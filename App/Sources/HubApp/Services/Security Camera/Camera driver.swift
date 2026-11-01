//
//  Camera driver.swift
//  Hub
//
//  Debug: drives the camera across devices without taps and prints `[CAMDRIVE]` lines, beside the normal window.
//  `--camera-on`: this device's camera on, for the hub it's on Hub Network with (`--camera-hub <name>` picks one); it
//  prints the password and what changes; `--camera-device Front` picks the camera whose name has that in it (and keeps it
//  in the settings). `--camera-watch --camera-password <password>`: watches the hub's cameras and
//  prints their state, frame rate and events; the password is saved, so the Cameras page then shows them live.
//  On an iPhone: `xcrun devicectl device process launch --console --terminate-existing --device <id> dev.v57.Hub
//  --camera-on`.
//

#if DEBUG && canImport(PlatformCamera)
import Foundation

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
    if isOn { await turnOn(hub) }
    if isWatching { await watch(hub) }
  }

  private static func turnOn(_ hub: Hub) async {
    let camera = SecurityCamera.main
    if let name = argument("--camera-device"), let device = camera.devices.first(where: { $0.name.contains(name) }) {
      camera.settings.device = device.id
    }
    await camera.turnOn(hub: hub)
    log("password \(camera.password)")
    var last = ""
    var tick = 0
    while true {
      let line = "phase=\(camera.phase) published=\(camera.isPublished) problem=\(camera.shareProblem ?? "-") "
        + "device=\(camera.device?.name ?? "-") motion=\(camera.motion.isActive) events=\(camera.events.count) "
        + "interruption=\(camera.interruption ?? "-") storage=\(camera.storageProblem ?? "-")"
      if line != last || tick % 20 == 0 {
        log("\(line) level=\(String(format: "%.3f", camera.motion.level))")
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
          log("\(line) fps=\(fps) frames=\(viewer.frameCount)")
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
