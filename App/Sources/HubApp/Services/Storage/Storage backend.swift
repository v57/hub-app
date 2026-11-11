//
//  Storage backend.swift
//  Hub
//
//  What This Device's Storage answers its hub with, off the main actor: the paths of hub-s3-local (`s3/read` and
//  `s3/write` presign, `s3/read/directory`, `s3/size`, `s3/list` and its stream, `s3/delete`, `s3/updated`,
//  `s3/update/status`, `s3/status`), and `s3/space` for hub-s3-raid, over the folder S3ServerSwift serves as the
//  bucket `hub`. Links are presigned against the Hub Network share's overlay address and port and fail closed until
//  the share is published; they carry no ACL. The size limit is kept here: uploads past it are
//  refused before their body, and uploads on their way hold their room until they end.
//

#if canImport(S3ServerSwift)
import Foundation
import HubService
import S3ServerSwift

/// `s3/list`: one level of a folder, as hub-s3-local answers it (names relative to the folder)
struct StorageFiles: Codable, Equatable, Sendable {
  var count: Int
  var files: [StorageFileInfo]
  var directories: [String]
}

struct StorageFileInfo: Codable, Equatable, Sendable {
  var name: String
  var size: Int64
  /// ISO 8601 with milliseconds, as S3 listings have it
  var lastModified: String?
}

/// `s3/space`: what the hub may fill in all, and what's left
struct StorageSpace: Codable, Equatable, Sendable {
  var total: Int64
  var free: Int64
}

/// An upload's state that `s3/update/status` sets and `s3/status` streams
struct StorageFileStatus: Codable, Equatable, Sendable {
  var name: String
  var progress: Double
}

struct StorageStatusUpdate: Codable, Sendable {
  var path: String
  var status: StorageFileStatus?
}

enum StorageError: LocalizedError, Equatable {
  case notPublished
  case invalidShare(String)
  case off

  var errorDescription: String? {
    switch self {
    // hub-s3-local's words, which callers may match
    case .notPublished: "Hub Network S3 share is not published"
    case .invalidShare(let detail): "Hub Network S3 share returned \(detail)"
    case .off: "Storage is off on this device"
    }
  }
}

/// The storage one running server serves: its files, its links, its limit and its watchers. Thread-safe; the hub's
/// calls and the server's hooks come from any thread.
final class StorageBackend: @unchecked Sendable {
  static let bucket = "hub"
  /// Links last 7 days, as hub-s3-local's
  static let linkLifetime = 7 * 24 * 3600
  /// Room an upload leaves on the device's volume, whatever the limit says
  static let reserve: Int64 = 1_000_000_000

  let storage: S3Storage
  let folder: URL
  let accessKeyID: String
  let secretAccessKey: String
  private let lock = NSLock()
  private var port: UInt16 = 0
  private var endpoint: URL?
  private var publication: NetworkSharePublication?
  private var used: Int64 = 0
  /// Uploads let in and not ended yet, each holding its room until it ends
  private var uploading: [S3Upload] = []
  private var limit: Int64
  private var statuses: [String: StorageFileStatus] = [:]
  private var folderWatchers: [UUID: (folder: String, changed: @Sendable () -> Void)] = [:]
  private var statusWatchers: [UUID: @Sendable () -> Void] = [:]
  /// Free bytes on the folder's volume; replaced in tests
  var freeSpace: @Sendable () -> Int64?

  init(folder: URL, limit: Int64, accessKeyID: String = StorageBackend.randomKey(), secretAccessKey: String = StorageBackend.randomKey()) throws {
    self.folder = folder
    self.limit = limit
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    storage = S3Storage(options: try Self.options(folder: folder, port: 0, key: accessKeyID, secret: secretAccessKey))
    freeSpace = { StorageVolume(folder).free }
  }

  /// The server's options: every address of both families (the overlay's comes and goes with the tunnel; the hooks
  /// answer only this device and Hub Network), the folder as the bucket `hub`, keys that never leave this process
  static func options(folder: URL, port: UInt16, key: String, secret: String) throws -> S3ServerOptions {
    try S3ServerOptions(host: "::", port: port, bucketPaths: [bucket: folder.path], key: key, secret: secret)
  }

  /// 32 random bytes in hex, like hub-s3-local's keys, new on every start
  static func randomKey() -> String {
    (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
  }

  var hooks: S3ServerHooks {
    S3ServerHooks(
      acceptsConnection: { StorageBackend.isAllowed($0) },
      admitUpload: { [weak self] upload in self?.admit(upload) },
      changed: { [weak self] change in self?.changed(change) },
      uploadEnded: { [weak self] upload in self?.ended(upload) })
  }

  // MARK: State

  func set(port: UInt16, endpoint: URL?) {
    lock.withLock {
      self.port = port
      self.endpoint = endpoint
    }
  }

  func set(publication: NetworkSharePublication?) {
    lock.withLock { self.publication = publication }
  }

  func set(limit: Int64) {
    lock.withLock { self.limit = limit }
  }

  func set(used: Int64) {
    lock.withLock { self.used = used }
  }

  var usedBytes: Int64 { lock.withLock { used } }
  var limitBytes: Int64 { lock.withLock { limit } }

  // MARK: Limit

  /// Refuses an upload that would take the folder past the limit, or leave the device with less than the reserve,
  /// counting the uploads still on their way; one it lets in holds its room until it ends
  func admit(_ upload: S3Upload) -> S3Error? {
    let free = freeSpace()
    return lock.withLock {
      let growth = upload.length - upload.replacedSize
      let held = uploading.reduce(Int64(0)) { $0 + max(0, $1.length - $1.replacedSize) }
      if growth > 0, used + held + growth > limit {
        return .storageFull("The storage this device shares is full (\(Self.format(used + held)) of \(Self.format(limit)))")
      }
      let writing = uploading.reduce(Int64(0)) { $0 + $1.length }
      if let free, free - writing - upload.length < Self.reserve {
        return .storageFull("This device is almost out of space (\(Self.format(max(0, free - writing))) free)")
      }
      uploading.append(upload)
      return nil
    }
  }

  /// `s3/space`: the limit, and the room under it that `admit` would let in
  func space() -> StorageSpace {
    let free = freeSpace()
    return lock.withLock {
      let held = uploading.reduce(Int64(0)) { $0 + max(0, $1.length - $1.replacedSize) }
      let writing = uploading.reduce(Int64(0)) { $0 + $1.length }
      var room = limit - used - held
      if let free { room = min(room, free - writing - Self.reserve) }
      return StorageSpace(total: limit, free: max(0, room))
    }
  }

  /// An upload ended, stored or not: its room is free again (a stored one is in `used` by now)
  func ended(_ upload: S3Upload) {
    lock.withLock {
      if let index = uploading.firstIndex(of: upload) { uploading.remove(at: index) }
    }
  }

  private func changed(_ change: S3Change) {
    switch change {
    case let .stored(_, key, size, replaced):
      lock.withLock { used += size - replaced }
      notify(key: key)
    case let .deleted(_, key, size):
      lock.withLock { used = max(0, used - size) }
      notify(key: key)
    }
  }

  static func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  // MARK: Hub API

  /// `s3/read` and `s3/write`: a presigned link through the Hub Network share
  func link(method: String, key: String) throws -> String {
    let (port, endpoint, publication) = lock.withLock { (self.port, self.endpoint, self.publication) }
    guard port != 0 else { throw StorageError.off }
    let origin = try endpoint.map { Self.direct($0, port: port) } ?? Self.overlayEndpoint(publication)
    let presigner = S3Presigner(endpoint: origin, bucket: Self.bucket, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
    return presigner.url(method: method, key: key, expires: Self.linkLifetime).absoluteString
  }

  /// The share's overlay address and port, over TCP. Not its `*.hub.invalid` authority, as hub-s3-local presigns: an
  /// Apple device's tunnel answers only the names its profile was installed with, so no Apple client resolved it, the
  /// hub's own Mac included, and `URLSession` timed out. The address reaches the device the same way, through the
  /// member's link or the hub's machine, as the camera's viewers connect.
  static func overlayEndpoint(_ publication: NetworkSharePublication?) throws -> URL {
    guard let publication else { throw StorageError.notPublished }
    guard publication.protocol == .tcp else {
      throw StorageError.invalidShare("unsupported protocol '\(publication.protocol.rawValue)'")
    }
    guard publication.port > 0 else { throw StorageError.invalidShare("invalid port '\(publication.port)'") }
    let address = publication.overlayAddress
    guard isOverlay(address) else { throw StorageError.invalidShare("invalid overlay address '\(address)'") }
    var components = URLComponents()
    components.scheme = "http"
    components.host = address.contains(":") ? "[\(address)]" : address
    components.port = Int(publication.port)
    guard let url = components.url else { throw StorageError.invalidShare("invalid overlay address '\(address)'") }
    return url
  }

  /// A direct origin (Debug's `--storage-endpoint`), with the server's port when it names none
  static func direct(_ endpoint: URL, port: UInt16) -> URL {
    guard endpoint.port == nil, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return endpoint }
    components.port = Int(port)
    components.path = ""
    return components.url ?? endpoint
  }

  /// `s3/list`: one level under `prefix` (a folder ending in `/`, or nothing)
  func list(_ prefix: String?) throws -> StorageFiles {
    let prefix = prefix ?? ""
    let listing = try storage.list(bucket: Self.bucket, prefix: prefix, delimiter: "/")
    let files = listing.objects.map { StorageFileInfo(name: String($0.key.dropFirst(prefix.count)), size: $0.size, lastModified: $0.lastModified) }
    let directories = listing.commonPrefixes.map { String($0.dropFirst(prefix.count)) }
    return StorageFiles(count: files.count + directories.count, files: files, directories: directories)
  }

  /// `s3/read/directory`: every file under `prefix`, full keys, at most 1000
  func readDirectory(_ prefix: String?) throws -> [StorageFileInfo] {
    try storage.list(bucket: Self.bucket, prefix: prefix ?? "").objects.map {
      StorageFileInfo(name: $0.key, size: $0.size, lastModified: $0.lastModified)
    }
  }

  /// `s3/size`
  func size(_ key: String) throws -> Int64 {
    do {
      return try storage.size(bucket: Self.bucket, key: key)
    } catch let error as S3Error where error.code == "NoSuchKey" {
      throw HubError.notFound("No such file: \(key)")
    }
  }

  /// `s3/delete`: a file, or every file in a folder (`path` ending in `/`, up to 1000 per call)
  func delete(_ path: String) throws {
    let keys = path.hasSuffix("/") ? try storage.list(bucket: Self.bucket, prefix: path).objects.map(\.key) : [path]
    for key in keys {
      do {
        let size = try storage.delete(bucket: Self.bucket, key: key)
        lock.withLock { used = max(0, used - size) }
      } catch let error as S3Error where error.code == "NoSuchKey" {
        // Gone already, as S3's DELETE of a missing key
      }
      notify(key: key)
    }
    if path.hasSuffix("/") { notify(folder: path) }
  }

  /// `s3/update/status`
  func update(_ update: StorageStatusUpdate) {
    let watchers = lock.withLock {
      statuses[update.path] = update.status
      return Array(statusWatchers.values)
    }
    watchers.forEach { $0() }
  }

  var currentStatuses: [String: StorageFileStatus] { lock.withLock { statuses } }

  // MARK: Watching

  /// Calls `changed` whenever `folder`'s listing may have changed, until the returned token is cancelled
  func watch(folder: String, _ changed: @escaping @Sendable () -> Void) -> UUID {
    let id = UUID()
    lock.withLock { folderWatchers[id] = (folder, changed) }
    return id
  }

  func watchStatuses(_ changed: @escaping @Sendable () -> Void) -> UUID {
    let id = UUID()
    lock.withLock { statusWatchers[id] = changed }
    return id
  }

  func unwatch(_ id: UUID) {
    lock.withLock {
      folderWatchers[id] = nil
      statusWatchers[id] = nil
    }
  }

  /// `s3/updated`: the listings of `folder` (nil: every listing)
  func notify(folder: String?) {
    let watchers = lock.withLock { folderWatchers.values.filter { folder == nil || $0.folder == folder } }
    watchers.forEach { $0.changed() }
  }

  /// A key changed: the listings of every folder above it
  func notify(key: String) {
    let folders = Set(Self.folders(above: key))
    let watchers = lock.withLock { folderWatchers.values.filter { folders.contains($0.folder) } }
    watchers.forEach { $0.changed() }
  }

  /// `a/b/c.txt` → `a/b/`, `a/`, `` (the top level)
  static func folders(above key: String) -> [String] {
    var parts = key.split(separator: "/", omittingEmptySubsequences: false).dropLast()
    var folders = [""]
    while !parts.isEmpty {
      folders.append(parts.joined(separator: "/") + "/")
      parts = parts.dropLast()
    }
    return folders
  }

  /// A stream of `value()` now and after every change `subscribe` reports, without repeats
  static func stream<Value: Encodable & Equatable & Sendable>(
    _ continuation: AsyncThrowingStream<Encodable & Sendable, Error>.Continuation,
    subscribe: (@escaping @Sendable () -> Void) -> UUID, unsubscribe: (UUID) -> Void, value: @escaping @Sendable () throws -> Value
  ) async throws {
    let (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let id = subscribe { changed.yield() }
    defer { unsubscribe(id) }
    var last = try value()
    continuation.yield(last)
    for await _ in changes {
      try Task.checkCancellation()
      let next = try value()
      guard next != last else { continue }
      last = next
      continuation.yield(next)
    }
  }

  // MARK: Addresses

  /// Hub Network's overlay (100.64.0.0/10 holds the hub's 100.96.0.0/11; fd48:5542:4e45::/48) or this device, as the
  /// camera's server answers
  static func isAllowed(_ address: String) -> Bool {
    address == "127.0.0.1" || address == "::1" || isOverlay(address)
  }

  /// An address in Hub Network's overlay
  static func isOverlay(_ address: String) -> Bool {
    if address.lowercased().hasPrefix("fd48:5542:4e45:") { return true }
    let octets = address.split(separator: ".").compactMap { UInt8($0) }
    return octets.count == 4 && octets[0] == 100 && octets[1] & 0xC0 == 64
  }
}

/// The volume a folder is on: its free and total bytes
struct StorageVolume {
  var free: Int64?
  var total: Int64?

  init(_ folder: URL) {
    var url = folder
    // The folder may not exist yet: its nearest existing parent is on the same volume
    while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
      url.deleteLastPathComponent()
    }
#if os(macOS) || os(iOS)
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    free = values?.volumeAvailableCapacityForImportantUsage
#else
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
    free = values?.volumeAvailableCapacity.map(Int64.init)
#endif
    total = values?.volumeTotalCapacity.map(Int64.init)
  }
}
#endif
