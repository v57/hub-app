//
//  Camera server.swift
//  Hub
//
//  The camera's HTTP server (routes in Camera protocol.swift). It listens on every interface, since the overlay's
//  address comes and goes with the tunnel, but answers only connections from Hub Network (100.64.0.0/10,
//  fd48:5542:4e45::/48) or this device, only while the camera's Hub Network share is published, and only with the
//  camera's password. A live viewer that can't keep up loses frames up to the next keyframe instead of a growing queue.
//

#if canImport(PlatformCamera)
import ChannelServer
import CryptoKit
import Foundation
import PlatformCamera

final class CameraServer: @unchecked Sendable {
  /// Bytes queued for a live viewer before its frames are skipped: about two seconds of video
  static let liveBacklog = 512 * 1024
  /// Failed passwords from one address before it waits a minute
  static let attempts = 10

  private let engine: CameraEngine
  private let recorder: CameraRecorder
  private let passwordHash: Data
  private let info: @Sendable () -> CameraInfo
  private let queue = DispatchQueue(label: "dev.v57.Hub.camera-server")
  private var listener: ByteStreamListener?
  private var live: [ObjectIdentifier: LiveViewer] = [:]
  private var failures: [String: [Date]] = [:]
  /// Answers only while the camera's share is published on its hub; set on `queue`
  private var isPublished = false

  init(engine: CameraEngine, recorder: CameraRecorder, password: String, info: @escaping @Sendable () -> CameraInfo) {
    self.engine = engine
    self.recorder = recorder
    passwordHash = Data(SHA256.hash(data: Data(password.utf8)))
    self.info = info
  }

  /// Listens on a free port and returns it
  func start() async throws -> UInt16 {
    let listener = makeByteStreamListener(ListenAddress(port: 0))
    self.listener = listener
    return try await withCheckedThrowingContinuation { continuation in
      listener.start(queue: queue) { result in
        continuation.resume(with: result)
      } accept: { [weak self] stream in
        self?.accept(stream)
      }
    }
  }

  func stop() {
    queue.sync {
      isPublished = false
      listener?.stop()
      listener = nil
      closeLiveViewers()
    }
  }

  /// Whether the share is live: without it, requests get 503 and live viewers are dropped (fail closed)
  func setPublished(_ published: Bool) {
    queue.async { [self] in
      isPublished = published
      if !published { closeLiveViewers() }
    }
  }

  private func closeLiveViewers() {
    let viewers = live.values
    live = [:]
    for viewer in viewers {
      viewer.stopWatching()
      viewer.stream.close()
    }
  }

  // MARK: Requests

  private func accept(_ stream: ByteStream) {
    guard let address = stream.remoteAddress, Self.isAllowed(address) else {
      stream.close()
      return
    }
    var buffer = Data()
    var answered = false
    stream.start { [weak self, weak stream] data in
      guard let self, let stream, !answered else { return }
      buffer.append(data)
      if buffer.count > 16_384 {
        answered = true
        self.respond(stream, status: 431, text: "Request too large")
        return
      }
      guard let end = buffer.range(of: Data("\r\n\r\n".utf8)), let request = Request(buffer[..<end.lowerBound]) else { return }
      answered = true
      self.handle(request, address: address, on: stream)
    } onClose: { [weak self, weak stream] in
      guard let self, let stream else { return }
      if let viewer = self.live.removeValue(forKey: ObjectIdentifier(stream)) { viewer.stopWatching() }
    }
  }

  private func handle(_ request: Request, address: String, on stream: ByteStream) {
    guard isPublished else { return respond(stream, status: 503, text: "The camera isn’t shared on Hub Network") }
    guard request.method == "GET" || request.method == "HEAD" else { return respond(stream, status: 405, text: "Use GET") }
    let now = Date()
    let recent = (failures[address] ?? []).filter { now.timeIntervalSince($0) < 60 }
    failures[address] = recent.isEmpty ? nil : recent
    guard recent.count < Self.attempts else { return respond(stream, status: 429, text: "Too many wrong passwords. Wait a minute.") }
    guard let token = request.bearer, Self.equal(Data(SHA256.hash(data: Data(token.utf8))), passwordHash) else {
      failures[address, default: []].append(now)
      return respond(stream, status: 401, text: "Wrong password", headers: ["WWW-Authenticate": "Bearer realm=\"Hub camera\""])
    }
    let parts = request.path.split(separator: "/").map(String.init)
    switch parts.first {
    case nil:
      respond(stream, json: info())
    case "live" where parts.count == 1:
      startLive(on: stream)
    case "snapshot.jpg" where parts.count == 1:
      let width = request.query["width"].flatMap(Int.init).map { min(max($0, 64), 3840) } ?? 1280
      answer(stream) { [engine] in
        guard let jpeg = try? await engine.snapshot(maxWidth: width) else { return .text(503, "No picture yet") }
        return .data(jpeg, "image/jpeg")
      }
    case "events" where parts.count == 1:
      answer(stream) { [recorder] in
        .data((try? JSONEncoder.camera.encode(await recorder.events)) ?? Data("[]".utf8), "application/json")
      }
    case "events" where parts.count == 3 && parts[2] == "thumbnail.jpg":
      let id = parts[1]
      answer(stream) { [recorder] in
        guard let url = await recorder.thumbnail(id), let data = try? Data(contentsOf: url) else { return .text(404, "No thumbnail") }
        return .data(data, "image/jpeg")
      }
    case "events" where parts.count == 3 && parts[2] == "clip.mp4":
      let id = parts[1]
      answer(stream) { [recorder] in
        do {
          let (url, isTemporary) = try await recorder.clip(id)
          return .file(url, "video/mp4", deleteAfter: isTemporary)
        } catch {
          return .text(404, error.localizedDescription)
        }
      }
    default:
      respond(stream, status: 404, text: "Not found")
    }
  }

  /// What a route answers after work off the server's queue
  private enum Answer: Sendable {
    case data(Data, String)
    case text(Int, String)
    case file(URL, String, deleteAfter: Bool)
  }

  private struct Connection: @unchecked Sendable {
    let stream: ByteStream
  }

  private func answer(_ stream: ByteStream, _ make: @escaping @Sendable () async -> Answer) {
    let connection = Connection(stream: stream)
    Task {
      let answer = await make()
      queue.async { [self] in
        switch answer {
        case .data(let body, let type): respond(connection.stream, status: 200, body: body, type: type)
        case .text(let status, let text): respond(connection.stream, status: status, text: text)
        case .file(let url, let type, let deleteAfter): sendFile(url, type: type, on: connection.stream, deleteAfter: deleteAfter)
        }
      }
    }
  }

  // MARK: Live

  private final class LiveViewer: @unchecked Sendable {
    let stream: ByteStream
    var stopWatching: () -> Void = {}
    /// Skipping frames until a keyframe, after falling behind
    var skips = false
    var motion: CameraMotion?
    var timer: DispatchSourceTimer?
    init(stream: ByteStream) { self.stream = stream }
  }

  private func startLive(on stream: ByteStream) {
    stream.write(Self.head(status: 200, headers: ["Content-Type": CameraWire.contentType, "Cache-Control": "no-store"]))
    let viewer = LiveViewer(stream: stream)
    live[ObjectIdentifier(stream)] = viewer
    let stopFrames = engine.watch { [weak self, weak viewer] frame in
      guard let self, let viewer else { return }
      self.queue.async { self.send(frame, to: viewer) }
    }
    // Motion, when it changes, at most twice a second
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 0.5)
    timer.setEventHandler { [weak self, weak viewer] in
      guard let self, let viewer else { return }
      let motion = self.engine.motion
      let rounded = CameraMotion(isActive: motion.isActive, level: (motion.level * 100).rounded() / 100)
      guard rounded != viewer.motion else { return }
      viewer.motion = rounded
      viewer.stream.write(CameraWire.record(rounded))
    }
    timer.resume()
    viewer.timer = timer
    viewer.stopWatching = { [weak viewer] in
      stopFrames()
      viewer?.timer?.cancel()
      viewer?.timer = nil
    }
  }

  /// Writes a frame unless the viewer is behind; one that fell behind starts again at a keyframe
  private func send(_ frame: EncodedVideoFrame, to viewer: LiveViewer) {
    guard live[ObjectIdentifier(viewer.stream)] === viewer else { return }
    if !viewer.skips, viewer.stream.bufferedAmount > Self.liveBacklog {
      viewer.skips = true
#if DEBUG
      print("[CAMERA] viewer behind, \(viewer.stream.bufferedAmount) bytes queued: skipping to a keyframe")
#endif
    }
    if viewer.skips {
      guard frame.isKeyframe, viewer.stream.bufferedAmount < Self.liveBacklog / 4 else { return }
      viewer.skips = false
#if DEBUG
      print("[CAMERA] viewer caught up, \(viewer.stream.bufferedAmount) bytes queued")
#endif
    }
    viewer.stream.write(CameraWire.record(frame))
  }

  // MARK: Responses

  private func respond(_ stream: ByteStream, status: Int, text: String, headers: [String: String] = [:]) {
    respond(stream, status: status, body: Data(text.utf8), type: "text/plain; charset=utf-8", headers: headers)
  }

  private func respond<Value: Encodable>(_ stream: ByteStream, json value: Value) {
    let body = (try? JSONEncoder.camera.encode(value)) ?? Data("null".utf8)
    respond(stream, status: 200, body: body, type: "application/json")
  }

  private func respond(_ stream: ByteStream, status: Int, body: Data, type: String, headers: [String: String] = [:]) {
    var headers = headers
    headers["Content-Type"] = type
    headers["Content-Length"] = String(body.count)
    headers["Cache-Control"] = "no-store"
    stream.write(Self.head(status: status, headers: headers) + body)
    stream.close()
  }

  /// A file in pieces, as fast as the viewer takes them
  private func sendFile(_ url: URL, type: String, on stream: ByteStream, deleteAfter: Bool) {
    guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else {
      return respond(stream, status: 404, text: "The clip is gone")
    }
    try? handle.seek(toOffset: 0)
    stream.write(Self.head(status: 200, headers: ["Content-Type": type, "Content-Length": String(size), "Cache-Control": "no-store"]))
    FileSender(handle: handle, url: url, deleteAfter: deleteAfter, stream: stream, queue: queue).next()
  }

  /// Feeds a file to a connection while it keeps up, on the server's queue
  private final class FileSender: @unchecked Sendable {
    let handle: FileHandle
    let url: URL
    let deleteAfter: Bool
    let stream: ByteStream
    let queue: DispatchQueue

    init(handle: FileHandle, url: URL, deleteAfter: Bool, stream: ByteStream, queue: DispatchQueue) {
      self.handle = handle
      self.url = url
      self.deleteAfter = deleteAfter
      self.stream = stream
      self.queue = queue
    }

    func next() {
      while stream.bufferedAmount < 1 << 20 {
        guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else {
          try? handle.close()
          if deleteAfter { try? FileManager.default.removeItem(at: url) }
          stream.close()
          return
        }
        stream.write(chunk)
      }
      queue.asyncAfter(deadline: .now() + 0.02) { self.next() }
    }
  }

  private static func head(status: Int, headers: [String: String]) -> Data {
    let reasons = [200: "OK", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 429: "Too Many Requests",
                   431: "Request Header Fields Too Large", 503: "Service Unavailable"]
    var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nConnection: close\r\n"
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
    return Data((text + "\r\n").utf8)
  }

  // MARK: Checks

  /// Hub Network's overlay (100.64.0.0/10 holds the hub's 100.96.0.0/11; fd48:5542:4e45::/48) or this device
  static func isAllowed(_ address: String) -> Bool {
    if address == "127.0.0.1" || address == "::1" { return true }
    let lowered = address.lowercased()
    if lowered.hasPrefix("fd48:5542:4e45:") { return true }
    let octets = address.split(separator: ".").compactMap { UInt8($0) }
    return octets.count == 4 && octets[0] == 100 && octets[1] & 0xC0 == 64
  }

  /// Compares in constant time
  static func equal(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  struct Request {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]

    init?(_ head: Data) {
      let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
      let line = lines.first?.split(separator: " ") ?? []
      guard line.count == 3, line[2].hasPrefix("HTTP/1.") else { return nil }
      method = String(line[0])
      let target = URLComponents(string: String(line[1]))
      path = target?.path ?? "/"
      query = Dictionary((target?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
      headers = [:]
      for field in lines.dropFirst() {
        guard let colon = field.firstIndex(of: ":") else { continue }
        headers[field[..<colon].lowercased()] = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      }
    }

    var bearer: String? {
      guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else { return nil }
      return String(value.dropFirst(7))
    }
  }
}
#endif
