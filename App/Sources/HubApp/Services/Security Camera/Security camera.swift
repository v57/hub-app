//
//  Security camera.swift
//  Hub
//
//  Turns this device into a security camera on one hub: off until the user turns it on (and asks for camera access
//  then), it captures, detects motion, records clips, and serves its live view and events to the hub's devices through
//  a Hub Network share (`Camera: <device name>`, everyone on the hub by default, behind the camera's password). The
//  device stays awake while the camera runs; on iPhone and iPad the app has to stay open, since iOS stops the camera in
//  the background.
//

#if canImport(PlatformCamera)
import Foundation
import HubService
import PlatformCamera
import PlatformPower
import PlatformSystem

@MainActor @Observable
final class SecurityCamera {
  static let main = SecurityCamera()

  enum Phase: Equatable {
    case off
    case starting
    case on
    case failed(String)
  }

  enum Quality: String, Codable, CaseIterable, Sendable {
    case hd, low
    var format: VideoFormat { self == .hd ? .hd : .low }
    var title: String { self == .hd ? "HD (720p)" : "Low (360p)" }
  }

  struct Settings: Codable, Hashable, Sendable {
    /// A `CameraDevice.id`; nil for the default camera
    var device: String?
    var quality = Quality.hd
    var sensitivity = 0.5
    var storage = CameraStoragePolicy()
  }

  private(set) var phase = Phase.off
  /// The hub the camera is on, while it's on or should come back on at launch
  private(set) var hubID: Hub.ID?
  var settings: Settings {
    didSet {
      guard settings != oldValue else { return }
      if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "camera.settings") }
      Task { await applySettings(oldValue) }
    }
  }
  /// Whether the share is published on the hub now; the server answers only while it is
  private(set) var isPublished = false
  /// Why the camera isn't reachable from other devices, while it isn't
  private(set) var shareProblem: String?
  private(set) var events: [CameraEvent] = []
  private(set) var motion = CameraMotion(isActive: false, level: 0)
  private(set) var device: CameraDevice?
  private(set) var interruption: String?
  private(set) var storageProblem: String?

  /// The engine while the camera runs: a HomeKit bridge takes it as its `CameraFeed`
  private(set) var engine: CameraEngine?
  private var server: CameraServer?
  private var recorder: CameraRecorder?
  private var port: UInt16?
  private var awake: SleepAssertion?
  private var watch: Task<Void, Never>?
  private var reconnectHandlers = Set<Hub.ID>()

  var isOn: Bool { phase == .on || phase == .starting }
  static var isSupported: Bool { CameraCapture.isAvailable }
  /// The cameras of this device
  var devices: [CameraDevice] { CameraCapture.devices() }
  var shareName: String { HubCamera.sharePrefix + SystemInfo.deviceName }
  /// This device's camera's resource on its hub, once published
  private(set) var resourceId: String?

  private init() {
    settings = UserDefaults.standard.data(forKey: "camera.settings").flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    hubID = UserDefaults.standard.url(forKey: "camera.hub")
  }

  /// The camera's password: made up when the camera is first turned on, kept in the keychain
  var password: String {
    get {
      if let data = try? KeyChain.loadData(keychain: Self.passwordKeychain), let password = String(data: data, encoding: .utf8) {
        return password
      }
      let password = Self.makePassword()
      try? KeyChain.replaceData(Data(password.utf8), keychain: Self.passwordKeychain)
      return password
    }
    set {
      try? KeyChain.replaceData(Data(newValue.utf8), keychain: Self.passwordKeychain)
      // Viewers sign in again with the new one
      if let hub = hub, isOn { Task { await restart(on: hub) } }
    }
  }

  private static let passwordKeychain = KeyChain.KeychainConfiguration(
    service: "dev.v57.Hub.camera.v1", account: "this-device", useDataProtectionKeychain: true)

  /// Three groups of four letters and digits, without the ones that look alike
  static func makePassword() -> String {
    let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    return (0..<3).map { _ in String((0..<4).map { _ in alphabet.randomElement()! }) }.joined(separator: "-")
  }

  var hub: Hub? { hubID.flatMap { id in Hubs.main.list.first { $0.id == id } } }

  /// At launch: the camera comes back on where the user left it on
  func restore() {
    guard phase == .off, UserDefaults.standard.bool(forKey: "camera.on"), let hub else { return }
    Task { await turnOn(hub: hub) }
  }

  // MARK: On and off

  func turnOn(hub: Hub) async {
    if isOn, hubID != hub.id { await turnOff() }
    guard !isOn else { return }
    phase = .starting
    hubID = hub.id
    UserDefaults.standard.set(hub.id, forKey: "camera.hub")
    do {
      if CameraCapture.access == .notDetermined { _ = await CameraCapture.requestAccess() }
      guard CameraCapture.access == .authorized else { throw CameraError.notAuthorized }
      let engine = try CameraEngine(settings: .init(device: settings.device, format: settings.quality.format, sensitivity: settings.sensitivity))
      engine.onInterruption = { reason in
        Task { @MainActor in SecurityCamera.main.interruption = reason.isEmpty ? nil : reason }
      }
      try engine.start()
      let recorder = CameraRecorder(folder: Self.folder, policy: settings.storage, hubFolder: "Cameras/\(SystemInfo.deviceName)")
      await recorder.configure(policy: settings.storage, hubStorage: hubStorage(hub)) { events in
        Task { @MainActor in
          SecurityCamera.main.events = events
          SecurityCamera.main.storageProblem = nil
        }
      }
      await recorder.start(engine: engine)
      let info = cameraInfo(engine: engine)
      let server = CameraServer(engine: engine, recorder: recorder, password: password, info: info)
      port = try await server.start()
      self.engine = engine
      self.recorder = recorder
      self.server = server
      device = engine.device
      interruption = nil
      awake = SleepAssertion(.idleSleep, reason: "Hub’s security camera is on")
      phase = .on
      UserDefaults.standard.set(true, forKey: "camera.on")
      await publish(on: hub)
      watchConnection(hub)
    } catch {
      await stopRunning()
      phase = .failed(error.localizedDescription)
    }
  }

  func turnOff() async {
    UserDefaults.standard.set(false, forKey: "camera.on")
    if let hub, hub.isConnected, isPublished {
      _ = try? await hub.service.network.remove(shareName)
    }
    await stopRunning()
    phase = .off
  }

  private func stopRunning() async {
    watch?.cancel()
    watch = nil
    server?.stop()
    server = nil
    await recorder?.stop()
    recorder = nil
    engine?.stop()
    engine = nil
    awake?.release()
    awake = nil
    port = nil
    isPublished = false
    motion = CameraMotion(isActive: false, level: 0)
  }

  private func restart(on hub: Hub) async {
    await stopRunning()
    phase = .off
    await turnOn(hub: hub)
  }

  private func applySettings(_ old: Settings) async {
    guard isOn, let hub else { return }
    if old.device != settings.device || old.quality != settings.quality || old.sensitivity != settings.sensitivity {
      await restart(on: hub)
    } else if old.storage != settings.storage {
      await recorder?.configure(policy: settings.storage, hubStorage: hubStorage(hub)) { events in
        Task { @MainActor in SecurityCamera.main.events = events }
      }
      await recorder?.applyRetention()
    }
  }

  private func cameraInfo(engine: CameraEngine) -> @Sendable () -> CameraInfo {
    let name = SystemInfo.deviceName
    let camera = engine.device?.name ?? "Camera"
    let format = engine.settings.format
    let sensitivity = engine.settings.sensitivity
    let storage = settings.storage.target.rawValue
    return { [weak engine] in
      CameraInfo(
        name: name, camera: camera, width: format.width, height: format.height, fps: format.fps,
        motion: engine?.motion ?? CameraMotion(isActive: false, level: 0), sensitivity: sensitivity, storage: storage)
    }
  }

  private func hubStorage(_ hub: Hub) -> CameraHubStorage {
    CameraHubStorage(
      write: { @MainActor key in try await hub.client.send("s3/write", key) },
      read: { @MainActor key in try await hub.client.send("s3/read", key) },
      delete: { @MainActor key in try await hub.client.send("s3/delete", key) },
      updated: { @MainActor folder in try await hub.client.send("s3/updated", folder) })
  }

  /// Clips, thumbnails and the event index
  static var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Camera", directoryHint: .isDirectory)
  }

  // MARK: Hub Network

  /// Shares the server's port on the hub's network: everyone on the hub may connect (the owner can narrow it on the
  /// Network page), behind the password. The share's attestation is this device's own: its Hub Network membership
  /// is registered with the key it connects with.
  private func publish(on hub: Hub) async {
    guard let port else { return }
    guard hub.net.isJoined else {
      setPublished(false, problem: "Turn on Hub Network on this device so your other devices can reach the camera.")
      return
    }
    let identity = hub.identity
    hub.service.network.setAttestationProvider { share, serviceKey, _ in
      try CameraShareAttestation.attest(share, serviceKey: serviceKey, identity: identity)
    }
    if !reconnectHandlers.contains(hub.id) {
      reconnectHandlers.insert(hub.id)
      hub.service.network.onReconnect { [weak self, weak hub] publications in
        guard let self, let hub, hub.id == self.hubID, let resourceId = self.resourceId else { return }
        self.setPublished(publications.contains { $0.resourceId == resourceId }, problem: nil)
      }
    }
    do {
      let publications = try await hub.service.network.publish(
        NetworkShare(name: shareName, protocol: .tcp, target: LocalTarget(port: port), policy: .hub))
      resourceId = hub.service.network.publication(forShare: shareName)?.resourceId
      setPublished(resourceId != nil && publications.contains { $0.resourceId == resourceId }, problem: nil)
    } catch {
      setPublished(false, problem: "Hub Network didn’t take the camera’s share: \(error.localizedDescription)")
    }
  }

  private func setPublished(_ published: Bool, problem: String?) {
    isPublished = published
    shareProblem = published ? nil : problem ?? shareProblem
    server?.setPublished(published)
  }

  /// Fails closed while the hub is away: the share is gone from the hub then, so the server stops answering until
  /// the reconnected hub has it again. Also follows motion for this page.
  private func watchConnection(_ hub: Hub) {
    watch?.cancel()
    watch = Task { [weak self, weak hub] in
      var wasConnected = hub?.isConnected ?? false
      var wasJoined = hub?.net.isJoined ?? false
      while !Task.isCancelled, let self, let hub {
        let connected = hub.isConnected
        let joined = hub.net.isJoined
        if !connected, self.isPublished {
          self.setPublished(false, problem: "\(hub.settings.name) isn’t connected.")
        }
        // Joined later, or a publication failed while the hub was away: try again
        if connected, joined, !self.isPublished, !wasConnected || !wasJoined || self.shareProblem != nil {
          await self.publish(on: hub)
        }
        wasConnected = connected
        wasJoined = joined
        if let engine = self.engine { self.motion = engine.motion }
        if let recorder = self.recorder, let problem = await recorder.lastError { self.storageProblem = problem }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
}

/// A share's attestation signed by this app's own key, the key of this device's Hub Network membership: what a
/// machine's agent (`LocalShareAgent`) signs for the services it fronts, here for the app's own server
enum CameraShareAttestation {
  static func attest(_ share: NetworkShare, serviceKey: String, identity: KeyChain) throws -> AgentAttestation {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = Date()
    let unsigned = AgentAttestation(
      attestationId: UUID().uuidString.lowercased(), serviceKey: serviceKey, key: identity.publicKey(), shareName: share.name,
      protocol: share.protocol, target: share.target, issuedAt: formatter.string(from: now),
      expiresAt: formatter.string(from: now.addingTimeInterval(120)), signature: "")
    let input = try HubNetworkSignedEnvelope.signatureInput(for: unsigned, domain: "hub-network/agent-attestation/v1")
    return AgentAttestation(
      attestationId: unsigned.attestationId, serviceKey: serviceKey, key: unsigned.key, shareName: share.name,
      protocol: share.protocol, target: share.target, issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt,
      signature: identity.sign(data: input))
  }
}
#endif
