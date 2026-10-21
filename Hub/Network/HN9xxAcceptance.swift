#if DEBUG
#if os(macOS)
import AppKit
#endif
import Foundation
import HubService
import Network
import SwiftUI

/// Env-driven HN-9xx live acceptance for the Phase 1-2 matrix (Mac A <-> Mac
/// B / iPhone). On macOS the driver launches the app with env vars; on iOS
/// the same hooks run under `xcrun devicectl device process launch -e ...`.
///
/// Owner acceptance (`HUB_HN9XX_OWNER_ACCEPTANCE=1`):
///   - connects to hub-server as the owner,
///   - sets `hub/net/node` to `HUB_HN9XX_NODE_ENDPOINT` (Tailscale name),
///   - joins the local network and waits for the local `net/invite` provider,
///   - issues a single-use invitation and writes `HUB_HN9XX_RESULT_JSON`
///     (`{invitation, nodeEndpoint, hub, expiresAt}`),
///   - then stays alive to serve replay (inviter must stay online for the
///     node's replay gate) and reconnect (fresh invite on request).
///
/// Joiner acceptance (`HUB_HN9XX_JOINER_ACCEPTANCE=1`):
///   - pastes `HUB_HN9XX_INVITATION` through `HubNets.main.join`,
///   - verifies hub connectivity through the inviter overlay and real overlay
///     traffic (ICMP ping of the inviter overlay address and a TCP connect to
///     hub-server `:1997` through the tunnel, plus a hub-server RPC round trip),
///   - unjoins (tunnel stop + profile removal + keychain cleanup),
///   - writes `HUB_HN9XX_RESULT_JSON`
///     (`{joined, hub, overlay, traffic, unjoined, error}`) and exits.
///
/// Everything is driven from `integration/hn9xx_mac_mac_join.sh`; no
/// loopback shortcuts: traffic assertions run against the inviter's overlay
/// address over real LAN/Tailscale UDP.

@MainActor
enum HN9xxAcceptance {
  private static let timeout: Duration = .seconds(150)

  struct OwnerResult: Codable {
    let invitation: String
    let nodeEndpoint: String
    let hub: String
    let expiresAt: String
  }

  struct JoinerResult: Codable {
    let joined: Bool
    let hub: String
    let overlay: String
    let traffic: String
    let unjoined: Bool
    let error: String?
  }

  static func runOwner() async {
    if ProcessInfo.processInfo.environment["HUB_HN9XX_DUMP_DIAG"] != nil {
      // Dump the extension's diagnostics. Two channels: the in-memory buffer
      // pulled over provider IPC (the macOS extension's file writes land in a
      // persona-scoped container the app cannot read), then the app-group
      // file as a fallback (iOS joiner).
      var diag = ""
      if let pulled = try? await PacketTunnelController().extensionDiagnostics() {
        diag = pulled
      }
      if diag.isEmpty {
        diag = readExtensionDiagnostics()
      }
      writeStdout("[HN9XX] mac-diag " + diag)
      terminateApp()
      return
    }
    if ProcessInfo.processInfo.environment["HUB_HN9XX_RESET_PROFILE"] != nil {
      let tunnel = try? PacketTunnelController()
      await tunnel?.stop()
      try? await tunnel?.deleteSystemProfile()
      writeStdout("[HN9XX] profile reset")
      try? await Task.sleep(for: .seconds(1))
      terminateApp()
      return
    }
    progress("owner acceptance starting")
    // A previous run's profile file can be unreadable by this process (the
    // app-group container's persona/permission state) — the acceptance always
    // joins fresh, so drop any installed profile first.
    if let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.dev.v57.hub"
    ) {
      try? FileManager.default.removeItem(
        at: container.appendingPathComponent("hub-network-profile-v1.json", isDirectory: false)
      )
    }
    let hubAddress = ProcessInfo.processInfo.environment["HUB_HN9XX_HUB"]
      ?? "ws://127.0.0.1:1997"
    let nodeEndpoint = ProcessInfo.processInfo.environment["HUB_HN9XX_NODE_ENDPOINT"] ?? ""
    let result = await ownerBody(hubAddress: hubAddress, nodeEndpoint: nodeEndpoint)
    emitResult(result)
    progress("owner result written (invitation=\(result.invitation.isEmpty ? "empty" : "ok"))")
    // Stay alive: the node requires the inviter to remain online for the
    // single-use replay gate, and the driver kills this instance before the
    // reconnect phase.
    await stayAlive()
  }

  static func runJoiner() async {
    guard let invitation = ProcessInfo.processInfo.environment["HUB_HN9XX_INVITATION"],
          !invitation.isEmpty else {
      emitResult(JoinerResult(
        joined: false, hub: "", overlay: "", traffic: "",
        unjoined: false, error: "HUB_HN9XX_INVITATION is required"
      ))
      return
    }
    clearExtensionDiagnostics()
    // A killed run (watchdog, missed consent) leaves a staged native-join
    // record; the coordinator refuses to join over it (transactionConflict).
    // An acceptance run is always a fresh join — drop the staging directory.
    if let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      try? FileManager.default.removeItem(
        at: root.appendingPathComponent("Hub/NativeNetworkJoins/v1", isDirectory: true)
      )
    }
    // A hung earlier run can leave its tunnel up (activeVPNConflict); stop it, keeping the approved profile
    if let tunnel = try? PacketTunnelController() { await tunnel.stop() }
    // A rebuilt test hub answers at the same overlay address with a new hub key, and a pinned key is never
    // replaced on its own. Forget pins for overlay addresses (100.64.0.0/10) only; real hubs keep theirs.
    let pins = HubKeyPins.beside(KeyChain.main)
    for address in pins.all.keys {
      guard let url = URL(string: address), let host = url.host,
            host.hasPrefix("100."), let second = Int(host.split(separator: ".")[1]), (64...127).contains(second)
      else { continue }
      pins.forget(url)
    }
    do {
      let decoded = try NetworkInvitationParser.decode(invitation)
      progress("joiner: invitation decoded (replay \(String(decoded.replayId.prefix(8))))")
      let joinedHub = try await runJoinerJoin(invitation: invitation)
      progress("joiner: joined hub \(joinedHub.settings.address.absoluteString)")
      let host = joinedHub.settings.address.host ?? ""
      let overlay = host
      progress("joiner: overlay host \(host); verifying traffic")
      let traffic = try await verifyOverlayTraffic(hub: joinedHub, overlayHost: host)
      progress("joiner: traffic \(traffic); unjoining")
      let unjoined = await unjoin(hub: joinedHub, replayId: decoded.replayId)
      progress("joiner: unjoined=\(unjoined)")
      emitResult(JoinerResult(
        joined: true, hub: joinedHub.settings.address.absoluteString,
        overlay: overlay, traffic: traffic, unjoined: unjoined, error: nil
      ))
    } catch {
      let diag = readExtensionDiagnostics()
      emitResult(JoinerResult(
        joined: false, hub: "", overlay: "", traffic: "",
        unjoined: false,
        error: String(describing: error)
          + (diag.isEmpty ? "" : " | ext: " + diag.trimmingCharacters(in: .whitespacesAndNewlines))
      ))
    }
    try? await Task.sleep(for: .seconds(1))
    terminateApp()
  }

  /// Reads the extension's tunnel-start diagnostics (app group file written
  /// by the PacketTunnelProvider; the extension's stderr is not bridged by
  /// devicectl --console on iOS).
  private static func readExtensionDiagnostics() -> String {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.dev.v57.hub"
    ) else { return "" }
    let url = container.appendingPathComponent("hn9xx-diag.log", isDirectory: false)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  private static func clearExtensionDiagnostics() {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.dev.v57.hub"
    ) else { return }
    let url = container.appendingPathComponent("hn9xx-diag.log", isDirectory: false)
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: Owner

  private static func ownerBody(
    hubAddress: String,
    nodeEndpoint: String
  ) async -> OwnerResult {
    do {
      progress("waiting for owner hub \(hubAddress)")
      let hub = try await waitForOwnerHub(at: hubAddress)
      progress("owner hub connected")
      if !nodeEndpoint.isEmpty {
        progress("setting node endpoint \(nodeEndpoint)")
        try await hub.client.send("hub/net/node/set", nodeEndpoint as String)
        let _: String = try await firstValue(
          from: hub.client.values("hub/net/node")
        ) { $0 == nodeEndpoint }
        // The invite generator and the local inviter profile read this store;
        // it must be set before joining so the installed profile enables the
        // extension's online-inviter.
        HubService.Group.HubNetworkNodeEndpointStore.shared.set(nodeEndpoint)
        progress("node endpoint confirmed")
      }
      progress("joining local network")
      try await hub.net.joinNetwork(enabled: true)
      guard hub.net.isJoined else { throw AcceptanceError.notJoined }
      progress("local network joined")
      // The node only accepts a joiner's session.open while the inviter is
      // registered, so wait for the extension's online-inviter registration
      // before issuing the invitation.
      try await waitForInviterRegistration()
      progress("inviter registered with node")
      let readiness: HubNetworkLocalAgentStatus = try await firstValue(
        from: hub.client.values("hub/net/local-agent")
      ) { $0.canIssueInvitation }
      progress("local agent ready (binding=\(readiness.bindingKind?.rawValue ?? "nil"))")
      let netAgents: [HubNetInfo] = try await firstValue(
        from: hub.client.values("hub/net/list")
      ) { $0.contains(where: { $0.localIp == "127.0.0.1" }) }
      guard let localAgent = netAgents.first(where: { $0.localIp == "127.0.0.1" }) else {
        throw AcceptanceError.timeout("local net/invite provider")
      }
      let invitation = try await hub.createNetworkInvitation(service: localAgent.id)
      let expiresAt = ISO8601DateFormatter().string(
        from: Date().addingTimeInterval(7 * 24 * 60 * 60)
      )
      progress("invitation created")
      writeStdout("[HN9XX] owner-invitation \(invitation)")
      return OwnerResult(
        invitation: invitation,
        nodeEndpoint: nodeEndpoint,
        hub: hub.settings.address.absoluteString,
        expiresAt: expiresAt
      )
    } catch {
      progress("owner failed: \(String(describing: error))")
      return OwnerResult(
        invitation: "", nodeEndpoint: nodeEndpoint,
        hub: hubAddress, expiresAt: ""
      )
    }
  }

  private static func waitForOwnerHub(at address: String) async throws -> Hub {
    guard let url = URL(string: address),
          (url.scheme == "ws" || url.scheme == "wss") else {
      throw AcceptanceError.badAddress(address)
    }
    if !Hubs.main.list.contains(where: { $0.settings.address == url }) {
      _ = Hubs.main.insert(with: Hub.Settings(name: "HN-9xx Owner Hub", address: url))
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let hub = Hubs.main.list.first(where: {
        $0.settings.address == url
          && $0.isConnected
          && $0.api.contains("hub/net/node/set")
          && $0.api.contains("hub/net/local-agent")
      }) {
        return hub
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw AcceptanceError.timeout("connected owner Hub with hub/net/node/set")
  }

  /// Waits until the extension reports the online-inviter registered with the
  /// node. Without this the joiner's `session.open` fails `inviter offline`.
  private static func waitForInviterRegistration() async throws {
    let tunnel = try PacketTunnelController()
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let status = try? await tunnel.inviterStatus(), status.registered {
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw AcceptanceError.timeout("inviter registration with hub-net-node")
  }

  // MARK: Joiner

  private static func runJoinerJoin(invitation: String) async throws -> Hub {
    progress("joiner: join start (150s deadline)")
    let box = JoinBox()
    let outcome: Result<Hub, Error> = await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<Hub, Error>, Never>) in
      Task {
        do {
          let hub = try await HubNets.main.join(link: invitation)
          box.complete(continuation, .success(hub))
        } catch {
          box.complete(continuation, .failure(error))
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 150) {
        box.complete(
          continuation,
          .failure(AcceptanceError.timeout("join through inviter overlay (app or extension hung)"))
        )
      }
    }
    let hub = try outcome.get()
    progress("joiner: join returned; waiting for hub connection")
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while ContinuousClock.now < deadline {
      if hub.isConnected { return hub }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AcceptanceError.timeout("joined hub connection through inviter overlay")
  }

  /// Real overlay traffic both directions, no loopback:
  /// 1. ICMP ping of the inviter overlay IPv4 through the tunnel.
  /// 2. TCP connect to hub-server `:1997` on the inviter overlay address.
  /// 3. One hub-server RPC round trip (`hub/net/list`) over the same path.
  private static func verifyOverlayTraffic(hub: Hub, overlayHost: String) async throws -> String {
    guard !overlayHost.isEmpty else { throw AcceptanceError.badAddress("") }
    var results: [String] = []
    let ipv4 = overlayHost.replacingOccurrences(of: "[", with: "")
      .replacingOccurrences(of: "]", with: "")
    let containsColon = ipv4.contains(":")
#if os(macOS)
    if !containsColon {
      let ping = Process()
      ping.executableURL = URL(fileURLWithPath: "/sbin/ping")
      ping.arguments = ["-c", "2", "-t", "3", ipv4]
      let pipe = Pipe()
      ping.standardOutput = pipe
      ping.standardError = pipe
      do {
        try ping.run()
        ping.waitUntilExit()
        if ping.terminationStatus == 0 {
          results.append("ping-ok")
        } else {
          results.append("ping-failed")
        }
      } catch {
        results.append("ping-unavailable")
      }
    }
#endif
    let tcpOK = await tcpConnectOK(host: ipv4, port: 1997)
    results.append(tcpOK ? "tcp-ok" : "tcp-failed")
    let rpcOK = (try? await hubRPC(hub)) != nil
    results.append(rpcOK ? "rpc-ok" : "rpc-failed")
    guard tcpOK || rpcOK else { throw AcceptanceError.trafficTimeout }
    return results.joined(separator: ",")
  }

  private static func tcpConnectOK(host: String, port: UInt16) async -> Bool {
    let connection = NWConnection(
      to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
      using: .tcp
    )
    let box = ConnectBox()
    let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          connection.cancel()
          box.complete({ continuation.resume(returning: $0) }, true)
        case .failed:
          connection.cancel()
          box.complete({ continuation.resume(returning: $0) }, false)
        default:
          break
        }
      }
      connection.start(queue: .global())
      DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
        if connection.state != .ready { connection.cancel() }
        box.complete({ continuation.resume(returning: $0) }, false)
      }
    }
    return ok
  }

  /// An authenticated round trip over the overlay. `hub/net/list` is owner-only since the device layer, and a
  /// joiner isn't an owner, so this reads `hub/api/services`, which any keyed caller may read.
  private static func hubRPC(_ hub: Hub) async throws {
    _ = try await firstValue(from: hub.client.values("hub/api/services", "")) { _ in true }
  }

  private static func firstValue<S: AsyncSequence & Sendable>(
    from stream: S,
    where predicate: @escaping @Sendable (S.Element) -> Bool
  ) async throws -> S.Element where S.Element: Sendable {
    try await withThrowingTaskGroup(of: S.Element.self) { group in
      group.addTask {
        for try await value in stream where predicate(value) { return value }
        throw AcceptanceError.timeout("hub/api/services")
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw AcceptanceError.timeout("hub/api/services")
      }
      let value = try await group.next()!
      group.cancelAll()
      return value
    }
  }

  private static func unjoin(hub: Hub, replayId: String) async -> Bool {
    let tunnel: PacketTunnelController
    do {
      tunnel = try PacketTunnelController()
      await tunnel.stop()
      try await tunnel.remove()
      if let decoded = Hubs.main.list.first(where: {
        $0.settings.address == hub.settings.address
      }) {
        Hubs.main.remove(with: decoded.settings)
      }
      try? await NativeJoinStore.main.cleanup(transactionId: replayId)
      return true
    } catch {
      print("[HN9XX] unjoin failed: \(error)")
      return false
    }
  }

  // MARK: Plumbing

  private static func stayAlive() async {
    while true {
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private static func progress(_ line: String) {
    writeStdout("[HN9XX] " + line)
  }

  private static func emitResult(_ value: some Encodable) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(value)
      writeStdout("[HN9XX] result-json " + data.base64EncodedString())
    } catch {
      writeStdout("[HN9XX] result encode failed: \(error)")
    }
  }

  /// Unbuffered stdout so the driver can parse acceptance results from logs
  /// even though the app is sandboxed (no writable shared filesystem path).
  private static func writeStdout(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }

  /// Ends the acceptance process. iOS has no AppKit; devicectl launches the
  /// app with a console bridge, so exit(0) is the clean termination.
  private static func terminateApp() {
#if os(macOS)
    NSApp.terminate(nil)
#else
    exit(0)
#endif
  }

  private final class ConnectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func complete(_ resume: (Bool) -> Void, _ ok: Bool) {
      lock.lock()
      defer { lock.unlock() }
      guard !finished else { return }
      finished = true
      resume(ok)
    }
  }

  /// Resume-once guard for the join deadline race (same idiom as the invite
  /// OnceBox: a plain task group waits for children at scope exit, and the
  /// channel/extension continuations never resume on cancellation).
  private final class JoinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func complete(
      _ continuation: CheckedContinuation<Result<Hub, Error>, Never>,
      _ outcome: Result<Hub, Error>
    ) {
      lock.lock()
      defer { lock.unlock() }
      guard !finished else { return }
      finished = true
      continuation.resume(returning: outcome)
    }
  }

  enum AcceptanceError: Error, CustomStringConvertible {
    case badAddress(String)
    case notJoined
    case timeout(String)
    case trafficTimeout

    var description: String {
      switch self {
      case .badAddress(let value): "invalid hub address: \(value)"
      case .notJoined: "owner did not join the local network"
      case .timeout(let condition): "timed out waiting for \(condition)"
      case .trafficTimeout: "overlay traffic check timed out"
      }
    }
  }
}

/// Overlay shown while an HN-9xx acceptance runs.
struct HN9xxAcceptanceView: View {
  @State private var message = "running"

  var body: some View {
    VStack(spacing: 12) {
      Text("HN-9xx Acceptance")
        .font(.headline)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      let isJoiner = ProcessInfo.processInfo.environment["HUB_HN9XX_JOINER_ACCEPTANCE"] != nil
      if isJoiner {
        message = "joiner acceptance running"
        await HN9xxAcceptance.runJoiner()
      } else {
        message = "owner acceptance running (stays alive)"
        await HN9xxAcceptance.runOwner()
      }
    }
  }
}
#endif
