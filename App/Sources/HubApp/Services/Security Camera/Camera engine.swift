//
//  Camera engine.swift
//  Hub
//
//  One running camera: the live encoder (H.264 or HEVC), motion detection and the fragmented MP4 prebuffer, fed the
//  frames of one lens by the device's `CameraRig`. It is the `CameraFeed` a HomeKit bridge (HAPKit) takes later; the
//  camera's own server and recorder use the same calls. Its format, sensitivity and zone change while it runs.
//

#if canImport(PlatformCamera)
import Foundation
import PlatformCamera

/// Platform's encoder: the app has a `VideoEncoder` of its own (the Video Encoder service)
typealias CameraEncoder = PlatformCamera.VideoEncoder

final class CameraEngine: CameraFeed, @unchecked Sendable {
  struct Settings: Hashable, Sendable {
    var format: VideoFormat
    var sensitivity: Double
    /// Where motion counts; nil for the whole picture
    var zone: MotionDetector.Zone?
  }

  /// Seconds of recording kept before now, for clips that start before the motion did (HomeKit asks for 4 or more)
  static let prebuffer: Double = 8
  /// Motion is looked for this many times a second
  static let analysisRate: Double = 5

  /// Which lens it is
  let device: CameraDevice

  private var encoder: CameraEncoder
  private let writer = FragmentedMP4Writer(segmentDuration: 1)
  private let lock = NSLock()
  private var current: Settings
  private var detector: MotionDetector
  private var lastAnalysis = -Double.infinity
  private var latest: CameraFrame?
  private var liveSinks: [UUID: @Sendable (EncodedVideoFrame) -> Void] = [:]
  private var streams: [UUID: CameraEncoder] = [:]
  private var motionSinks: [UUID: AsyncStream<MotionEvent>.Continuation] = [:]
  private var recordingSinks: [UUID: AsyncStream<MP4Fragment>.Continuation] = [:]
  private var initialization: MP4Fragment?
  private var segments: [MP4Fragment] = []
  private var currentMotion = CameraMotion(isActive: false, level: 0)
  private var isStopped = false

  init(device: CameraDevice, settings: Settings) throws {
    self.device = device
    current = settings
    encoder = try CameraEncoder(format: settings.format)
    detector = MotionDetector(sensitivity: settings.sensitivity, zone: settings.zone)
  }

  var settings: Settings { lock.withLock { current } }

  /// Motion now, as viewers see it
  var motion: CameraMotion { lock.withLock { currentMotion } }

  /// The newest picture, for a preview that isn't the live stream
  var latestFrame: CameraFrame? { lock.withLock { latest } }

  func start() {
    encoder.onFrame = { [weak self] frame in self?.encoded(frame) }
    writer.onFragment = { [weak self] fragment in self?.written(fragment) }
  }

  /// Another format starts a new encoder (viewers get a keyframe with the new parameter sets, and the recording a new
  /// initialization fragment, which ends a clip); sensitivity and zone apply from the next frame
  func update(_ settings: Settings) throws {
    let old = lock.withLock { current }
    guard settings != old else { return }
    if settings.format != old.format {
      let encoder = try CameraEncoder(format: settings.format)
      encoder.onFrame = { [weak self] frame in self?.encoded(frame) }
      let previous = lock.withLock {
        defer { self.encoder = encoder }
        return self.encoder
      }
      previous.invalidate()
    }
    lock.withLock {
      current = settings
      detector.sensitivity = settings.sensitivity
      if detector.zone != settings.zone {
        detector.zone = settings.zone
        detector.reset()
      }
    }
  }

  func stop() {
    let encoder = lock.withLock {
      isStopped = true
      return self.encoder
    }
    encoder.invalidate()
    writer.finish()
    let (streams, motionSinks, recordingSinks) = lock.withLock {
      defer {
        self.streams = [:]
        self.motionSinks = [:]
        self.recordingSinks = [:]
        liveSinks = [:]
      }
      return (self.streams, self.motionSinks, self.recordingSinks)
    }
    streams.values.forEach { $0.invalidate() }
    motionSinks.values.forEach { $0.finish() }
    recordingSinks.values.forEach { $0.finish() }
  }

  // MARK: Pipeline

  /// The lens's next frame, on its capture queue
  func take(_ frame: CameraFrame) {
    let (encoder, streams, analyze): (CameraEncoder?, [CameraEncoder], Bool) = lock.withLock {
      guard !isStopped else { return (nil, [], false) }
      latest = frame
      let analyze = frame.time - lastAnalysis >= 1 / Self.analysisRate
      if analyze { lastAnalysis = frame.time }
      return (self.encoder, Array(self.streams.values), analyze)
    }
    guard let encoder else { return }
    encoder.encode(frame)
    streams.forEach { $0.encode(frame) }
    if analyze { detectMotion(frame) }
  }

  private func detectMotion(_ frame: CameraFrame) {
    let luma = frame.lumaGrid(columns: 64, rows: 36)
    let (event, sinks) = lock.withLock {
      let event = detector.process(luma: luma, columns: 64, time: frame.time)
      let box = detector.box.map { CameraBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
      currentMotion = CameraMotion(isActive: detector.isActive, level: detector.level, box: detector.isActive ? box : nil)
      return (event, Array(motionSinks.values))
    }
    guard let event else { return }
    sinks.forEach { $0.yield(event) }
  }

  private func encoded(_ frame: EncodedVideoFrame) {
    writer.append(frame)
    let sinks = lock.withLock { Array(liveSinks.values) }
    sinks.forEach { $0(frame) }
  }

  private func written(_ fragment: MP4Fragment) {
    let sinks = lock.withLock {
      if fragment.kind == .initialization {
        initialization = fragment
        segments = []
      } else {
        segments.append(fragment)
        let end = fragment.time + fragment.duration
        segments.removeAll { $0.time + $0.duration < end - Self.prebuffer - 1 }
      }
      return Array(recordingSinks.values)
    }
    sinks.forEach { $0.yield(fragment) }
  }

  // MARK: The camera's own viewers

  /// The live encoder's frames, from the next keyframe (asked for now), on the encoder's queue; call the returned
  /// closure to stop
  func watch(_ sink: @escaping @Sendable (EncodedVideoFrame) -> Void) -> @Sendable () -> Void {
    let id = UUID()
    let encoder = lock.withLock {
      liveSinks[id] = sink
      return self.encoder
    }
    encoder.requestKeyframe()
    return { [weak self] in
      _ = self?.lock.withLock { self?.liveSinks.removeValue(forKey: id) }
    }
  }

#if DEBUG
  /// Motion starting or ending as if the detector saw it, for the self-test
  func simulateMotion(_ active: Bool) {
    let sinks = lock.withLock {
      currentMotion = CameraMotion(isActive: active, level: active ? 0.2 : 0)
      return Array(motionSinks.values)
    }
    sinks.forEach { $0.yield(MotionEvent(isActive: active, level: active ? 0.2 : 0)) }
  }
#endif

  // MARK: CameraFeed

  var supportedFormats: [VideoFormat] {
    var format = settings.format
    format.codec = .h264
    return [format, .low, VideoFormat(width: 320, height: 240, fps: 15, bitrate: 200_000)]
  }

  func video(_ format: VideoFormat) -> CameraVideoStream {
    let id = UUID()
    let (frames, continuation) = AsyncStream.makeStream(of: EncodedVideoFrame.self, bufferingPolicy: .bufferingNewest(30))
    guard let encoder = try? CameraEncoder(format: format) else {
      continuation.finish()
      return CameraVideoStream(format: format, frames: frames) { _ in }
    }
    encoder.onFrame = { continuation.yield($0) }
    encoder.requestKeyframe()
    lock.withLock { streams[id] = encoder }
    let end: @Sendable () -> Void = { [weak self] in
      let encoder = self?.lock.withLock { self?.streams.removeValue(forKey: id) }
      encoder?.invalidate()
      continuation.finish()
    }
    continuation.onTermination = { _ in end() }
    return CameraVideoStream(format: format, frames: frames) { control in
      switch control {
      case .bitrate(let bitrate): encoder.setBitrate(bitrate)
      case .keyframe: encoder.requestKeyframe()
      case .stop: end()
      }
    }
  }

  func snapshot(maxWidth: Int) async throws -> Data {
    guard let frame = lock.withLock({ latest }) else { throw CameraError.failed("The camera has no picture yet.") }
    let jpeg = await Task.detached(priority: .userInitiated) { frame.jpeg(maxWidth: maxWidth) }.value
    guard let jpeg else { throw CameraError.failed("The picture couldn’t be saved as JPEG.") }
    return jpeg
  }

  func motionEvents() -> AsyncStream<MotionEvent> {
    let id = UUID()
    let (events, continuation) = AsyncStream.makeStream(of: MotionEvent.self)
    lock.withLock { motionSinks[id] = continuation }
    continuation.onTermination = { [weak self] _ in
      _ = self?.lock.withLock { self?.motionSinks.removeValue(forKey: id) }
    }
    return events
  }

  func recording(prebuffer: Double) -> AsyncStream<MP4Fragment> {
    let id = UUID()
    let (fragments, continuation) = AsyncStream.makeStream(of: MP4Fragment.self)
    lock.withLock {
      if let initialization {
        continuation.yield(initialization)
        let end = segments.last.map { $0.time + $0.duration } ?? 0
        // From the newest segment that starts at least `prebuffer` seconds back
        let start = segments.lastIndex { $0.time <= end - prebuffer } ?? 0
        segments[start...].forEach { continuation.yield($0) }
      }
      recordingSinks[id] = continuation
    }
    continuation.onTermination = { [weak self] _ in
      _ = self?.lock.withLock { self?.recordingSinks.removeValue(forKey: id) }
    }
    return fragments
  }
}
#endif
