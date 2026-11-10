//
//  Device storage.swift
//  Hub
//
//  This Device's Storage: the app is an S3 server on one hub, so an iPhone, iPad or Mac (an old one kept awake with
//  Farm) shares part of its storage. Off until the user turns it on. It serves a folder in the app's container (kept out
//  of backups) as the bucket `hub` with S3ServerSwift, up to a size limit, on the port it had last time where it's
//  free. The server answers only this device and Hub Network, and the hub's devices reach it through a Hub Network
//  share (`s3`) whose attestation the app signs, as the security camera's. On the hub it answers hub-s3-local's API
//  (Storage backend.swift), so the hub lists it as an `s3/write` provider: the Files page, cameras' clips and
//  hub-s3-raid (which counts an iPhone or iPad as a `mobile` node) use it like any storage.
//

#if canImport(S3ServerSwift)
import ComponentKit
import Foundation
import HubService
import S3ServerSwift

@MainActor @Observable
final class DeviceStorage {
  static let main = DeviceStorage()
  static let shareName = "s3"
  /// Decimal, as the sizes the app shows (ByteCountFormatter's)
  static let gigabyte: Int64 = 1_000_000_000

  enum Phase: Equatable {
    case off
    case starting
    case on
    case failed(String)
  }

  struct Settings: Codable, Hashable, Sendable {
    var isOn = false
    /// The hub the storage is on
    var hub: URL?
    /// Bytes the hub's devices may fill; 0 until it's first turned on
    var limit: Int64 = 0
    /// The server's port last time, taken again where it's free
    var port: UInt16 = 0
  }

  private(set) var phase = Phase.off
  var settings: Settings {
    didSet {
      guard settings != oldValue else { return }
      if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
      if settings.limit != oldValue.limit { backend?.set(limit: settings.limit) }
    }
  }
  /// Bytes the folder takes
  private(set) var usedBytes: Int64 = 0
  /// The volume the folder is on
  private(set) var volume = StorageVolume(DeviceStorage.folder)
  /// Shared on Hub Network: the hub's devices can reach the server and get links
  private(set) var isPublished = false
  /// Why other devices can't reach the storage, while they can't
  private(set) var shareProblem: String?
  private(set) var port: UInt16?

  private var server: S3Server?
  private var backend: StorageBackend?
  /// What the hub's calls reach, on every hub the storage was on in this run
  private let current = StorageBackendBox()
  private var groups: [Hub.ID: HubService.Group] = [:]
  private var reconnectHandlers = Set<Hub.ID>()
  private var watch: Task<Void, Never>?
  private var changing = false

  var isOn: Bool { phase == .on || phase == .starting }
  var hub: Hub? { settings.hub.flatMap { id in Hubs.main.list.first { $0.id == id } } }

  private static let settingsKey = "storage.settings"

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.settingsKey), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
      settings = saved
    } else {
      settings = Settings()
    }
  }

  /// The shared folder: in Application Support, kept out of iCloud and device backups (it can be large)
  static var folder: URL {
    URL.applicationSupportDirectory.appending(path: "Storage", directoryHint: .isDirectory)
  }

  /// A limit for a first start: a quarter of the free space, 1 GB at least and 100 GB at most, in whole gigabytes
  static func defaultLimit(free: Int64?) -> Int64 {
    let quarter = (free ?? 0) / 4
    return min(max(quarter / gigabyte, 1), 100) * gigabyte
  }

  /// The most the limit can be: what's used plus what's free
  var largestLimit: Int64 {
    max(Self.gigabyte, ((usedBytes + (volume.free ?? 0)) / Self.gigabyte) * Self.gigabyte)
  }

  // MARK: On and off

  /// At launch: back on where the user left it on, once its hub is in the list
  func restore() {
    guard phase == .off, settings.isOn, let hub else { return }
    Task { await turnOn(hub: hub) }
  }

  /// Back in front on iPhone and iPad: a listener iOS ended while the app was suspended listens again
  func resume() async {
    guard phase == .on, let server, !(await server.isRunning), let hub else { return }
    await restartServer(on: hub)
  }

  func turnOn(hub: Hub) async {
    guard !changing else { return }
    if isOn, settings.hub != hub.id { await turnOff() }
    guard !isOn else { return }
    changing = true
    defer { changing = false }
    phase = .starting
    settings.hub = hub.id
    settings.isOn = true
    do {
      try prepareFolder()
      volume = StorageVolume(Self.folder)
      if settings.limit == 0 { settings.limit = Self.defaultLimit(free: volume.free) }
      let backend = try StorageBackend(folder: Self.folder, limit: settings.limit)
      self.backend = backend
      try await startServer(backend)
      current.set(backend)
      register(on: hub)
      phase = .on
      await countUsage()
      await publish(on: hub)
      watchConnection(hub)
    } catch {
      await stopServer()
      phase = .failed(error.localizedDescription)
    }
  }

  func turnOff() async {
    settings.isOn = false
    phase = .off
    watch?.cancel()
    watch = nil
    current.set(nil)
    for group in groups.values { group.isEnabled = false }
    if let hub, hub.isConnected, isPublished {
      _ = try? await hub.service.network.remove(Self.shareName)
    }
    isPublished = false
    shareProblem = nil
    await stopServer()
  }

  /// Bytes the hub's devices may fill, from now on; what's stored stays
  func setLimit(_ bytes: Int64) {
    settings.limit = max(Self.gigabyte, bytes)
  }

  private func prepareFolder() throws {
    var folder = Self.folder
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try folder.setResourceValues(values)
  }

  private func startServer(_ backend: StorageBackend) async throws {
    let server: S3Server
    do {
      server = try await Self.listen(backend, port: settings.port)
    } catch where settings.port != 0 {
      server = try await Self.listen(backend, port: 0)
    }
    self.server = server
    let port = await server.boundPort ?? 0
    self.port = port
    settings.port = port
    backend.set(port: port, endpoint: Self.directEndpoint)
  }

  private static func listen(_ backend: StorageBackend, port: UInt16) async throws -> S3Server {
    let options = try StorageBackend.options(folder: backend.folder, port: port, key: backend.accessKeyID, secret: backend.secretAccessKey)
    let server = S3Server(options: options, hooks: backend.hooks)
    try await server.start()
    return server
  }

  private func stopServer() async {
    await server?.stop()
    server = nil
    backend = nil
    port = nil
  }

  /// A new listener after iOS ended the old one, on the same port where it's free (then the share stays as it is)
  private func restartServer(on hub: Hub) async {
    guard let backend else { return }
    let old = port
    await server?.stop()
    do {
      try await startServer(backend)
    } catch {
      phase = .failed(error.localizedDescription)
      return
    }
    if port != old {
      isPublished = false
      await publish(on: hub)
    }
  }

  /// Counts the folder's bytes off the main actor, for the limit
  private func countUsage() async {
    guard let backend else { return }
    let used = await Task.detached { (try? backend.storage.usedBytes(bucket: StorageBackend.bucket)) ?? 0 }.value
    backend.set(used: used)
    usedBytes = used
  }

  // MARK: Hub

  /// The hub-s3-local API on `hub`'s connection, registered once and turned on and off with the storage
  private func register(on hub: Hub) {
    for (id, group) in groups where id != hub.id { group.isEnabled = false }
    if let group = groups[hub.id] {
      group.isEnabled = true
    } else {
      groups[hub.id] = hub.service.group(enabled: true).storageService(current)
      hub.service.sendServiceUpdates()
    }
  }

  /// Shares the server's port on the hub's network: everyone on the hub may connect (the owner can narrow it on the
  /// Network page); links carry their signature, so reaching the port isn't enough
  private func publish(on hub: Hub) async {
    guard let port, phase == .on else { return }
    guard hub.net.isJoined else {
      setPublished(nil, problem: String(localized: "Turn on Hub Network on this \(KitDevice.nameInSentence) so your other devices can reach its storage."))
      return
    }
    AppShareAttestation.provide(for: hub)
    if !reconnectHandlers.contains(hub.id) {
      reconnectHandlers.insert(hub.id)
      hub.service.network.onReconnect { [weak self, weak hub] _ in
        guard let self, let hub, hub.id == self.settings.hub, self.phase == .on else { return }
        self.setPublished(hub.service.network.publication(forShare: Self.shareName), problem: nil)
      }
    }
    do {
      try await hub.service.network.publish(
        NetworkShare(name: Self.shareName, protocol: .tcp, target: LocalTarget(port: port), policy: .hub))
      setPublished(hub.service.network.publication(forShare: Self.shareName), problem: nil)
    } catch {
      setPublished(nil, problem: String(localized: "Hub Network didn’t take the storage’s share: \(error.localizedDescription)"))
    }
  }

  private func setPublished(_ publication: NetworkSharePublication?, problem: String?) {
    isPublished = publication != nil
    shareProblem = publication != nil ? nil : problem ?? shareProblem
    backend?.set(publication: publication)
  }

  /// Fails closed while the hub is away (its shares are gone from it then), publishes again once it's back on Hub
  /// Network, listens again after a suspension, and follows the used and free space for the page
  private func watchConnection(_ hub: Hub) {
    watch?.cancel()
    watch = Task { [weak self, weak hub] in
      var wasConnected = hub?.isConnected ?? false
      var wasJoined = hub?.net.isJoined ?? false
      var tick = 0
      while !Task.isCancelled, let self, let hub, self.phase == .on {
        let connected = hub.isConnected
        let joined = hub.net.isJoined
        if !connected, self.isPublished {
          self.setPublished(nil, problem: String(localized: "\(hub.settings.name) isn’t connected."))
        }
        if connected, joined, !self.isPublished, !wasConnected || !wasJoined || self.shareProblem != nil, tick % 5 == 0 {
          await self.publish(on: hub)
        }
        if connected, !joined, self.isPublished || self.shareProblem == nil {
          self.setPublished(nil, problem: String(localized: "Turn on Hub Network on this \(KitDevice.nameInSentence) so your other devices can reach its storage."))
        }
        wasConnected = connected
        wasJoined = joined
        if let backend = self.backend { self.usedBytes = backend.usedBytes }
        if tick % 10 == 0 {
          self.volume = StorageVolume(Self.folder)
          if let server = self.server, !(await server.isRunning) { await self.restartServer(on: hub) }
        }
        tick += 1
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// Debug: `--storage-endpoint http://127.0.0.1` presigns against that origin (the server's port when it names
  /// none) instead of the Hub Network share, like hub-s3-local's S3_LOCAL_ENDPOINT, for simulators that share the
  /// Mac's loopback
  private static var directEndpoint: URL? {
#if DEBUG
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--storage-endpoint"), index + 1 < arguments.count else { return nil }
    return URL(string: arguments[index + 1])
#else
    nil
#endif
  }
}

/// The running storage's backend, for the hub's calls on any thread; nil while the storage is off
final class StorageBackendBox: @unchecked Sendable {
  private let lock = NSLock()
  private var backend: StorageBackend?

  func set(_ backend: StorageBackend?) {
    lock.withLock { self.backend = backend }
  }

  func get() throws -> StorageBackend {
    guard let backend = lock.withLock({ backend }) else { throw HubError.unavailable(StorageError.off.localizedDescription) }
    return backend
  }
}

extension HubService.Group {
  /// hub-s3-local's API (its README's table and descriptions) over This Device's Storage. Every path asks the hub
  /// whether its caller holds a grant of that same path: owners pass, others need a grant, as on hub-s3-local.
  func storageService(_ box: StorageBackendBox) -> Self {
    func options(_ path: String, _ name: String, _ title: String, _ description: String) -> HubService.Options {
      .init(permissions: .init(group: "s3", name: name), permission: path, title: title, description: description)
    }
    /// Link failures read as hub-s3-local's ("Hub Network S3 share is not published")
    @Sendable func link(_ method: String, _ path: String) throws -> String {
      do {
        return try box.get().link(method: method, key: path)
      } catch let error as StorageError {
        throw HubError.unavailable(error.localizedDescription)
      }
    }
    return post("s3/read", options: options("s3/read", "Read files", "Download link",
      "A presigned GET URL for one file this device shares, valid for 7 days; anyone who holds it and reaches the Hub Network share can download the file. It does not check that the file exists, and fails with \"Hub Network S3 share is not published\" until the share is live. Owners and callers granted s3/read may call it.")
    ) { (path: String) -> String in
      try link("GET", path)
    }
    .post("s3/write", options: options("s3/write", "Upload files", "Upload link",
      "A presigned PUT URL for one file this device shares, valid for 7 days: PUT the bytes to it; s3/list streams show the file once it's stored. Anyone who holds it and reaches the share can upload or overwrite that file, within the device's size limit (507 past it); fails with \"Hub Network S3 share is not published\" until the share is live. Owners and callers granted s3/write may call it.")
    ) { (path: String) -> String in
      try link("PUT", path)
    }
    .post("s3/read/directory", options: options("s3/read/directory", "Read files", "List files recursively",
      "Every file under a prefix, at every level, with full paths; an empty or absent prefix lists the whole shared folder. One listing: at most 1000 files, no paging. Owners and callers granted s3/read/directory may call it.")
    ) { (prefix: String?) -> [StorageFileInfo] in
      try box.get().readDirectory(prefix)
    }
    .post("s3/size", options: options("s3/size", "Read files", "File size",
      "Size of one file in bytes. Fails when the file does not exist. Owners and callers granted s3/size may call it.")
    ) { (path: String) -> Int64 in
      try box.get().size(path)
    }
    .post("s3/list", options: options("s3/list", "Read files", "List a folder",
      "One folder level: the files directly in a folder and its subfolders, from one listing (at most 1000 entries). The s3/list stream follows the same listing. Owners and callers granted s3/list may call it.")
    ) { (prefix: String?) -> StorageFiles in
      try box.get().list(prefix)
    }
    .post("s3/delete", options: options("s3/delete", "Delete files", "Delete a file or folder",
      "Deletes one file, or every file under a path ending in \"/\" (from one listing: at most 1000 files per call), and refreshes the s3/list streams. Answers nothing. Owners and callers granted s3/delete may call it.")
    ) { (path: String) in
      try box.get().delete(path)
    }
    .post("s3/updated", options: options("s3/updated", "Upload files", "Refresh folder listings",
      "Tells the s3/list streams of a folder to list it again. Uploads through s3/write URLs refresh them on their own here; hub-s3-local needs this call after them. Pass the folder exactly as the streams follow it (\"photos/\"), or nothing to refresh every stream. Owners and callers granted s3/updated may call it.")
    ) { (path: String?) in
      try box.get().notify(folder: path)
    }
    .post("s3/space", options: options("s3/space", "Read files", "Space",
      "The bytes this device lets the hub fill (its Storage limit) and what's left of them, after what's stored, uploads on their way and the 1 GB the device keeps free: { total, free }. hub-s3-raid sizes the device by it. Owners and callers granted s3/space may call it.")
    ) { (_: String?) -> StorageSpace in
      try box.get().space()
    }
    .post("s3/update/status", options: options("s3/update/status", "Upload files", "Set upload status",
      "Sets or clears the status of one file in the s3/status stream, like upload progress; leave out status to clear it. Kept in memory until the storage stops. Owners and callers granted s3/update/status may call it.")
    ) { (update: StorageStatusUpdate) in
      try box.get().update(update)
    }
    .stream("s3/list", options: options("s3/list", "Read files", "Watch a folder",
      "One folder level, like the s3/list post, sent again when it changes: uploads, s3/delete and s3/updated. Owners and callers granted s3/list may call it.")
    ) { (prefix: String?, continuation) in
      let backend = try box.get()
      let folder = prefix ?? ""
      try await StorageBackend.stream(continuation, subscribe: { backend.watch(folder: folder, $0) }, unsubscribe: backend.unwatch) {
        try backend.list(folder)
      }
    }
    .stream("s3/status", options: options("s3/status", "Read files", "Watch upload status",
      "The status of every file that has one, as a map from file path to status, sent again on every s3/update/status. Owners and callers granted s3/status may call it.")
    ) { continuation in
      let backend = try box.get()
      try await StorageBackend.stream(continuation, subscribe: backend.watchStatuses, unsubscribe: backend.unwatch) {
        backend.currentStatuses
      }
    }
  }
}
#endif
