//
//  Security camera.swift
//  Hub
//
//  Turns this device's cameras into security cameras on one hub: off until the user turns it on (and asks for camera
//  access then). Each lens turned on (`CameraSetup`) is its own Hub camera, named after the place it watches: it
//  captures, detects motion, records clips, and serves its live view and events to the hub's devices through a Hub
//  Network share of its own (`Camera: <place>`, everyone on the hub by default, behind its own password). One
//  `CameraRig` runs the lenses together (iOS's multi-camera session where there's more than one). The device stays
//  awake while a camera runs; on iPhone and iPad the app has to stay open, since iOS stops the camera in the
//  background.
//

#if canImport(PlatformCamera)
import Foundation
import HubService
import PlatformCamera
import PlatformPower
import PlatformSystem
#if os(iOS)
import UIKit
#endif

@MainActor @Observable
final class SecurityCamera {
  static let main = SecurityCamera()

  enum Phase: Equatable {
    case off
    case starting
    case on
    case failed(String)
  }

  struct Settings: Codable, Hashable, Sendable {
    var cameras: [CameraSetup] = []
    var storage = CameraStoragePolicy()
  }

  /// One of this device's cameras while it runs
  @MainActor @Observable
  final class Unit: Identifiable {
    let id: String
    let engine: CameraEngine
    let recorder: CameraRecorder
    let server: CameraServer
    let port: UInt16
    fileprivate let info: CameraInfoBox
    fileprivate(set) var shareName: String
    fileprivate(set) var resourceId: String?
    fileprivate(set) var isPublished = false
    /// Why the camera isn't reachable from other devices, while it isn't
    fileprivate(set) var shareProblem: String?
    fileprivate(set) var events: [CameraEvent] = []
    fileprivate(set) var motion = CameraMotion(isActive: false, level: 0)
    fileprivate(set) var viewers = 0
    fileprivate(set) var storageProblem: String?
    /// No clips now: someone is using the Mac (When I'm Away)
    fileprivate(set) var clipsPaused = false
    /// No live view either, while clips are paused (live view while paused off)
    fileprivate(set) var liveOff = false
    fileprivate var password: String

    fileprivate init(id: String, engine: CameraEngine, recorder: CameraRecorder, server: CameraServer, port: UInt16, info: CameraInfoBox, shareName: String, password: String) {
      self.id = id
      self.engine = engine
      self.recorder = recorder
      self.server = server
      self.port = port
      self.info = info
      self.shareName = shareName
      self.password = password
    }
  }

  private(set) var phase = Phase.off
  /// The hub the cameras are on, while they're on or should come back on at launch
  private(set) var hubID: Hub.ID?
  var settings: Settings {
    didSet {
      guard settings != oldValue else { return }
      if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
      Task { await apply() }
    }
  }
  /// The running cameras by `CameraSetup.id`
  private(set) var units: [String: Unit] = [:]
  /// Why the cameras aren't capturing, while they aren't
  private(set) var interruption: String? {
    didSet { units.values.forEach { $0.info.value.paused = pausedReason($0) } }
  }
  /// Whether someone is using this Mac, while a camera records only when they're away
  private(set) var presence: UserPresence?
  /// Record for 1 Hour: cameras that record until then even while someone is using the Mac
  private(set) var recordsUntil: [String: Date] = [:]
  private var presenceObservation: UserPresenceObservation?

  static let clipsPausedReason = String(localized: "Clips paused · you’re using this \(deviceKind)")
  static let liveOffReason = String(localized: "Live view is off while you’re using this \(deviceKind).")
  /// Why a camera couldn't start, while it can't
  private(set) var problem: String?
  /// What the cameras cost now, and before the last change (the budget's ticks)
  private(set) var budget = CameraBudget()
  private(set) var previousBudget: CameraBudget?
  /// Hub's share of all the CPU, 0…1
  private(set) var cpuShare: Double?
  private(set) var previousCPUShare: Double?
  /// On iPhone and iPad: the camera's own black screen over the app (`CameraScreen`)
  var showsScreen = false

  private let rig = CameraRig()
  private let router = EngineRouter()
  private var awake: SleepAssertion?
  private var watch: Task<Void, Never>?
  private var reconnectHandlers = Set<Hub.ID>()
  private var applying = false
  private var appliesAgain = false

  var isOn: Bool { phase == .on || phase == .starting }
  static var isSupported: Bool { CameraCapture.isAvailable }
  /// The lenses of this device
  var devices: [CameraDevice] { CameraCapture.devices() }
  var hub: Hub? { hubID.flatMap { id in Hubs.main.list.first { $0.id == id } } }
  var orderedUnits: [Unit] { settings.cameras.compactMap { units[$0.id] } }

  private static let settingsKey = "camera.settings.v2"

  private init() {
    hubID = UserDefaults.standard.url(forKey: "camera.hub")
    if let data = UserDefaults.standard.data(forKey: Self.settingsKey), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
      settings = saved
    } else {
      settings = Self.migrated()
    }
    let router = router
    rig.onFrame = { device, frame in router.engine(for: device)?.take(frame) }
    rig.onInterruption = { reason in
      Task { @MainActor in SecurityCamera.main.interruption = reason.isEmpty ? nil : reason }
    }
    rig.onBudget = { budget in
      Task { @MainActor in
        SecurityCamera.main.budget.pressure = budget.pressure
        SecurityCamera.main.budget.factors = budget.factors
      }
    }
  }

  /// The settings of the app before cameras were per lens: one camera named after the device, its clips in the
  /// camera folder's root (moved into its own folder), its password kept
  private static func migrated() -> Settings {
    struct Old: Decodable {
      var device: String?
      var quality: String?
      var sensitivity: Double?
      var storage: CameraStoragePolicy?
    }
    var settings = Settings()
    guard let device = CameraCapture.defaultDeviceID else { return settings }
    var setup = CameraSetup(id: "main", device: device, place: SystemInfo.deviceName, isOn: true)
    if let data = UserDefaults.standard.data(forKey: "camera.settings"), let old = try? JSONDecoder().decode(Old.self, from: data) {
      if let id = old.device, CameraCapture.devices().contains(where: { $0.id == id }) { setup.device = id }
      setup.video.height = old.quality == "low" ? 360 : 720
      setup.video.fps = 24
      setup.sensitivity = old.sensitivity ?? 0.5
      settings.storage = old.storage ?? CameraStoragePolicy()
    }
    let root = folder
    let target = root.appending(path: "main", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: root.appending(path: "events.json").path), !FileManager.default.fileExists(atPath: target.path) {
      try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      for name in ["Clips", "Thumbnails", "events.json"] {
        try? FileManager.default.moveItem(at: root.appending(path: name), to: target.appending(path: name))
      }
    }
    settings.cameras = [setup]
    return settings
  }

  // MARK: Cameras

  /// The setup of a lens: the saved one, or a new one (off) named after it
  func setup(for device: CameraDevice) -> CameraSetup {
    settings.cameras.first { $0.device == device.id }
      ?? CameraSetup(device: device.id, place: Self.suggestedPlace(for: device), isOn: false)
  }

  /// Changes a lens's setup (adding it the first time)
  func update(_ setup: CameraSetup) {
    if let index = settings.cameras.firstIndex(where: { $0.id == setup.id }) {
      settings.cameras[index] = setup
    } else {
      settings.cameras.append(setup)
    }
  }

  /// Whether another lens can go on next to the ones on, and why not
  func reasonCantTurnOn(_ device: CameraDevice) -> String? {
    let on = settings.cameras.filter(\.isOn).map(\.device)
    guard !on.contains(device.id) else { return nil }
    if on.count >= CameraRig.maximumCameras {
      let count = CameraRig.maximumCameras
      return count == 1
        ? String(localized: "This \(Self.deviceKind) runs one camera at once.")
        : String(localized: "This \(Self.deviceKind) runs \(count) cameras at once.")
    }
    if !CameraRig.canRun(together: on + [device.id]) { return String(localized: "Doesn’t run together with the cameras that are on.") }
    return nil
  }

  private static func suggestedPlace(for device: CameraDevice) -> String {
    switch device.position {
    case .front: "Front Camera"
    case .back:
      // Back Camera → Back, Back Ultra Wide Camera → Ultra Wide
      device.name == "Back Camera" ? "Back" : device.name.replacingOccurrences(of: "Back ", with: "").replacingOccurrences(of: " Camera", with: "")
    case .external: device.name
    }
  }

  /// What `device` can do with the cameras that are on (fewer formats while several run on iPhone and iPad)
  func capabilities(of setup: CameraSetup) -> CameraCapabilities {
    let together = Set(settings.cameras.filter(\.isOn).map(\.device) + (setup.isOn ? [setup.device] : [])).count
    return CameraRig.capabilities(of: setup.device, together: max(1, together))
  }

  /// What the cameras would cost with this setup's video instead of its current one (iPhone and iPad with several
  /// cameras on); nil where the system has no numbers
  func estimate(_ setup: CameraSetup) async -> CameraBudget? {
    let configurations = settings.cameras.filter(\.isOn).map { $0.id == setup.id ? setup.configuration : $0.configuration }
    guard isOn, configurations.count > 1 else { return nil }
    let rig = rig
    return await Task.detached { rig.estimate(configurations) }.value
  }

  /// Locks focus, exposure and white balance where they are now
  func lockNow(_ setup: CameraSetup) async {
    let rig = rig
    let device = setup.device
    guard let values = await Task.detached(operation: { rig.lockNow(device: device) }).value else { return }
    var setup = setup
    setup.locked = values
    setup.picture.focus = .locked
    setup.picture.exposure = .locked
    setup.picture.whiteBalance = .locked
    update(setup)
  }

  // MARK: Passwords

  /// A camera's password: made up the first time, kept in the keychain
  func password(_ id: String) -> String {
    if let data = try? KeyChain.loadData(keychain: Self.passwordKeychain(id)), let password = String(data: data, encoding: .utf8) {
      return password
    }
    let password = Self.makePassword()
    try? KeyChain.replaceData(Data(password.utf8), keychain: Self.passwordKeychain(id))
    return password
  }

  /// The password of this device's camera with this Hub Network share, if it's one: its own pages watch it without
  /// asking
  func password(for camera: HubCamera) -> String? {
    // By share name while the hub's answer with the resource id is still on its way
    units.values.first { $0.resourceId == camera.id || ($0.resourceId == nil && $0.shareName == camera.resource.shareName) }?.password
  }

  /// Seconds of clips a day over the last 7 days (motion, with what's recorded before it), for the usage estimates
  func clipSecondsPerDay(_ id: String) -> Double {
    let since = Date().addingTimeInterval(-7 * 86_400)
    let events = units[id]?.events.filter { $0.start >= since && $0.end != nil } ?? []
    return events.reduce(0) { $0 + $1.duration + settings.storage.preRoll } / 7
  }

  /// Viewers sign in again with the new one
  func setPassword(_ password: String, for id: String) {
    try? KeyChain.replaceData(Data(password.utf8), keychain: Self.passwordKeychain(id))
    if isOn { Task { await apply() } }
  }

  private static func passwordKeychain(_ id: String) -> KeyChain.KeychainConfiguration {
    // The first camera keeps the password the device's one camera had
    KeyChain.KeychainConfiguration(service: "dev.v57.Hub.camera.v1", account: id == "main" ? "this-device" : "camera-\(id)", useDataProtectionKeychain: true)
  }

  /// Three groups of four letters and digits, without the ones that look alike
  static func makePassword() -> String {
    let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    return (0..<3).map { _ in String((0..<4).map { _ in alphabet.randomElement()! }) }.joined(separator: "-")
  }

  // MARK: On and off

  /// At launch: the cameras come back on where the user left them on
  func restore() {
    guard phase == .off, UserDefaults.standard.bool(forKey: "camera.on"), let hub else { return }
    Task { await turnOn(hub: hub) }
  }

  func turnOn(hub: Hub) async {
    if isOn, hubID != hub.id { await turnOff() }
    guard !isOn else { return }
    phase = .starting
    hubID = hub.id
    UserDefaults.standard.set(hub.id, forKey: "camera.hub")
    if CameraCapture.access == .notDetermined { _ = await CameraCapture.requestAccess() }
    guard CameraCapture.access == .authorized else {
      phase = .failed(CameraError.notAuthorized.localizedDescription)
      return
    }
    if !settings.cameras.contains(where: \.isOn), let device = devices.first {
      var setup = setup(for: device)
      setup.isOn = true
      update(setup)
    }
    awake = SleepAssertion(.idleSleep, reason: "Hub’s security camera is on")
    phase = .on
    UserDefaults.standard.set(true, forKey: "camera.on")
    await apply()
    watchConnection(hub)
  }

  func turnOff() async {
    UserDefaults.standard.set(false, forKey: "camera.on")
    phase = .off
    showsScreen = false
    watch?.cancel()
    watch = nil
    await apply()
    awake?.release()
    awake = nil
  }

  /// Runs exactly the cameras that should run now: starts, stops and changes units, then the rig
  private func apply() async {
    // One at a time: a change while applying applies once more afterwards
    guard !applying else {
      appliesAgain = true
      return
    }
    applying = true
    defer { applying = false }
    repeat {
      appliesAgain = false
      await applyOnce()
    } while appliesAgain
  }

  private func applyOnce() async {
    let wanted = phase == .on ? settings.cameras.filter(\.isOn) : []
    let wantedIDs = Set(wanted.map(\.id))
    for (id, unit) in units where !wantedIDs.contains(id) {
      await stop(unit)
    }
    var failures = [String]()
    for setup in wanted {
      do {
        if let unit = units[setup.id] {
          try await change(unit, to: setup)
        } else {
          try await start(setup)
        }
      } catch {
        failures.append("\(setup.place): \(error.localizedDescription)")
      }
    }
    router.set(Dictionary(units.values.map { ($0.engine.device.id, $0.engine) }, uniquingKeysWith: { a, _ in a }))
    observePresence()
    updateClipsPaused()
    // A camera whose live view is off while clips are paused doesn't capture at all
    let configurations = wanted.filter { units[$0.id].map { !$0.liveOff } ?? false }.map(\.configuration)
    let rig = rig
    let before = budget
    do {
      try await Task.detached { try rig.run(configurations) }.value
    } catch {
      failures.append(error.localizedDescription)
    }
    budget = await Task.detached { rig.budget }.value
    if before != budget, before.hardwareCost != nil || budget.hardwareCost != nil { previousBudget = before }
    problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
    if phase == .on, wanted.isEmpty == false, units.isEmpty {
      phase = .failed(problem ?? String(localized: "No camera started."))
    }
    if let hub, phase == .on {
      for unit in units.values where !unit.isPublished { await publish(unit, on: hub) }
    }
  }

  private func start(_ setup: CameraSetup) async throws {
    guard let device = devices.first(where: { $0.id == setup.device }) else { throw CameraError.noDevice }
    let engine = try CameraEngine(device: device, settings: engineSettings(setup))
    engine.start()
    let folder = Self.folder.appending(path: setup.id, directoryHint: .isDirectory)
    let recorder = CameraRecorder(folder: folder, policy: settings.storage, hubFolder: "Cameras/\(setup.place)")
    let id = setup.id
    if let hub {
      await recorder.configure(policy: settings.storage, hubStorage: hubStorage(hub)) { events in
        Task { @MainActor in
          SecurityCamera.main.units[id]?.events = events
          SecurityCamera.main.units[id]?.storageProblem = nil
        }
      }
    }
    await recorder.start(engine: engine)
    let box = CameraInfoBox(info(setup, engine: engine))
    let password = password(setup.id)
    let server = CameraServer(engine: engine, recorder: recorder, password: password) { [weak engine] in
      var info = box.value
      if let engine { info.motion = engine.motion }
      return info
    }
    // The same port as last time where it's free: devices following the camera's alerts in the background know it
    let portKey = "camera.port.\(setup.id)"
    let port = try await server.start(port: UInt16(clamping: UserDefaults.standard.integer(forKey: portKey)))
    UserDefaults.standard.set(Int(port), forKey: portKey)
    units[setup.id] = Unit(
      id: setup.id, engine: engine, recorder: recorder, server: server, port: port, info: box,
      shareName: HubCamera.sharePrefix + setup.place, password: password)
  }

  private func change(_ unit: Unit, to setup: CameraSetup) async throws {
    try unit.engine.update(engineSettings(setup))
    unit.info.value = info(setup, engine: unit.engine)
    unit.info.value.paused = pausedReason(unit)
    unit.info.value.clipsPaused = unit.clipsPaused ? Self.clipsPausedReason : nil
    if let hub {
      await unit.recorder.configure(policy: settings.storage, hubStorage: hubStorage(hub)) { events in
        Task { @MainActor in SecurityCamera.main.units[setup.id]?.events = events }
      }
      await unit.recorder.applyRetention()
    }
    // Another password or place: a new server or share
    let password = password(setup.id)
    let shareName = HubCamera.sharePrefix + setup.place
    if password != unit.password || shareName != unit.shareName {
      await stop(unit)
      try await start(setup)
    }
  }

  private func stop(_ unit: Unit) async {
    units[unit.id] = nil
    if let hub, hub.isConnected, unit.isPublished {
      _ = try? await hub.service.network.remove(unit.shareName)
    }
    unit.server.stop()
    await unit.recorder.stop()
    unit.engine.stop()
  }

  // MARK: When I'm Away

  /// Follows whether someone uses the Mac while a running camera records only when they're away
  private func observePresence() {
    let needed = phase == .on && UserPresence.isSupported && settings.cameras.contains { $0.isOn && $0.recording.when == .whenAway }
    if needed, presenceObservation == nil {
      presenceObservation = UserPresence.observe { presence in
        SecurityCamera.main.presence = presence
        SecurityCamera.main.updateClipsPaused()
      }
    } else if !needed, presenceObservation != nil {
      presenceObservation?.cancel()
      presenceObservation = nil
      presence = nil
    }
  }

  /// Whether this camera records no clips now: When I'm Away, someone is using the Mac, and no Record for 1 Hour
  func clipsPaused(_ setup: CameraSetup) -> Bool {
    guard setup.recording.when == .whenAway, let presence else { return false }
    if let until = recordsUntil[setup.id], until > Date() { return false }
    return !presence.isAway(after: Double(setup.recording.awayMinutes) * 60)
  }

  /// Records for an hour even while someone is using the Mac; nil ends it
  func recordForAnHour(_ id: String, _ on: Bool = true) {
    recordsUntil[id] = on ? Date().addingTimeInterval(3600) : nil
    updateClipsPaused()
  }

  /// Pauses and resumes the running cameras' clips as presence changes; restarts the rig when a live view goes off or
  /// comes back
  private func updateClipsPaused() {
    if recordsUntil.values.contains(where: { $0 <= Date() }) { recordsUntil = recordsUntil.filter { $0.value > Date() } }
    var liveChanged = false
    for setup in settings.cameras {
      guard let unit = units[setup.id] else { continue }
      let paused = clipsPaused(setup)
      let liveOff = paused && !setup.recording.liveWhilePaused
      if unit.clipsPaused != paused {
        unit.clipsPaused = paused
        unit.info.value.clipsPaused = paused ? Self.clipsPausedReason : nil
        let recorder = unit.recorder
        Task { await recorder.setPaused(paused) }
      }
      if unit.liveOff != liveOff {
        unit.liveOff = liveOff
        unit.info.value.paused = pausedReason(unit)
        liveChanged = true
      }
    }
    if liveChanged { Task { await apply() } }
  }

  private func pausedReason(_ unit: Unit) -> String? {
    interruption ?? (unit.liveOff ? Self.liveOffReason : nil)
  }

  private func engineSettings(_ setup: CameraSetup) -> CameraEngine.Settings {
    CameraEngine.Settings(format: setup.video.format, sensitivity: setup.sensitivity, zone: setup.zone)
  }

  private func info(_ setup: CameraSetup, engine: CameraEngine) -> CameraInfo {
    let format = setup.video.format
    let zone = setup.zone.map { CameraBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    var power: String?
    if let battery = Battery.current {
      let level = Int((battery.level * 100).rounded())
      power = battery.isCharging ? String(localized: "Charging · \(level)%") : String(localized: "On battery · \(level)%")
    }
    return CameraInfo(
      name: SystemInfo.deviceName, camera: engine.device.name, width: format.width, height: format.height, fps: format.fps,
      motion: engine.motion, sensitivity: setup.sensitivity, storage: settings.storage.target.rawValue, place: setup.place,
      codec: format.codec.rawValue, bitrate: format.bitrate, viewers: nil, paused: interruption, zone: zone,
      device: "\(Self.deviceKind) · \(Self.systemName) \(SystemInfo.osVersion)", power: power)
  }

  private static var systemName: String {
#if os(macOS)
    "macOS"
#elseif os(visionOS)
    "visionOS"
#else
    Self.deviceKind == "iPad" ? "iPadOS" : "iOS"
#endif
  }

  /// Mac, iPhone or iPad
  static var deviceKind: String {
#if os(macOS)
    "Mac"
#elseif os(iOS)
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
#else
    "device"
#endif
  }

  private func hubStorage(_ hub: Hub) -> CameraHubStorage {
    CameraHubStorage(
      write: { @MainActor key in try await hub.client.send("s3/write", key) },
      read: { @MainActor key in try await hub.client.send("s3/read", key) },
      delete: { @MainActor key in try await hub.client.send("s3/delete", key) },
      updated: { @MainActor folder in try await hub.client.send("s3/updated", folder) })
  }

  /// Each camera's clips, thumbnails and event index, in a folder named after its id
  static var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Camera", directoryHint: .isDirectory)
  }

  // MARK: Hub Network

  /// Shares a camera's server port on the hub's network: everyone on the hub may connect (the owner can narrow it on
  /// the Network page), behind its password. The share's attestation is this device's own: its Hub Network
  /// membership is registered with the key it connects with.
  private func publish(_ unit: Unit, on hub: Hub) async {
    guard hub.net.isJoined else {
      setPublished(unit, false, problem: String(localized: "Turn on Hub Network on this \(Self.deviceKind) so your other devices can reach the camera."))
      return
    }
    let identity = hub.identity
    hub.service.network.setAttestationProvider { share, serviceKey, _ in
      try CameraShareAttestation.attest(share, serviceKey: serviceKey, identity: identity)
    }
    if !reconnectHandlers.contains(hub.id) {
      reconnectHandlers.insert(hub.id)
      hub.service.network.onReconnect { [weak self, weak hub] publications in
        guard let self, let hub, hub.id == self.hubID else { return }
        for unit in self.units.values {
          guard let resourceId = unit.resourceId else { continue }
          self.setPublished(unit, publications.contains { $0.resourceId == resourceId }, problem: nil)
        }
      }
    }
    do {
      let publications = try await hub.service.network.publish(
        NetworkShare(name: unit.shareName, protocol: .tcp, target: LocalTarget(port: unit.port), policy: .hub))
      unit.resourceId = hub.service.network.publication(forShare: unit.shareName)?.resourceId
      setPublished(unit, unit.resourceId.map { id in publications.contains { $0.resourceId == id } } ?? false, problem: nil)
    } catch {
      setPublished(unit, false, problem: String(localized: "Hub Network didn’t take the camera’s share: \(error.localizedDescription)"))
    }
  }

  private func setPublished(_ unit: Unit, _ published: Bool, problem: String?) {
    unit.isPublished = published
    unit.shareProblem = published ? nil : problem ?? unit.shareProblem
    unit.server.setPublished(published)
  }

  /// Fails closed while the hub is away: the shares are gone from the hub then, so the servers stop answering until
  /// the reconnected hub has them again. Also follows motion, viewers, the budget and the CPU for the pages.
  private func watchConnection(_ hub: Hub) {
    watch?.cancel()
    watch = Task { [weak self, weak hub] in
      var wasConnected = hub?.isConnected ?? false
      var wasJoined = hub?.net.isJoined ?? false
      var cpu = CPUClock()
      var tick = 0
      while !Task.isCancelled, let self, let hub {
        let connected = hub.isConnected
        let joined = hub.net.isJoined
        for unit in self.units.values {
          if !connected, unit.isPublished {
            self.setPublished(unit, false, problem: "\(hub.settings.name) isn’t connected.")
          }
          // Joined later, or a publication failed while the hub was away: try again
          if connected, joined, !unit.isPublished, !wasConnected || !wasJoined || unit.shareProblem != nil {
            await self.publish(unit, on: hub)
          }
          unit.motion = unit.engine.motion
          if let problem = await unit.recorder.lastError { unit.storageProblem = problem }
        }
        wasConnected = connected
        wasJoined = joined
        tick += 1
        if tick % 2 == 0 {
          for unit in self.units.values { unit.viewers = unit.server.viewers }
          let share = cpu.share()
          if let share, let current = self.cpuShare, abs(share - current) > 0.03 { self.previousCPUShare = current }
          self.cpuShare = share
          let rig = self.rig
          let budget = await Task.detached { rig.budget }.value
          if budget.hardwareCost != self.budget.hardwareCost || budget.pressure != self.budget.pressure { self.budget = budget }
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
}

/// Which engine takes which lens's frames, read on the capture queues
private final class EngineRouter: @unchecked Sendable {
  private let lock = NSLock()
  private var engines: [String: CameraEngine] = [:]

  func set(_ engines: [String: CameraEngine]) { lock.withLock { self.engines = engines } }
  func engine(for device: String) -> CameraEngine? { lock.withLock { engines[device] } }
}

/// A camera's info as the server answers it, changed by the settings while it runs
final class CameraInfoBox: @unchecked Sendable {
  private let lock = NSLock()
  private var info: CameraInfo
  init(_ info: CameraInfo) { self.info = info }
  var value: CameraInfo {
    get { lock.withLock { info } }
    set { lock.withLock { info = newValue } }
  }
}

/// This process's share of all the CPU between two readings
private struct CPUClock {
  private var last: (cpu: Double, wall: Double)?

  mutating func share() -> Double? {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
    let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    let wall = ProcessInfo.processInfo.systemUptime
    defer { last = (cpu, wall) }
    guard let last, wall > last.wall else { return nil }
    return min(1, (cpu - last.cpu) / (wall - last.wall) / Double(ProcessInfo.processInfo.activeProcessorCount))
  }
}

/// A share's attestation signed by this app's own key, the key of this device's Hub Network membership: what a
/// machine's agent (`LocalShareAgent`) signs for the services it fronts, here for the app's own server
enum CameraShareAttestation {
  static func attest(_ share: NetworkShare, serviceKey: String, identity: KeyChain) throws -> AgentAttestation {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = Date()
    DevicePorts.main.noteAttested(protocol: share.protocol.rawValue, port: share.target.port)
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
