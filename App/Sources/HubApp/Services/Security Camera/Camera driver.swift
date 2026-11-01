//
//  Camera driver.swift
//  Hub
//
//  Debug: drives the camera across devices without taps and prints `[CAMDRIVE]` lines, beside the normal window.
//  `--camera-on`: this device's camera on, for the hub it's on Hub Network with (`--camera-hub <name>` picks one); it
//  prints the password and what changes; `--camera-device Front` picks the camera whose name has that in it (and keeps it
//  in the settings). `--camera-watch --camera-password <password>`: watches the hub's cameras and
//  prints their state, frame rate, how far frames are behind and events; the password is saved, so the Cameras page
//  then shows them live. Both flags run both.
//  On an iPhone: `xcrun devicectl device process launch --console --terminate-existing --device <id> dev.v57.Hub
//  --camera-on`.
//

#if DEBUG && canImport(PlatformCamera)
import Foundation
import PlatformCamera

@MainActor
enum CameraDriver {
  static var isRequested: Bool { isOn || isWatching }
  private static var isOn: Bool { CommandLine.arguments.contains("--camera-on") }
  private static var isWatching: Bool { CommandLine.arguments.contains("--camera-watch") }

  static func log(_ line: String) {
    print("[CAMDRIVE] \(line)")
  }

  private static func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    return arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
  }

  private static func wait<T>(_ seconds: Double, _ value: () -> T?) async -> T? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if let value = value() { return value }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return nil
  }

  static func run() async {
    // A relaunch from devicectl ends the tunnel's extension a moment later: start it again, as NetTest does
    if let tunnel = try? PacketTunnelController(), (try? tunnel.installedConfiguration()) != nil {
      for _ in 0..<5 {
        if await tunnel.status != .connected {
          do {
            try await tunnel.start()
            log("tunnel started")
          } catch {
            log("tunnel start: \(error)")
          }
          break
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
    let name = argument("--camera-hub")
    guard let hub = await wait(60, {
      Hubs.main.list.first { hub in
        if let name { return hub.settings.name == name && hub.isConnected }
        return hub.isConnected && hub.net.isJoined
      }
    }) else {
      return log("result fail: no connected hub on Hub Network")
    }
    log("hub \(hub.settings.name) \(hub.settings.address.absoluteString)")
    // Both: this device's camera runs beside the watch (two members each watching the other's camera)
    if isOn, isWatching {
      Task { await turnOn(hub) }
      await watch(hub)
    } else if isOn {
      await turnOn(hub)
    } else if isWatching {
      await watch(hub)
    }
  }

  private static func turnOn(_ hub: Hub) async {
    let camera = SecurityCamera.main
    log("lenses \(camera.devices.map(\.name)) at most \(CameraRig.maximumCameras) at once")
    // --camera-device <name part>[,<name part>…]: only these lenses on
    if let names = argument("--camera-device")?.split(separator: ",").map(String.init) {
      for var setup in camera.settings.cameras {
        setup.isOn = false
        camera.update(setup)
      }
      for name in names {
        guard let device = camera.devices.first(where: { $0.name.contains(name) }) else { continue }
        var setup = camera.setup(for: device)
        setup.isOn = true
        camera.update(setup)
      }
    }
    // --camera-video 1080:30:hevc for every lens on
    if let video = argument("--camera-video")?.split(separator: ":").map(String.init), video.count == 3,
      let height = Int(video[0]), let fps = Int(video[1]), let codec = VideoCodec(rawValue: video[2]) {
      for var setup in camera.settings.cameras where setup.isOn {
        setup.video = CameraVideo(height: height, fps: fps, codec: codec)
        camera.update(setup)
      }
    }
    await camera.turnOn(hub: hub)
    for setup in camera.settings.cameras where setup.isOn {
      log("\(setup.place) password \(camera.password(setup.id)) \(setup.video.title)")
    }
    var last = ""
    var tick = 0
    while true {
      let budget = camera.budget
      var line = "phase=\(camera.phase) interruption=\(camera.interruption ?? "-") problem=\(camera.problem ?? "-") "
        + "budget=\(budget.hardwareCost.map { String(format: "%.2f", $0) } ?? "-")/\(budget.systemPressureCost.map { String(format: "%.2f", $0) } ?? "-") "
        + "pressure=\(budget.pressure.title)"
      for unit in camera.orderedUnits {
        line += " | \(unit.shareName) published=\(unit.isPublished) problem=\(unit.shareProblem ?? "-") motion=\(unit.motion.isActive) "
          + "events=\(unit.events.count) viewers=\(unit.viewers) storage=\(unit.storageProblem ?? "-")"
      }
      if line != last || tick % 20 == 0 {
        log("\(line) cpu=\(camera.cpuShare.map { String(format: "%.3f", $0) } ?? "-")")
        last = line
      }
      tick += 1
      try? await Task.sleep(for: .milliseconds(500))
    }
  }

  private static func watch(_ hub: Hub) async {
    let subscription = hub.state.networkResources.subscribe(hub: hub)
    defer { _ = subscription }
    guard let cameras = await wait(60, {
      let cameras = hub.state.networkResources.value.compactMap(HubCamera.init)
      return cameras.isEmpty ? nil : cameras
    }) else {
      return log("result fail: no cameras")
    }
    log("cameras \(cameras.map(\.name))")
    let password = argument("--camera-password")
    var viewers: [CameraViewer] = []
    for camera in cameras {
      if let password { CameraViewer.save(password, for: camera) }
      let viewer = CameraViewer(camera: camera, hub: hub)
      viewers.append(viewer)
      Task {
        for try await providers: [HubNetworkProvider] in hub.client.values("network/providers/list", CameraProviderRequest(resourceId: camera.id)) {
          log("\(camera.name) providers \(providers.map { "\($0.overlayAddress):\($0.port)" })")
          viewer.providers(providers)
        }
      }
    }
    var last: [String] = []
    var frames = viewers.map(\.frameCount)
    var tick = 0
    while true {
      try? await Task.sleep(for: .seconds(2))
      tick += 1
      for (index, viewer) in viewers.enumerated() {
        let fps = Double(viewer.frameCount - frames[index]) / 2
        frames[index] = viewer.frameCount
        let line = "\(viewer.camera.name) state=\(viewer.state) motion=\(viewer.motion?.isActive ?? false) events=\(viewer.events.count) "
          + "thumbnails=\(viewer.thumbnails.count) info=\(viewer.info.map { "\($0.width)x\($0.height)@\($0.fps) \($0.storage)" } ?? "-")"
        if last.count <= index { last.append("") }
        if line != last[index] || tick % 5 == 0 {
          log("\(line) fps=\(fps) frames=\(viewer.frameCount) behind=\(String(format: "%.2f", viewer.behind))s restarts=\(viewer.restarts)")
          last[index] = line
        }
      }
    }
  }
}
#elseif DEBUG
@MainActor
enum CameraDriver {
  static var isRequested: Bool { false }
  static func run() async {}
}
#endif
