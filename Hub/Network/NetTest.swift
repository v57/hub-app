//
//  NetTest.swift
//  Hub
//
//  `--net-test [use-internet|stop|join|share-internet|leave|status|links|node]` (Debug): drives this device's Hub Network on its first hub (or
//  `--net-hub <ws address>`) without taps and prints each step as a `[NETTEST]` line: the hub's agent, joining, the
//  devices that offer their internet, Use Internet, a download through it, the network path and the extension's
//  diagnostics. On an iPhone, read the lines with
//  `xcrun devicectl device process launch --console --terminate-existing --device <id> dev.v57.Hub --net-test`.
//

#if DEBUG && !os(tvOS)
import Foundation
import Network

@MainActor
enum NetTest {
  static var isRequested: Bool { CommandLine.arguments.contains("--net-test") }

  private static var action: String {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--net-test"), index + 1 < arguments.count,
          !arguments[index + 1].hasPrefix("--") else { return "use-internet" }
    return arguments[index + 1]
  }

  static func log(_ line: String) {
    print("[NETTEST] \(line)")
  }

  static func run() async {
    let action = action
    log("start \(action)")
    guard let hub = await wait("hub", seconds: 20, { firstHub() }) else { return fail("no hub") }
    log("hub \(hub.settings.name) \(hub.settings.address.absoluteString) onHubMachine=\(hub.isOnHubMachine)")
    if action == "links" {
      // Also away from the hub: the link to its machine is what this checks
      return await links(hub)
    }
    guard await wait("connected", seconds: 30, { hub.isConnected ? true : nil }) != nil else { return fail("not connected") }
    guard await wait("api", seconds: 20, { hub.api.isEmpty ? nil : true }) != nil else { return fail("no api") }
    // Subscriptions live while they're held
    let subscriptions = [
      hub.state.networkLocalAgent.subscribe(hub: hub), hub.state.networkGateways.subscribe(hub: hub),
      hub.state.networkAgents.subscribe(hub: hub), hub.state.hubNetNode.subscribe(hub: hub),
    ]
    defer { _ = subscriptions }
    await hub.net.restoreIfActive()
    let agent = await wait("hub agent", seconds: 20, {
      hub.state.networkLocalAgent.value.updatedAt.isEmpty ? nil : hub.state.networkLocalAgent.value
    })
    if let agent {
      log("hub agent state=\(agent.state.rawValue) binding=\(agent.bindingKind?.rawValue ?? "-") connected=\(agent.connected) invites=\(agent.canIssueInvitation) error=\(agent.error?.message ?? "-")")
    } else {
      log("hub agent: no status")
    }
    log("coordinator node=\(hub.state.hubNetNode.value ?? "nil")")
    log("this device agent=\(hub.networkAppAgent.state)")
    if action == "status" {
      await statusLines(hub)
      keyLines(hub)
      await diagnostics()
      return pass()
    }
    if action == "node" {
      // `--net-node <ws address>`, or none for the default: the coordinator the hub names (owners only)
      let arguments = CommandLine.arguments
      let node = arguments.firstIndex(of: "--net-node").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
      do {
        try await hub.net.setNode(node)
        log("coordinator set to \(node ?? "the default")")
        return pass()
      } catch {
        return fail("set coordinator: \(error)")
      }
    }
    if action == "leave" {
      do {
        try await hub.net.joinNetwork(enabled: false)
        log("left")
        return pass()
      } catch {
        return fail("leave: \(error)")
      }
    }
    if !hub.net.isJoined {
      log("joining")
      do {
        try await hub.net.joinNetwork(enabled: true)
      } catch {
        await diagnostics()
        return fail("join: \(error)")
      }
    }
    log("joined address=\(hub.net.address?.ipv4 ?? "-")")
    if action == "share-internet" {
      do {
        try await hub.net.shareNetwork(enabled: true)
        log("sharing this device's internet")
      } catch {
        await diagnostics()
        return fail("share internet: \(error)")
      }
    }
    if action == "join" || action == "share-internet" {
      await statusLines(hub)
      keyLines(hub)
      await diagnostics()
      return pass()
    }
    if action == "reach" {
      let arguments = CommandLine.arguments
      let target = arguments.firstIndex(of: "--net-reach").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        ?? "100.96.0.2:1997"
      let reached = await reach(target)
      log("reach \(target): \(reached)")
      await statusLines(hub)
      return reached == "connected" ? pass() : fail("couldn't reach \(target)")
    }
    if action == "stop" {
      do {
        try await hub.net.disableVpn()
        log("stopped using another device's internet")
        await statusLines(hub)
        return pass()
      } catch {
        return fail("stop: \(error)")
      }
    }
    guard let gateway = await wait("gateway", seconds: 20, {
      hub.net.devices.first { $0.key != hub.key }
    }) else {
      log("gateways: \(hub.state.networkGateways.value.map { "\($0.key.prefix(12)) \($0.state) \($0.endpoint)" })")
      return fail("no device offers its internet")
    }
    log("gateway \(gateway.name ?? "-") key=\(gateway.key.prefix(12)) endpoint=\(gateway.endpoint) overlay=\(gateway.overlayAddress)")
    do {
      try await hub.net.vpn(through: gateway)
      log("using internet through \(gateway.name ?? gateway.key.prefix(12).description)")
    } catch {
      await diagnostics()
      return fail("use internet: \(error)")
    }
    await statusLines(hub)
    keyLines(hub)
    await download()
    await diagnostics()
    pass()
  }

  // MARK: Steps

  private static func firstHub() -> Hub? {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--net-hub"), index + 1 < arguments.count {
      return Hubs.main.list.first { $0.settings.address.absoluteString == arguments[index + 1] }
    }
    return Hubs.main.list.first
  }

  /// The WireGuard keys each side holds: this device's own, the members' and the gateways', to match a handshake
  private static func keyLines(_ hub: Hub) {
    let own = (try? HubNetworkWireGuardKeyStore().publicKeyBase64()) ?? "unavailable"
    let profile = try? PacketTunnelController().installedConfiguration()
    log("own wireguard=\(own.prefix(10)) profile wireguard=\(profile?.wireGuardPublicKey?.prefix(10) ?? "-") key=\(hub.key.suffix(10))")
    for agent in hub.state.networkAgents.value {
      log("member \(agent.name ?? "-") key=\(agent.key.suffix(10)) wireguard=\(agent.wireGuardKey.prefix(10)) overlay=\(agent.overlayAddresses) online=\(agent.online.map(String.init) ?? "-")")
    }
    for gateway in hub.state.networkGateways.value {
      log("gateway key=\(gateway.key.suffix(10)) wireguard=\(gateway.wireGuardKey.prefix(10)) state=\(gateway.state) endpoint=\(gateway.endpoint)")
    }
  }

  /// Waits up to `--net-wait` seconds (40) for a link with a fresh handshake, printing the extension's links as they
  /// go, then opens the hub's port on each linked device's overlay address
  private static func links(_ hub: Hub) async {
    let arguments = CommandLine.arguments
    let seconds = arguments.firstIndex(of: "--net-wait").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 40
    let deadline = Date().addingTimeInterval(seconds)
    var status: LinkStatusLines?
    while Date() < deadline {
      status = await linkLines()
      if status?.up.isEmpty == false { break }
      try? await Task.sleep(for: .seconds(3))
    }
    log("hub connected=\(hub.isConnected)")
    guard let status, !status.up.isEmpty else {
      await diagnostics()
      return fail("no link came up")
    }
    var reachedAll = true
    // A member reaches the hub on the machine it links to
    for peer in status.up where peer.opens {
      guard let address = peer.routes.first(where: { !$0.contains(":") })?.split(separator: "/").first else { continue }
      let reached = await reach("\(address):1997")
      log("reach \(address):1997 through the link: \(reached)")
      if reached != "connected" { reachedAll = false }
    }
    await statusLines(hub)
    reachedAll ? pass() : fail("a linked device's hub port didn't answer")
  }

  private struct LinkStatusLines: Decodable {
    struct Peer: Decodable {
      let key: String
      let opens: Bool
      let attempting: Bool
      let endpoint: String?
      let routes: [String]
      let ports: [String]
      let lastHandshake: Date?
    }
    let present: Bool
    let coordinator: String
    let linkUps: Int
    let peers: [Peer]
    /// Peers with a handshake in the last 150 seconds
    var up: [Peer] { peers.filter { $0.lastHandshake.map { Date().timeIntervalSince($0) < 150 } ?? false } }
  }

  /// Prints the extension's links and returns them
  @discardableResult
  private static func linkLines() async -> LinkStatusLines? {
    guard let data = try? await PacketTunnelController().linkStatus() else {
      log("links: no tunnel")
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let status = try? decoder.decode(LinkStatusLines.self, from: data) else {
      log("links: unreadable \(String(decoding: data, as: UTF8.self).prefix(200))")
      return nil
    }
    log("links present=\(status.present) coordinator=\(status.coordinator) ups=\(status.linkUps) peers=\(status.peers.count)")
    for peer in status.peers {
      let age = peer.lastHandshake.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never"
      log("link peer=\(peer.key.suffix(10)) \(peer.opens ? "opens" : "accepts") attempting=\(peer.attempting) endpoint=\(peer.endpoint ?? "-") routes=\(peer.routes) ports=\(peer.ports) handshake=\(age)")
    }
    return status
  }

  private static func statusLines(_ hub: Hub) async {
    log("joined=\(hub.net.isJoined) address=\(hub.net.address?.ipv4 ?? "-") vpn=\(hub.net.vpn?.name ?? "none")")
    await linkLines()
    let path = await currentPath()
    log("path status=\(path.status) interfaces=\(path.availableInterfaces.map { "\($0.name)(\($0.type))" }) primary=\(path.availableInterfaces.first.map { "\($0.name)" } ?? "-")")
  }

  /// A TCP connection to `host:port` over whatever route the system picks (the overlay for 100.96/11): `connected`,
  /// or what stopped it within 10 seconds
  private static func reach(_ target: String) async -> String {
    guard let colon = target.lastIndex(of: ":"), let port = NWEndpoint.Port(String(target[target.index(after: colon)...])) else {
      return "bad target"
    }
    let connection = NWConnection(host: NWEndpoint.Host(String(target[..<colon])), port: port, using: .tcp)
    return await withCheckedContinuation { continuation in
      let once = OnceFlag()
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: if once.take() { connection.cancel(); continuation.resume(returning: "connected") }
        case .failed(let error): if once.take() { connection.cancel(); continuation.resume(returning: "failed \(error)") }
        case .waiting(let error): if once.take() { connection.cancel(); continuation.resume(returning: "waiting \(error)") }
        default: break
        }
      }
      connection.start(queue: .global())
      DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        if once.take() { connection.cancel(); continuation.resume(returning: "timed out") }
      }
    }
  }

  private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if taken { return false }
      taken = true
      return true
    }
  }

  private static func currentPath() async -> NWPath {
    await withCheckedContinuation { continuation in
      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { path in
        monitor.cancel()
        continuation.resume(returning: path)
      }
      monitor.start(queue: .global())
    }
  }

  /// Where the traffic leaves (Cloudflare's trace: the public IP and data centre), then 5 MB to time
  private static func download() async {
    let session = URLSession(configuration: .ephemeral)
    if let (data, _) = try? await session.data(from: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!) {
      let trace = String(decoding: data, as: UTF8.self).split(separator: "\n")
        .filter { $0.hasPrefix("ip=") || $0.hasPrefix("colo=") || $0.hasPrefix("warp=") }
      log("trace \(trace.joined(separator: " "))")
    } else {
      log("trace failed")
    }
    let started = Date()
    do {
      let (data, _) = try await session.data(from: URL(string: "https://speed.cloudflare.com/__down?bytes=5000000")!)
      let seconds = Date().timeIntervalSince(started)
      log("download \(data.count) bytes in \(String(format: "%.1f", seconds)) s")
    } catch {
      log("download failed: \(error.localizedDescription)")
    }
  }

  /// The extension's own lines: over its IPC while it runs, else from the file it also writes in the app group
  private static func diagnostics() async {
    if let controller = try? PacketTunnelController(),
       let lines = await controller.extensionDiagnostics()?.split(separator: "\n"), !lines.isEmpty {
      for line in lines.suffix(25) { log("extension \(line)") }
      return
    }
    guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.v57.hub"),
          let text = try? String(contentsOf: group.appendingPathComponent("hn9xx-diag.log"), encoding: .utf8) else {
      log("extension: no diagnostics")
      return
    }
    for line in text.split(separator: "\n").suffix(25) { log("extension file \(line)") }
  }

  // MARK: Helpers

  private static func wait<T>(_ what: String, seconds: Double, _ value: @MainActor () -> T?) async -> T? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if let value = value() { return value }
      try? await Task.sleep(for: .milliseconds(200))
    }
    log("timed out waiting for \(what)")
    return nil
  }

  private static func pass() { log("result pass") }

  private static func fail(_ reason: String) { log("result fail: \(reason)") }
}
#endif
