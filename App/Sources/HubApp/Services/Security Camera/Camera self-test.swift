//
//  Camera self-test.swift
//  Hub
//
//  Debug: `Hub --camera-selftest` runs the camera on this device's real camera without a hub: the engine, the server
//  on loopback, the live stream through the viewer's parser, a snapshot, wrong passwords, and a clip around a simulated
//  motion event, downloaded back. It prints `[CAMERA]` lines and quits. `--camera-hold <seconds>` keeps the published server
//  up that long first, for a client from outside.
//

#if DEBUG && canImport(PlatformCamera)
import Foundation
import PlatformCamera
import PlatformMedia

@MainActor
enum CameraSelfTest {
  static var isRequested: Bool { CommandLine.arguments.contains("--camera-selftest") }

  static func log(_ line: String) {
    print("[CAMERA] \(line)")
  }

  static func run() async {
    var failures = 0
    func check(_ ok: Bool, _ line: String) {
      log("\(ok ? "ok" : "FAIL") \(line)")
      if !ok { failures += 1 }
    }
    log("access \(CameraCapture.access) devices \(CameraCapture.devices().map(\.name))")
    if CameraCapture.access == .notDetermined { _ = await CameraCapture.requestAccess() }
    guard CameraCapture.access == .authorized else {
      log("FAIL camera access is \(CameraCapture.access)")
      exit(1)
    }
    let folder = URL.temporaryDirectory.appending(path: "camera-selftest-\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
      guard let device = CameraCapture.devices().first else { throw CameraError.noDevice }
      let engine = try CameraEngine(device: device, settings: .init(format: .hd, sensitivity: 0.5))
      engine.start()
      let rig = CameraRig()
      rig.onFrame = { _, frame in engine.take(frame) }
      try rig.run([CameraConfiguration(device: device.id, width: 1280, height: 720, fps: 15)])
      defer { rig.stop() }
      log("capturing from \(engine.device.name)")
      var policy = CameraStoragePolicy()
      policy.postRoll = 2
      let recorder = CameraRecorder(folder: folder, policy: policy, hubFolder: "Cameras/test")
      await recorder.configure(policy: policy, hubStorage: nil, onChange: nil)
      await recorder.start(engine: engine)
      let password = "self-test-password"
      let server = CameraServer(engine: engine, recorder: recorder, password: password) {
        CameraInfo(name: "Self test", camera: "camera", width: 1280, height: 720, fps: 15, motion: engine.motion, sensitivity: 0.5, storage: "device")
      }
      let port = try await server.start()
      let base = URL(string: "http://127.0.0.1:\(port)")!
      log("serving on \(port)")

      // Not published: fails closed
      check(try await status(base, password: password) == 503, "answers 503 before the share is published")
      server.setPublished(true)
      try await Task.sleep(for: .milliseconds(100))
      check(try await status(base, password: "wrong") == 401, "wrong password gets 401")
      check(try await status(base, password: password) == 200, "right password gets 200")
      // --camera-hold <seconds>: keeps the server up for a client from outside (a slow viewer, say) before going on
      if let index = CommandLine.arguments.firstIndex(of: "--camera-hold"), index + 1 < CommandLine.arguments.count,
        let seconds = Double(CommandLine.arguments[index + 1]) {
        log("holding \(seconds) s on \(port), password \(password)")
        try await Task.sleep(for: .seconds(seconds))
      }

      // Live: 6 seconds through the viewer's parser
      let stats = LiveStats()
      var request = URLRequest(url: base.appending(path: "live"))
      request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
      let renderer = CameraVideoRenderer()
      let connection = LiveConnection(request: request, renderer: renderer) { event in
        if case .motion(let motion) = event { stats.motion(motion) }
      } ended: { error in
        stats.ended(error)
      }
      stats.renderer = renderer
      connection.start()
      let probe = LiveProbe(request: request, stats: stats)
      probe.start()
      try await Task.sleep(for: .seconds(6))
      connection.cancel()
      probe.cancel()
      let summary = stats.summary
      log("live \(summary.frames) frames, \(summary.keyframes) keyframes, \(summary.bytes / 1024) KB, \(summary.width)×\(summary.height), latency median \(summary.latency) ms, motion messages \(summary.motions)")
      check(summary.frames >= 60, "live stream delivers frames (\(summary.frames) in 6 s)")
      check(summary.keyframes >= 1 && summary.firstIsKeyframe, "live stream starts at a keyframe with parameter sets")

      // A viewer held up for 5 s is more than LiveConnection.maximumLag behind: it asks for the stream again
      let stalled = LiveConnection(request: request, renderer: CameraVideoRenderer()) { _ in } ended: { _ in }
      stalled.stall = 5
      stalled.start()
      try await Task.sleep(for: .seconds(8))
      stalled.cancel()
      check(stalled.restarts == 1, "a viewer 5 s behind starts the stream again (\(stalled.restarts) restarts)")

      // Snapshot
      var snapshotRequest = URLRequest(url: base.appending(path: "snapshot.jpg").appending(queryItems: [URLQueryItem(name: "width", value: "640")]))
      snapshotRequest.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
      let (jpeg, _) = try await URLSession.shared.data(for: snapshotRequest)
      check(jpeg.prefix(2) == Data([0xFF, 0xD8]), "snapshot is a JPEG (\(jpeg.count / 1024) KB)")
      try? jpeg.write(to: URL.temporaryDirectory.appending(path: "camera-selftest-snapshot.jpg"))

      // Alerts: a follower of /alerts, as the app runs one, hears of the event as it starts
      let alerts = AlertLines()
      let subscription = CameraAlertSubscription(
        id: "self-test", hub: "self-test", hubName: "Self test", place: "Self test", host: "127.0.0.1", port: port, password: password)
      let following = Task.detached { await CameraAlerts.listen(subscription) { alerts.add($0) } }
      try await Task.sleep(for: .seconds(1))

      // A clip around a simulated motion event: prebuffer, 5 s of motion, post-roll
      let motionStarted = Date()
      engine.simulateMotion(true)
      try await Task.sleep(for: .seconds(5))
      engine.simulateMotion(false)
      try await Task.sleep(for: .seconds(policy.postRoll + 2.5))
      var eventsRequest = URLRequest(url: base.appending(path: "events"))
      eventsRequest.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
      let events = try JSONDecoder.camera.decode([CameraEvent].self, from: try await URLSession.shared.data(for: eventsRequest).0)
      log("events \(events.map { "\($0.id) \(Int($0.duration)) s \($0.size / 1024) KB" })")
      check(events.count == 1 && events.first?.end != nil, "one finished event")
      following.cancel()
      let alert = alerts.all.first
      log("alerts \(alerts.all.map { "\($0.kind.rawValue) \($0.event ?? "-") at \(String(format: "%+.2f", $0.time.timeIntervalSince(motionStarted))) s" })")
      check(alerts.all.count == 1 && alert?.event == events.first?.id, "a follower of /alerts gets the event as it starts")
      if let event = events.first {
        var clipRequest = URLRequest(url: base.appending(path: "events/\(event.id)/clip.mp4"))
        clipRequest.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        let (clip, _) = try await URLSession.shared.data(for: clipRequest)
        let boxes = MP4Boxes(clip)
        log("clip \(clip.count / 1024) KB, boxes \(boxes.types.prefix(6)) … \(boxes.count("moof")) fragments, \(String(format: "%.1f", boxes.duration)) s")
        check(boxes.types.first == "ftyp" && boxes.types.contains("moov"), "clip starts with ftyp + moov")
        check(boxes.duration >= 8, "clip covers prebuffer + motion + post-roll (\(String(format: "%.1f", boxes.duration)) s)")
        // What the viewer's clip player does: AVFoundation opens it
        let file = URL.temporaryDirectory.appending(path: "camera-selftest-clip.mp4")
        try clip.write(to: file)
        let player = PlatformPlayer()
        try await player.open(file)
        log("clip opens: \(player.state), \(String(format: "%.1f", player.duration)) s, \(Int(player.videoSize.width))×\(Int(player.videoSize.height)), tracks \(player.tracks.map { "\($0.kind.rawValue) \($0.codec ?? "?")" })")
        check(player.duration >= 8 && player.videoSize.width == 1280, "the player opens the clip")
        player.stop()
        var thumbRequest = URLRequest(url: base.appending(path: "events/\(event.id)/thumbnail.jpg"))
        thumbRequest.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        let (thumbnail, _) = try await URLSession.shared.data(for: thumbRequest)
        check(thumbnail.prefix(2) == Data([0xFF, 0xD8]), "event thumbnail is a JPEG")
        var deleteRequest = URLRequest(url: base.appending(path: "events/\(event.id)"))
        deleteRequest.httpMethod = "DELETE"
        deleteRequest.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        let (_, deleted) = try await URLSession.shared.data(for: deleteRequest)
        let left = try JSONDecoder.camera.decode([CameraEvent].self, from: try await URLSession.shared.data(for: eventsRequest).0)
        check((deleted as? HTTPURLResponse)?.statusCode == 200 && left.isEmpty, "DELETE removes the event and its clip")
      }

      // Another format while live: HEVC at 1080p reaches a viewer from a keyframe with its three parameter sets
      if CameraEncoder.supports(.hevc) {
        let hevc = LiveStats()
        let probe = LiveProbe(request: request, stats: hevc)
        probe.start()
        try await Task.sleep(for: .seconds(1))
        let format = VideoFormat(width: 1920, height: 1080, fps: 15, bitrate: 2_000_000, codec: .hevc)
        try engine.update(.init(format: format, sensitivity: 0.5))
        try await Task.sleep(for: .seconds(3))
        probe.cancel()
        let codecs = hevc.codecs
        log("after the switch: \(codecs)")
        check(codecs.last == "hevc 1920×1080 3 sets", "switches to HEVC 1080p while live")
        try engine.update(.init(format: .hd, sensitivity: 0.5))
      }

      // HomeKit's seam: a second stream at another format, and the fMP4 prebuffer
      let low = engine.video(.low)
      var lowFrames = 0
      var lowFirstKey = false
      for await frame in low.frames {
        if lowFrames == 0 { lowFirstKey = frame.isKeyframe && frame.parameterSets.count == 2 }
        lowFrames += 1
        if lowFrames == 20 { break }
      }
      low.stop()
      check(lowFrames == 20 && lowFirstKey, "CameraFeed.video(.low) streams from a keyframe")
      var fragments = [MP4Fragment]()
      for await fragment in engine.recording(prebuffer: 4) {
        fragments.append(fragment)
        if fragments.count == 3 { break }
      }
      check(fragments.first?.kind == .initialization && fragments.dropFirst().allSatisfy { $0.kind == .media }, "CameraFeed.recording starts with initialization")

      server.setPublished(false)
      try await Task.sleep(for: .milliseconds(100))
      check(try await status(base, password: password) == 503, "unpublished again: 503")
      server.stop()
      await recorder.stop()
      engine.stop()
    } catch {
      log("FAIL \(error)")
      failures += 1
    }
    log(failures == 0 ? "result passed" : "result failed \(failures)")
    exit(failures == 0 ? 0 : 1)
  }

  private static func status(_ base: URL, password: String) async throws -> Int {
    var request = URLRequest(url: base)
    request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
    let (_, response) = try await URLSession.shared.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
  }
}

/// Counts what the live stream delivers
private final class LiveStats: @unchecked Sendable {
  private let lock = NSLock()
  var renderer: CameraVideoRenderer?
  private var frames = 0
  private var keyframes = 0
  private var bytes = 0
  private var first: Bool?
  private var size = (0, 0)
  private var latencies: [Double] = []
  private var motions = 0

  func frame(_ frame: EncodedVideoFrame) {
    // The capture clock is the host clock: uptime now minus the frame's time is capture-to-here
    let latency = (ProcessInfo.processInfo.systemUptime - frame.time) * 1000
    lock.withLock {
      if first == nil { first = frame.isKeyframe && frame.parameterSets.count == 2 }
      frames += 1
      if frame.isKeyframe { keyframes += 1 }
      bytes += frame.data.count
      size = (frame.width, frame.height)
      latencies.append(latency)
      if frame.isKeyframe {
        let kind = "\(frame.codec.rawValue) \(frame.width)×\(frame.height) \(frame.parameterSets.count) sets"
        if kinds.last != kind { kinds.append(kind) }
      }
    }
  }
  /// What the keyframes were, each change once
  private var kinds: [String] = []
  var codecs: [String] { lock.withLock { kinds } }
  func motion(_ motion: CameraMotion) { lock.withLock { motions += 1 } }
  func ended(_ error: Error?) {}

  var summary: (frames: Int, keyframes: Int, bytes: Int, width: Int, height: Int, latency: Int, motions: Int, firstIsKeyframe: Bool) {
    lock.withLock {
      let sorted = latencies.sorted()
      let median = sorted.isEmpty ? -1 : Int(sorted[sorted.count / 2])
      return (frames, keyframes, bytes, size.0, size.1, median, motions, first ?? false)
    }
  }
}

/// A second connection to /live that parses frames itself, for the counts
private final class LiveProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let request: URLRequest
  private let stats: LiveStats
  private var parser = CameraWire.Parser()
  private var session: URLSession?

  init(request: URLRequest, stats: LiveStats) {
    self.request = request
    self.stats = stats
  }

  func start() {
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    self.session = session
    session.dataTask(with: request).resume()
  }

  func cancel() { session?.invalidateAndCancel() }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    for message in parser.append(data) {
      if case .video(let frame) = message { stats.frame(frame) }
    }
  }
}

/// The top-level boxes of an MP4 file, and how long its media fragments last (the media timescale from `mdhd`, the
/// fragments' decode times from `tfdt`)
private struct MP4Boxes {
  var types: [String] = []
  var duration: Double = 0

  init(_ data: Data) {
    var offset = data.startIndex
    var timescale: UInt32 = 0
    var decodeTimes: [UInt64] = []
    while offset + 8 <= data.endIndex {
      let size = Int(data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
      let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
      guard size >= 8, offset + size <= data.endIndex else { break }
      types.append(type)
      let box = data[offset..<offset + size]
      if type == "moov", let mdhd = box.range(of: Data("mdhd".utf8)) {
        // version 0: 4 bytes version/flags, 4 created, 4 modified, then the timescale
        let at = mdhd.upperBound + 12
        timescale = box[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
      }
      if type == "moof", let tfdt = box.range(of: Data("tfdt".utf8)) {
        let version = box[tfdt.upperBound]
        let at = tfdt.upperBound + 4
        decodeTimes.append(
          version == 1
            ? box[at..<at + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            : UInt64(box[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
      }
      offset += size
    }
    if timescale > 0, let first = decodeTimes.first, let last = decodeTimes.last {
      // Up to the last fragment's start, plus about a second for it
      duration = Double(last - first) / Double(timescale) + 1
    }
  }

  func count(_ type: String) -> Int { types.filter { $0 == type }.count }
}
/// The motion lines a self-test follower received
final class AlertLines: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [CameraAlert] = []
  func add(_ alert: CameraAlert) { lock.withLock { lines.append(alert) } }
  var all: [CameraAlert] { lock.withLock { lines } }
}
#elseif DEBUG
/// No camera on this platform: nothing to test
@MainActor
enum CameraSelfTest {
  static var isRequested: Bool { false }
  static func run() async {}
}
#endif
