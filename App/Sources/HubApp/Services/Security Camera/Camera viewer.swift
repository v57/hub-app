//
//  Camera viewer.swift
//  Hub
//
//  Watches one camera of a hub: finds the device that provides its Hub Network share, asks for the camera's password
//  once (kept in the keychain), shows the live stream, motion and the list of events, and downloads clips. The camera
//  is reached at its provider's overlay address through this device's Hub Network tunnel; a camera on this device
//  itself is reached on loopback.
//

#if canImport(PlatformCamera)
import Foundation
import HubService
import PlatformCamera
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A camera on a hub: its Hub Network share
struct HubCamera: Identifiable, Hashable, Sendable {
  static let sharePrefix = "Camera: "
  let resource: HubNetworkResource
  var id: String { resource.resourceId }
  /// The camera device's name
  var name: String { String(resource.shareName.dropFirst(Self.sharePrefix.count)) }

  init?(_ resource: HubNetworkResource) {
    guard resource.shareName.hasPrefix(Self.sharePrefix) else { return nil }
    self.resource = resource
  }
}

@MainActor @Observable
final class CameraViewer {
  enum State: Equatable {
    case finding
    /// The camera's device isn't on Hub Network now
    case offline
    case needsPassword
    case wrongPassword
    case connecting
    case live
    case failed(String)
  }

  let camera: HubCamera
  let renderer = CameraVideoRenderer()
  private(set) var state = State.finding
  private(set) var motion: CameraMotion?
  private(set) var info: CameraInfo?
  private(set) var events: [CameraEvent] = []
  private(set) var thumbnails: [String: Data] = [:]
  private(set) var lastFrame: Date?
  /// Frames received since the viewer started
  private(set) var frameCount = 0

  private let hub: Hub
  private var base: URL?
  private var password: String?
  private var connection: LiveConnection?
  private var refresh: Task<Void, Never>?
  private var retry: Task<Void, Never>?

  init(camera: HubCamera, hub: Hub) {
    self.camera = camera
    self.hub = hub
    password = Self.savedPassword(camera)
  }

  /// The providers of the camera's share as the hub streams them (`network/providers/list`)
  func providers(_ providers: [HubNetworkProvider]) {
    guard let provider = providers.first else {
      base = nil
      stop()
      state = .offline
      return
    }
    let host = provider.key == hub.key ? "127.0.0.1" : provider.overlayAddress
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = Int(provider.port)
    let url = components.url
    guard url != base || connection == nil else { return }
    base = url
    connect()
  }

  func setPassword(_ password: String) {
    self.password = password
    Self.save(password, for: camera)
    connect()
  }

  func connect() {
    stop()
    guard base != nil else {
      state = .offline
      return
    }
    guard password?.isEmpty == false else {
      state = .needsPassword
      return
    }
    state = .connecting
    Task { await load() }
  }

  func stop() {
    connection?.cancel()
    connection = nil
    refresh?.cancel()
    refresh = nil
    retry?.cancel()
    retry = nil
  }

  /// Info and events, then the live stream; events again every 10 seconds
  private func load() async {
    do {
      info = try await get("", as: CameraInfo.self)
    } catch CameraViewerError.unauthorized {
      state = .wrongPassword
      return
    } catch {
      fail(error)
      return
    }
    startLive()
    refresh = Task { [weak self] in
      while !Task.isCancelled {
        await self?.loadEvents()
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }

  func loadEvents() async {
    guard let events = try? await get("events", as: [CameraEvent].self) else { return }
    self.events = events
    for event in events.prefix(50) where thumbnails[event.id] == nil {
      if let data = try? await data("events/\(event.id)/thumbnail.jpg") { thumbnails[event.id] = data }
    }
  }

  private func startLive() {
    guard let request = request("live") else { return }
    let connection = LiveConnection(request: request, renderer: renderer) { [weak self] message in
      Task { @MainActor in self?.received(message) }
    } ended: { [weak self] error in
      Task { @MainActor in self?.ended(error) }
    }
    self.connection = connection
    connection.start()
  }

  private func received(_ message: LiveConnection.Event) {
    switch message {
    case .frames(let count):
      lastFrame = Date()
      frameCount += count
      if state != .live { state = .live }
    case .motion(let motion):
      self.motion = motion
    }
  }

  private func ended(_ error: Error?) {
    guard connection != nil else { return }
    connection = nil
    if case CameraViewerError.unauthorized? = error {
      state = .wrongPassword
      return
    }
    fail(error ?? CameraViewerError.closed)
    // Tries again in a few seconds: the camera restarting, the tunnel relinking
    retry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.connect()
    }
  }

  private func fail(_ error: Error) {
    state = .failed(error.localizedDescription)
  }

  /// The event's clip in a temporary file, for the player; the caller deletes it
  func downloadClip(_ event: CameraEvent) async throws -> URL {
    guard let request = request("events/\(event.id)/clip.mp4") else { throw CameraViewerError.closed }
    let (download, response) = try await URLSession.shared.download(for: request)
    try Self.check(response)
    let file = URL.temporaryDirectory.appending(path: "\(event.id).mp4")
    try? FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: download, to: file)
    return file
  }

  // MARK: Requests

  private func request(_ path: String) -> URLRequest? {
    guard let base, let password else { return nil }
    var request = URLRequest(url: base.appending(path: path))
    request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15
    return request
  }

  private func data(_ path: String) async throws -> Data {
    guard let request = request(path) else { throw CameraViewerError.closed }
    let (data, response) = try await URLSession.shared.data(for: request)
    try Self.check(response)
    return data
  }

  private func get<Value: Decodable>(_ path: String, as type: Value.Type) async throws -> Value {
    try JSONDecoder.camera.decode(type, from: try await data(path))
  }

  nonisolated private static func check(_ response: URLResponse) throws {
    guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
    if status == 401 { throw CameraViewerError.unauthorized }
    guard (200..<300).contains(status) else { throw CameraViewerError.status(status) }
  }

  // MARK: Passwords

  private static func keychain(_ camera: HubCamera) -> KeyChain.KeychainConfiguration {
    KeyChain.KeychainConfiguration(service: "dev.v57.Hub.camera.v1", account: camera.id, useDataProtectionKeychain: true)
  }

  static func savedPassword(_ camera: HubCamera) -> String? {
    (try? KeyChain.loadData(keychain: keychain(camera))).flatMap { String(data: $0, encoding: .utf8) }
  }

  static func save(_ password: String, for camera: HubCamera) {
    try? KeyChain.replaceData(Data(password.utf8), keychain: keychain(camera))
  }
}

enum CameraViewerError: LocalizedError {
  case unauthorized
  case closed
  case status(Int)

  var errorDescription: String? {
    switch self {
    case .unauthorized: "Wrong password."
    case .closed: "The camera ended the stream."
    case .status(503): "The camera isn’t shared on Hub Network right now."
    case .status(429): "Too many wrong passwords. Wait a minute."
    case .status(let status): "The camera answered \(status)."
    }
  }
}

/// The live stream's HTTP response, parsed as it arrives on URLSession's delegate queue: frames go straight to the
/// renderer, the rest to `received`
final class LiveConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Event: Sendable {
    /// Frames shown since the last of these
    case frames(Int)
    case motion(CameraMotion)
  }

  private let request: URLRequest
  private let renderer: CameraVideoRenderer
  private let received: @Sendable (Event) -> Void
  private let ended: @Sendable (Error?) -> Void
  private var parser = CameraWire.Parser()
  private var session: URLSession?
  private var lastFrameEvent = Date.distantPast
  private var framesSinceEvent = 0

  init(
    request: URLRequest, renderer: CameraVideoRenderer, received: @escaping @Sendable (Event) -> Void,
    ended: @escaping @Sendable (Error?) -> Void
  ) {
    self.request = request
    self.renderer = renderer
    self.received = received
    self.ended = ended
  }

  func start() {
    let configuration = URLSessionConfiguration.ephemeral
    // Frames come many times a second: a quiet stream is a broken one
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = .infinity
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    self.session = session
    session.dataTask(with: request).resume()
  }

  func cancel() {
    session?.invalidateAndCancel()
    session = nil
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
    if status == 401 {
      ended(CameraViewerError.unauthorized)
    } else if status != 200 {
      ended(CameraViewerError.status(status))
    }
    completionHandler(status == 200 ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    for message in parser.append(data) {
      switch message {
      case .video(let frame):
        renderer.enqueue(frame)
        framesSinceEvent += 1
        // The viewer's clock of the last frame, a few times a second at most
        let now = Date()
        if now.timeIntervalSince(lastFrameEvent) > 0.5 {
          lastFrameEvent = now
          received(.frames(framesSinceEvent))
          framesSinceEvent = 0
        }
      case .motion(let motion):
        received(.motion(motion))
      }
    }
    if parser.isBroken {
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    session.finishTasksAndInvalidate()
    if (error as? URLError)?.code == .cancelled, self.session == nil { return }
    ended(error)
  }
}
#endif
