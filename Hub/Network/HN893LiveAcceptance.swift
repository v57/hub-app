#if os(macOS) && DEBUG
import Foundation
import NetworkExtension

/// Signed, opt-in HN-893 acceptance driven by `integration/hn893_apple_join.sh`.
@MainActor
enum HN893LiveAcceptance {
  private static let timeout: Duration = .seconds(90)

  struct Result: Codable {
    let invitation: String
    let expiresAt: String
    let hub: String
    let baselineKeys: [String]
  }

  static func run() async throws {
    let outputURL = try requiredOutputURL()
    try? FileManager.default.removeItem(at: outputURL)

    let hub = try await waitForHub()
    let tunnel = try PacketTunnelController()
    var installedByAcceptance = false
    if await tunnel.status == .notInstalled {
      try await tunnel.authorizeAndInstallLocalHub(hub: hub)
      installedByAcceptance = true
    } else {
      try await tunnel.restoreInstalledLocalMembership(hub: hub)
    }

    defer {
      Task { @MainActor in
        await hub.networkAppAgent.disable(tunnel: tunnel)
        await tunnel.stop()
        if installedByAcceptance { try? await tunnel.remove() }
      }
    }

    if await tunnel.status != .connected { try await tunnel.start() }
    hub.networkAppAgent.enable(tunnel: tunnel)

    let readiness: HubNetworkLocalAgentStatus = try await firstValue(
      from: hub.client.values("hub/net/local-agent")
    ) {
      $0.canIssueInvitation && $0.bindingKind == .appleApp
    }
    guard readiness.readinessLabel == "Available (This Mac)" else {
      throw AcceptanceError.unexpectedReadiness(readiness.readinessLabel)
    }

    let baseline: [HubNetworkAgent] = try await firstValue(
      from: hub.client.values("network/agents/list")
    ) { _ in true }
    let baselineKeys = Set(baseline.map(\.key))
    let netAgents: [HubNetInfo] = try await firstValue(
      from: hub.client.values("hub/net/list")
    ) { $0.contains(where: { $0.localIp == "127.0.0.1" }) }
    guard let localAgent = netAgents.first(where: { $0.localIp == "127.0.0.1" }) else {
      throw AcceptanceError.unexpectedReadiness("No local net/invite service")
    }
    let invitation = try await hub.createNetworkInvitation(service: localAgent.id)
    let result = Result(
      invitation: invitation,
      expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 24 * 60 * 60)),
      hub: hub.settings.address.absoluteString,
      baselineKeys: baselineKeys.sorted()
    )
    try JSONEncoder().encode(result).write(to: outputURL, options: .atomic)

    let _: [HubNetworkAgent] = try await firstValue(
      from: hub.client.values("network/agents/list")
    ) { agents in
      agents.contains { !baselineKeys.contains($0.key) && $0.connectedAt.isEmpty == false }
    }
  }

  private static func waitForHub() async throws -> Hub {
    if let address = ProcessInfo.processInfo.environment["HUB_HN893_LOCAL_HUB"],
       let url = URL(string: address),
       (url.scheme == "ws" || url.scheme == "wss"),
       !Hubs.main.list.contains(where: { $0.settings.address == url }) {
      _ = Hubs.main.insert(with: Hub.Settings(name: "HN-893 Local Hub", address: url))
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let hub = Hubs.main.list.first(where: {
        $0.isConnected
          && $0.api.contains("hub/net/share")
          && $0.api.contains("hub/net/local-agent")
      }) {
        return hub
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw AcceptanceError.timeout("connected owner Hub with Apple local-agent APIs")
  }

  private static func firstValue<S: AsyncSequence & Sendable>(
    from stream: S,
    where predicate: @escaping @Sendable (S.Element) -> Bool
  ) async throws -> S.Element where S.Element: Sendable {
    try await withThrowingTaskGroup(of: S.Element.self) { group in
      group.addTask {
        for try await value in stream where predicate(value) { return value }
        throw AcceptanceError.streamEnded
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw AcceptanceError.timeout("Hub stream value")
      }
      let value = try await group.next()!
      group.cancelAll()
      return value
    }
  }

  private static func requiredOutputURL() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["HUB_HN893_RESULT_JSON"],
          path.hasPrefix("/") else {
      throw AcceptanceError.missingOutputPath
    }
    return URL(fileURLWithPath: path)
  }

  enum AcceptanceError: Error, CustomStringConvertible {
    case missingOutputPath
    case streamEnded
    case timeout(String)
    case unexpectedReadiness(String)

    var description: String {
      switch self {
      case .missingOutputPath: "HUB_HN893_RESULT_JSON must be an absolute path"
      case .streamEnded: "Hub stream ended before acceptance condition"
      case .timeout(let condition): "Timed out waiting for \(condition)"
      case .unexpectedReadiness(let label): "Unexpected readiness label: \(label)"
      }
    }
  }
}
#endif
