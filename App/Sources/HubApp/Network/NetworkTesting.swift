#if DEBUG && os(macOS)
import AppKit
import Foundation
import HubService
import Network
import Observation
import SwiftUI

/// Env-driven cross-machine test harness for the Hub Network redesign.
///
/// Environments:
///   HUBTESTENV=network  local hub owner; hub-server API surface smoke
///   HUBTESTENV=host     local hub owner; TCP server on 18403, shares invite,
///                       waits for client completion
///   HUBTESTENV=client   remote; joins via invite, verifies overlay traffic
///   HUBTESTENV=replay   remote; consumes a used invite, expects rejection
///   HUBTESTENV=stress   local; N join/unjoin cycles with fresh invites
///   HUBTESTENV=gateway  remote; selects host gateway, fetches public URL
///
/// Config env:
///   HUBTESTENV_HUB        hub-server address (default ws://127.0.0.1:1997)
///   HUBTESTENV_NODE       node endpoint (default empty -> server default)
///   HUBTESTENV_INVITE     invite code for client/replay
///   HUBTESTENV_PORT       TCP port (default 18403)
///   HUBTESTENV_STRESS_N   stress cycles (default 3)
///
/// Results are printed as `[HUBTEST] pass|fail "<title>"` lines; the harness
/// parses them from stdout. Host stays alive (owns the TCP server); all other
/// environments exit one second after completion.

enum HubTestEnvironment: String {
  case key
  case network
  case host
  case client
  case replay
  case stress
  case gateway
}

enum HubTestState: Sendable {
  case pending
  case running
  case passed
  case failed(String)

  var symbol: String {
    switch self {
    case .pending: "circle"
    case .running: "arrowtriangle.right.circle.fill"
    case .passed: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    }
  }

  var color: Color {
    switch self {
    case .pending: .secondary
    case .running: .blue
    case .passed: .green
    case .failed: .red
    }
  }
}

@MainActor @Observable
final class HubTestItem {
  let title: String
  var state: HubTestState = .pending

  init(title: String) {
    self.title = title
  }
}

struct HubTestCompletion: Codable, Sendable {
  let key: String
  let result: String
  let completedAt: String
}

@MainActor
final class HubTestRunner {
  static let main = HubTestRunner()

  let environment: HubTestEnvironment
  private(set) var items: [HubTestItem] = []
  private(set) var finished = false
  private(set) var invite: String?
  private(set) var hub: Hub?
  private var port: UInt16 = 18403
  private var listener: NWListener?

  init() {
    let raw = ProcessInfo.processInfo.environment["HUBTESTENV"] ?? ""
    environment = HubTestEnvironment(rawValue: raw) ?? .network
    let rawPort = ProcessInfo.processInfo.environment["HUBTESTENV_PORT"]
    if let rawPort, let value = UInt16(rawPort) {
      port = value
    }
    items = tasks(for: environment)
  }

  var isHost: Bool { environment == .host }

  func run() async {
    if environment == .key {
      print("[HUBTEST] key \(KeyChain.main.publicKey())")
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
      }
      return
    }
    let hubAddress = ProcessInfo.processInfo.environment["HUBTESTENV_HUB"]
      ?? "ws://127.0.0.1:1997"

    let ownerHub = await connectedHub(at: hubAddress)
    guard let ownerHub else {
      try? await Task.sleep(for: .milliseconds(100))
      await run(items[0])
      finished = true
      print("[HUBTEST] overall fail 1 tasks")
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
      }
      return
    }
    hub = ownerHub

    for item in items {
      try? await Task.sleep(for: .milliseconds(100))
      await run(item)
    }

    finished = true
    let passed = items.allSatisfy { if case .passed = $0.state { true } else { false } }
    print("[HUBTEST] overall \(passed ? "pass" : "fail") \(items.count) tasks")

    if !isHost {
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
      }
    }
  }

  private func run(_ item: HubTestItem) async {
    item.state = .running
    do {
      let operation = try operations()[item.title]
      try await operation?()
      item.state = .passed
      print("[HUBTEST] pass \"\(item.title)\"")
    } catch {
      item.state = .failed(String(describing: error))
      print("[HUBTEST] fail \"\(item.title)\" \(String(describing: error))")
    }
  }

  private func operations() throws -> [String: @MainActor () async throws -> Void] {
    guard let hub else { throw HubTestError.hubUnavailable }
    switch environment {
    case .key:
      return [:]
    case .network:
      return networkOperations(hub)
    case .host:
      return hostOperations(hub)
    case .client:
      return try clientOperations()
    case .replay:
      return try replayOperations()
    case .stress:
      return stressOperations(hub)
    case .gateway:
      return try gatewayOperations()
    }
  }

  // MARK: Task lists

  private func tasks(for environment: HubTestEnvironment) -> [HubTestItem] {
    switch environment {
    case .key:
      return []
    case .network:
      return networkTasks()
    case .host:
      return hostTasks()
    case .client:
      return clientTasks()
    case .replay:
      return replayTasks()
    case .stress:
      return stressTasks()
    case .gateway:
      return gatewayTasks()
    }
  }

  private func networkTasks() -> [HubTestItem] {
    [
      HubTestItem(title: "Connect to hub-server"),
      HubTestItem(title: "Check permissions"),
      HubTestItem(title: "Join network"),
      HubTestItem(title: "Share port"),
      HubTestItem(title: "Allow to use as VPN"),
      HubTestItem(title: "Share invite"),
    ]
  }

  private func hostTasks() -> [HubTestItem] {
    [
      HubTestItem(title: "Connect to hub-server"),
      HubTestItem(title: "Check permissions"),
      HubTestItem(title: "Join network"),
      HubTestItem(title: "Share port"),
      HubTestItem(title: "Allow to use as VPN"),
      HubTestItem(title: "Start TCP server"),
      HubTestItem(title: "Share invite"),
      HubTestItem(title: "Wait for client completion"),
    ]
  }

  private func clientTasks() -> [HubTestItem] {
    [
      HubTestItem(title: "Use invite"),
      HubTestItem(title: "Join network"),
      HubTestItem(title: "Join hub-server"),
      HubTestItem(title: "Resolve host overlay address"),
      HubTestItem(title: "Send requests to \(port)"),
      HubTestItem(title: "Report completion"),
    ]
  }

  private func replayTasks() -> [HubTestItem] {
    [
      HubTestItem(title: "Parse used invite"),
      HubTestItem(title: "Replay rejected"),
    ]
  }

  private func stressTasks() -> [HubTestItem] {
    let cycles = Int(ProcessInfo.processInfo.environment["HUBTESTENV_STRESS_N"] ?? "3") ?? 3
    return (1...cycles).map { index in
      [
        HubTestItem(title: "Cycle \(index) join"),
        HubTestItem(title: "Cycle \(index) traffic"),
        HubTestItem(title: "Cycle \(index) unjoin"),
      ]
    }.flatMap { $0 }
  }

  private func gatewayTasks() -> [HubTestItem] {
    [
      HubTestItem(title: "Join network"),
      HubTestItem(title: "Resolve host gateway"),
      HubTestItem(title: "Fetch public URL through gateway"),
    ]
  }

  // MARK: Operations

  private func networkOperations(_ hub: Hub) -> [String: @MainActor () async throws -> Void] {
    [
      "Connect to hub-server": { try await self.assertConnected(hub) },
      "Check permissions": { try await self.assertPermissions(hub) },
      "Join network": { try await self.joinNetwork(hub) },
      "Share port": { try await self.sharePort(hub, port: self.port) },
      "Allow to use as VPN": { try await self.enableGatewayServing(hub) },
      "Share invite": { try await self.createInvite(hub) },
    ]
  }

  private func hostOperations(_ hub: Hub) -> [String: @MainActor () async throws -> Void] {
    var operations = networkOperations(hub)
    operations["Start TCP server"] = { try await self.startTCPServer(port: self.port) }
    operations["Wait for client completion"] = { try await self.waitForClientCompletion(hub) }
    return operations
  }

  private func clientOperations() throws -> [String: @MainActor () async throws -> Void] {
    let link = try requiredInvite()
    return [
      "Use invite": { _ = try NetworkInvitationParser.decode(link) },
      "Join network": { _ = try await self.joinWithInvite(link) },
      "Join hub-server": { try await self.assertJoinedHubConnected() },
      "Resolve host overlay address": { _ = try await self.hostOverlayIPv4() },
      "Send requests to \(port)": { try await self.sendTrafficToHost(port: self.port) },
      "Report completion": { try await self.reportCompletion(hub: self.hub, result: "client-traffic-ok") },
    ]
  }

  private func replayOperations() throws -> [String: @MainActor () async throws -> Void] {
    let link = try requiredInvite()
    return [
      "Parse used invite": { _ = try NetworkInvitationParser.decode(link) },
      "Replay rejected": {
        do {
          _ = try await HubNets.main.join(link: link)
          throw HubTestError.replayNotRejected
        } catch let error as HubTestError {
          throw error
        } catch {
          let message = String(describing: error).lowercased()
          guard message.contains("replay") || message.contains("used")
            || message.contains("single-use") else {
            throw error
          }
        }
      },
    ]
  }

  private func stressOperations(_ hub: Hub) -> [String: @MainActor () async throws -> Void] {
    let cycles = Int(ProcessInfo.processInfo.environment["HUBTESTENV_STRESS_N"] ?? "3") ?? 3
    var operations: [String: @MainActor () async throws -> Void] = [:]
    for index in 1...cycles {
      operations["Cycle \(index) join"] = {
        try await self.joinNetwork(hub)
        _ = try await self.createInvite(hub)
      }
      operations["Cycle \(index) traffic"] = {
        try await self.verifyLocalTunnel(hub)
      }
      operations["Cycle \(index) unjoin"] = {
        try await self.unjoin(hub)
      }
    }
    return operations
  }

  private func gatewayOperations() throws -> [String: @MainActor () async throws -> Void] {
    let link = try requiredInvite()
    return [
      "Join network": { _ = try await self.joinWithInvite(link) },
      "Resolve host gateway": { _ = try await self.hostOverlayIPv4() },
      "Fetch public URL through gateway": { try await self.fetchThroughGateway() },
    ]
  }

  // MARK: Individual checks

  private func connectedHub(at address: String) async -> Hub? {
    guard let url = URL(string: address),
          (url.scheme == "ws" || url.scheme == "wss") else { return nil }
    if !Hubs.main.list.contains(where: { $0.settings.address == url }) {
      _ = Hubs.main.insert(with: Hub.Settings(name: "Hub Test", address: url))
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
      if let hub = Hubs.main.list.first(where: {
        $0.settings.address == url && $0.isConnected
      }) {
        return hub
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return Hubs.main.list.first(where: { $0.settings.address == url })
  }

  private func assertConnected(_ hub: Hub) throws {
    guard hub.isConnected else { throw HubTestError.hubUnavailable }
  }

  private func assertPermissions(_ hub: Hub) async throws {
    let required = [
      "hub/net/share", "hub/net/local-agent", "hub/net/list",
      "net/invite", "network/agents/list",
    ]
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
      let current = hub.api
      let missing = required.filter { !current.contains($0) }
      if missing.isEmpty { return }
      try? await Task.sleep(for: .milliseconds(200))
    }
    let missing = required.filter { !hub.api.contains($0) }
    throw HubTestError.missingPermissions(missing)
  }

  private func joinNetwork(_ hub: Hub) async throws {
    try await hub.net.joinNetwork(enabled: true)
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while ContinuousClock.now < deadline {
      if await (try PacketTunnelController()).status == .connected,
         hub.networkAppAgent.availableIdentity != nil {
        return
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    throw HubTestError.tunnelNotReady
  }

  private func sharePort(_ hub: Hub, port: UInt16) async throws {
    try await hub.net.shareTcp(port: Int(port), enabled: true)
    guard hub.net.sharedTcp.contains(Int(port)) else {
      throw HubTestError.portNotShared(port)
    }
  }

  private func enableGatewayServing(_ hub: Hub) async throws {
    try await hub.net.shareNetwork(enabled: true)
    guard hub.net.isSharing else { throw HubTestError.gatewayNotServing }
  }

  private func createInvite(_ hub: Hub) async throws {
    let link = try await hub.net.createInviteCode()
    guard (try? NetworkInvitationParser.decode(link)) != nil else {
      throw HubTestError.invalidInvite
    }
    invite = link
    print("[HUBTEST] invite \(link)")
  }

  private func startTCPServer(port: UInt16) async throws {
    let listener: NWListener
    do {
      listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    } catch {
      throw HubTestError.serverBindFailed(port)
    }
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
        if let data {
          connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
          })
        }
      }
    }
    listener.stateUpdateHandler = { state in
      if case .failed = state {
        print("[HUBTEST] tcp-server failed: \(state)")
      }
    }
    listener.start(queue: .global())
    try? await Task.sleep(for: .milliseconds(300))
  }

  private func waitForClientCompletion(_ hub: Hub) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(180))
    while ContinuousClock.now < deadline {
      for try await completion: HubTestCompletion in hub.client.values("hub/net/test/results") {
        print("[HUBTEST] client-completed \(completion.key) \(completion.result)")
        return
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
    throw HubTestError.clientTimeout
  }

  private func requiredInvite() throws -> String {
    guard let link = ProcessInfo.processInfo.environment["HUBTESTENV_INVITE"],
          !link.isEmpty else {
      throw HubTestError.missingInvite
    }
    return link
  }

  private func joinWithInvite(_ link: String) async throws -> Hub {
    let hub = try await HubNets.main.join(link: link)
    self.hub = hub
    return hub
  }

  private func assertJoinedHubConnected() throws {
    guard let hub, hub.isConnected else { throw HubTestError.hubUnavailable }
  }

  private func hostOverlayIPv4() async throws -> String {
    guard let hub else { throw HubTestError.hubUnavailable }
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while ContinuousClock.now < deadline {
      let agents = hub.state.networkAgents.value
      if let host = agents.first(where: { !$0.connectedAt.isEmpty }),
         let ipv4 = host.overlayAddresses.first(where: { !$0.contains(":") }) {
        return ipv4
      }
      hub.state.networkAgents.subscribe(hub: hub)
      try? await Task.sleep(for: .milliseconds(200))
    }
    throw HubTestError.hostUnresolved
  }

  private func sendTrafficToHost(port: UInt16) async throws {
    let hostIP = try await hostOverlayIPv4()
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(hostIP),
      port: NWEndpoint.Port(rawValue: port)!
    )
    let connection = NWConnection(to: endpoint, using: .tcp)
    let payload = Data("hub-test-\(UUID().uuidString)".utf8)
    let received = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      connection.stateUpdateHandler = { state in
        if case .failed(let error) = state {
          continuation.resume(throwing: error)
        }
      }
      connection.start(queue: .global())
      connection.send(content: payload, completion: .contentProcessed { error in
        if let error {
          continuation.resume(throwing: error)
        }
      })
      connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
        if let data {
          continuation.resume(returning: data)
        } else if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(throwing: HubTestError.trafficFailed)
        }
      }
    }
    connection.cancel()
    guard received == payload else { throw HubTestError.trafficMismatch }
  }

  private func reportCompletion(hub: Hub?, result: String) async throws {
    guard let hub else { throw HubTestError.hubUnavailable }
    struct Body: Encodable { let result: String }
    let _: Bool = try await hub.client.send("hub/net/test/complete", Body(result: result))
  }

  private func verifyLocalTunnel(_ hub: Hub) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while ContinuousClock.now < deadline {
      if await (try PacketTunnelController()).status == .connected {
        return
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    throw HubTestError.tunnelNotReady
  }

  private func unjoin(_ hub: Hub) async throws {
    try await hub.net.joinNetwork(enabled: false)
  }

  private func fetchThroughGateway() async throws {
    guard let hub else { throw HubTestError.hubUnavailable }
    guard let host = hub.net.devices.first(where: { !$0.overlayAddresses.isEmpty }) else {
      throw HubTestError.hostUnresolved
    }
    try await hub.net.vpn(through: host)
    var request = URLRequest(url: URL(string: "http://example.com")!)
    request.timeoutInterval = 20
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode < 500 else {
      throw HubTestError.gatewayFetchFailed
    }
    try await hub.net.disableVpn()
  }
}

enum HubTestError: Error, CustomStringConvertible {
  case hubUnavailable
  case missingPermissions([String])
  case tunnelNotReady
  case portNotShared(UInt16)
  case gatewayNotServing
  case invalidInvite
  case serverBindFailed(UInt16)
  case clientTimeout
  case missingInvite
  case hostUnresolved
  case trafficFailed
  case trafficMismatch
  case replayNotRejected
  case gatewayFetchFailed

  var description: String {
    switch self {
    case .hubUnavailable: "hub-server is not connected"
    case .missingPermissions(let paths): "missing permissions: \(paths.joined(separator: ", "))"
    case .tunnelNotReady: "tunnel did not reach connected"
    case .portNotShared(let port): "port \(port) is not shared"
    case .gatewayNotServing: "gateway serving did not become available"
    case .invalidInvite: "invite did not decode"
    case .serverBindFailed(let port): "TCP server failed to bind \(port)"
    case .clientTimeout: "timed out waiting for client completion"
    case .missingInvite: "HUBTESTENV_INVITE is required"
    case .hostUnresolved: "host overlay address not found in network/agents/list"
    case .trafficFailed: "overlay TCP connection failed"
    case .trafficMismatch: "overlay TCP echo mismatch"
    case .replayNotRejected: "used invite was accepted again"
    case .gatewayFetchFailed: "public URL fetch through gateway failed"
    }
  }
}

/// Overlay shown whenever HUBTESTENV is set. Lists every task with its state.
struct NetworkTestingView: View {
  @State private var runner = HubTestRunner.main

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Hub Network Tests")
        .font(.headline)
      Text("environment: \(runner.environment.rawValue)")
        .font(.caption)
        .foregroundStyle(.secondary)
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        ForEach(runner.items, id: \.title) { item in
          HStack(spacing: 8) {
            Image(systemName: item.state.symbol)
              .foregroundStyle(item.state.color)
            Text(item.title)
              .lineLimit(1)
          }
        }
      }
      if runner.finished {
        Text("Finished")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.black.opacity(0.85))
    .task {
      await runner.run()
    }
  }
}
#endif
