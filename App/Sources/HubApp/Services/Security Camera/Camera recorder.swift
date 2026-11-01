//
//  Camera recorder.swift
//  Hub
//
//  Records a clip around each motion event: from a few seconds before the motion started (the engine's fragmented
//  MP4 prebuffer) until `postRoll` seconds after it ended, at most `maximumClip` seconds per clip. Clips are fragmented
//  MP4 files in the camera's folder, with a JPEG thumbnail and an index (events.json); with Hub storage chosen, a
//  finished clip is uploaded to the hub's S3 service (`s3/write` gives a presigned PUT URL, then `s3/updated`) and the
//  device keeps only the thumbnail. Old clips go by age and by total size.
//

#if canImport(PlatformCamera)
import Foundation
import PlatformCamera

/// Where clips are kept, and for how long
struct CameraStoragePolicy: Codable, Hashable, Sendable {
  enum Target: String, Codable, CaseIterable, Sendable {
    /// The camera device's own storage
    case device
    /// The hub's storage service (hub-s3, hub-s3-local, hub-s3-raid: whichever the hub runs)
    case hub
  }
  var target: Target = .device
  /// Clips older than this go; 0 keeps them
  var days: Int = 7
  /// The oldest clips go while all of them take more; 0 for no limit
  var gigabytes: Double = 5
  /// Seconds recorded after motion ends
  var postRoll: Double = 5
  /// Seconds recorded before motion starts
  var preRoll: Double = 4
}

/// The hub's storage, as the recorder uses it
struct CameraHubStorage: Sendable {
  /// A presigned PUT URL for the key
  var write: @Sendable (String) async throws -> URL
  /// A presigned GET URL for the key
  var read: @Sendable (String) async throws -> URL
  var delete: @Sendable (String) async throws -> Void
  /// Tells the storage service a folder changed
  var updated: @Sendable (String) async throws -> Void
}

actor CameraRecorder {
  static let maximumClip: Double = 10 * 60

  let folder: URL
  private(set) var events: [CameraEvent] = []
  private var policy: CameraStoragePolicy
  private var hubStorage: CameraHubStorage?
  /// The folder clips go to in the hub's storage
  private let hubFolder: String
  private var recording: Recording?
  private var stopping: Task<Void, Never>?
  private var watching: Task<Void, Never>?
  private var onChange: (@Sendable ([CameraEvent]) -> Void)?
  private(set) var lastError: String?
  /// No clips while paused (someone is using the Mac): motion is still detected, for the live view
  private(set) var isPaused = false

  private struct Recording {
    var id: String
    var file: FileHandle
    var task: Task<Void, Never>
  }

  init(folder: URL, policy: CameraStoragePolicy, hubFolder: String) {
    self.folder = folder
    self.policy = policy
    self.hubFolder = hubFolder
    try? FileManager.default.createDirectory(at: folder.appending(path: "Clips"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: folder.appending(path: "Thumbnails"), withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: folder.appending(path: "events.json")),
      let saved = try? JSONDecoder.camera.decode([CameraEvent].self, from: data)
    {
      // A clip that was recording when the app quit ends where its file ends, when it was last written
      events = saved.map { event in
        guard event.end == nil else { return event }
        var event = event
        let attributes = event.clip.flatMap { try? FileManager.default.attributesOfItem(atPath: folder.appending(path: "Clips/\($0)").path) }
        event.end = max(event.start, attributes?[.modificationDate] as? Date ?? event.start)
        event.size = attributes?[.size] as? Int ?? 0
        return event
      }
    }
  }

  func configure(policy: CameraStoragePolicy, hubStorage: CameraHubStorage?, onChange: (@Sendable ([CameraEvent]) -> Void)?) {
    self.policy = policy
    self.hubStorage = hubStorage
    self.onChange = onChange
    onChange?(events)
  }

  /// Records the engine's motion events until `stop()`
  func start(engine: CameraEngine) {
    watching?.cancel()
    let events = engine.motionEvents()
    watching = Task { [weak self] in
      for await event in events {
        await self?.motion(event, engine: engine)
      }
    }
    Task { await applyRetention() }
  }

  func stop() async {
    watching?.cancel()
    watching = nil
    stopping?.cancel()
    stopping = nil
    await finish()
  }

  /// Pausing ends the clip being recorded now; the next motion after resuming starts a new one
  func setPaused(_ paused: Bool) async {
    guard paused != isPaused else { return }
    isPaused = paused
    guard paused else { return }
    stopping?.cancel()
    stopping = nil
    await finish()
  }

  func thumbnail(_ id: String) -> URL? {
    let url = folder.appending(path: "Thumbnails/\(id).jpg")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// A local file of the event's clip: the device's own, or downloaded from the hub's storage (the caller deletes it
  /// when `isTemporary`)
  func clip(_ id: String) async throws -> (url: URL, isTemporary: Bool) {
    guard let event = events.first(where: { $0.id == id }), let clip = event.clip else { throw CameraRecorderError.noClip }
    if event.storage == CameraStoragePolicy.Target.device.rawValue {
      return (folder.appending(path: "Clips/\(clip)"), false)
    }
    guard let hubStorage else { throw CameraRecorderError.hubStorageUnavailable }
    let url = try await hubStorage.read(clip)
    let (download, _) = try await URLSession.shared.download(from: url)
    return (download, true)
  }

  /// Deletes a finished event's clip and thumbnail, wherever the clip is; false for an unknown or recording event
  func delete(_ id: String) async -> Bool {
    guard let index = events.firstIndex(where: { $0.id == id }), events[index].end != nil else { return false }
    let event = events.remove(at: index)
    await remove([event])
    changed()
    return true
  }

  // MARK: Recording

  private func motion(_ event: MotionEvent, engine: CameraEngine) async {
    if event.isActive {
      guard !isPaused else { return }
      stopping?.cancel()
      stopping = nil
      if recording == nil { await begin(engine: engine, peak: event.level) }
    } else if recording != nil {
      let postRoll = policy.postRoll
      stopping = Task { [weak self] in
        try? await Task.sleep(for: .seconds(postRoll))
        guard !Task.isCancelled else { return }
        await self?.finish()
      }
    }
  }

  private func begin(engine: CameraEngine, peak: Double) async {
    let now = Date()
    let id = Self.id(now)
    let clip = "\(id).mp4"
    let url = folder.appending(path: "Clips/\(clip)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil), let file = try? FileHandle(forWritingTo: url) else {
      lastError = "Couldn’t create a clip file."
      return
    }
    if let jpeg = try? await engine.snapshot(maxWidth: 480) {
      try? jpeg.write(to: folder.appending(path: "Thumbnails/\(id).jpg"))
    }
    let fragments = engine.recording(prebuffer: policy.preRoll)
    let task = Task { [weak self] in
      var initializations = 0
      var started: Double?
      for await fragment in fragments {
        if fragment.kind == .initialization {
          initializations += 1
          // Another picture size: this clip ends here
          if initializations > 1 { break }
        } else {
          started = started ?? fragment.time
          if let started, fragment.time - started > Self.maximumClip { break }
        }
        try? file.write(contentsOf: fragment.data)
        await self?.grew(id, by: fragment.data.count, peak: engine.motion.level)
      }
      guard !Task.isCancelled else { return }
      // The clip got too long, or the picture size changed: the next motion event starts a new one
      await self?.finish()
    }
    recording = Recording(id: id, file: file, task: task)
    events.insert(
      CameraEvent(id: id, start: now, end: nil, peak: peak, size: 0, storage: CameraStoragePolicy.Target.device.rawValue, clip: clip),
      at: 0)
    changed()
  }

  private func grew(_ id: String, by bytes: Int, peak: Double) {
    guard let index = events.firstIndex(where: { $0.id == id }) else { return }
    events[index].size += bytes
    events[index].peak = max(events[index].peak, peak)
  }

  private func finish() async {
    guard let recording else { return }
    self.recording = nil
    recording.task.cancel()
    try? recording.file.close()
    guard let index = events.firstIndex(where: { $0.id == recording.id }) else { return }
    events[index].end = Date()
    changed()
    if policy.target == .hub, let hubStorage {
      await upload(events[index], to: hubStorage)
    }
    await applyRetention()
  }

  private func upload(_ event: CameraEvent, to storage: CameraHubStorage) async {
    guard let clip = event.clip else { return }
    let file = folder.appending(path: "Clips/\(clip)")
    let day = event.start.formatted(.iso8601.year().month().day())
    let key = "\(hubFolder)/\(day)/\(clip)"
    do {
      let url = try await storage.write(key)
      var request = URLRequest(url: url)
      request.httpMethod = "PUT"
      request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
      let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file)
      if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
        throw CameraRecorderError.uploadFailed(status)
      }
      try? await storage.updated("\(hubFolder)/\(day)/")
      try? FileManager.default.removeItem(at: file)
      if let index = events.firstIndex(where: { $0.id == event.id }) {
        events[index].storage = CameraStoragePolicy.Target.hub.rawValue
        events[index].clip = key
      }
      lastError = nil
    } catch {
      // Kept on the device: the clip isn't lost when the hub's storage is away
      lastError = "A clip stayed on this device: the hub’s storage didn’t take it (\(error.localizedDescription))."
    }
    changed()
  }

  // MARK: Retention

  func applyRetention() async {
    var removed = [CameraEvent]()
    if policy.days > 0 {
      let oldest = Date().addingTimeInterval(-Double(policy.days) * 86_400)
      removed += events.filter { $0.end != nil && $0.start < oldest }
      events.removeAll { $0.end != nil && $0.start < oldest }
    }
    if policy.gigabytes > 0 {
      let limit = Int(policy.gigabytes * 1_000_000_000)
      var total = events.reduce(0) { $0 + $1.size }
      while total > limit, let last = events.last, last.end != nil {
        total -= last.size
        removed.append(events.removeLast())
      }
    }
    guard !removed.isEmpty else { return }
    await remove(removed)
    changed()
  }

  private func remove(_ removed: [CameraEvent]) async {
    for event in removed {
      try? FileManager.default.removeItem(at: folder.appending(path: "Thumbnails/\(event.id).jpg"))
      guard let clip = event.clip else { continue }
      if event.storage == CameraStoragePolicy.Target.hub.rawValue {
        try? await hubStorage?.delete(clip)
      } else {
        try? FileManager.default.removeItem(at: folder.appending(path: "Clips/\(clip)"))
      }
    }
  }

  private func changed() {
    if let data = try? JSONEncoder.camera.encode(events) {
      try? data.write(to: folder.appending(path: "events.json"), options: .atomic)
    }
    onChange?(events)
  }

  /// `2026-11-01T14-03-22-5f1a`: sorts by time, safe in file names and S3 keys
  static func id(_ date: Date) -> String {
    let time = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
    return "\(time.replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(4).lowercased())"
  }
}

enum CameraRecorderError: LocalizedError {
  case noClip
  case hubStorageUnavailable
  case uploadFailed(Int)

  var errorDescription: String? {
    switch self {
    case .noClip: "This event has no clip."
    case .hubStorageUnavailable: "The clip is on the hub’s storage, which this camera can’t reach now."
    case .uploadFailed(let status): "The storage answered \(status)."
    }
  }
}
#endif
