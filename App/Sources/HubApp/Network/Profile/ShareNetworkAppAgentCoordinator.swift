import Foundation
import Channel
import HubService
import Observation

enum ShareNetworkAppAgentState: Equatable, Sendable {
  case disabled
  case binding
  case available(PacketTunnelBootstrapIdentity)
  case unavailable(String)
}

private struct AppleAppAgentControlResponse: Decodable, Sendable {
  let success: Bool
  let status: HubNetworkLocalAgentStatus
}

/// Keeps Hub's connection-bound Apple local-agent lease aligned with the
/// active packet-tunnel instance.
///
/// One coordinator belongs to each Hub. The extension remains authoritative
/// for readiness and signing; this type only forwards fresh assertions while
/// both Channel and packet tunnel are connected.
@MainActor
@Observable
final class ShareNetworkAppAgentCoordinator {
  private static let renewalLeadTime: TimeInterval = 10
  private static let healthPollInterval = Duration.milliseconds(500)

  struct Runtime {
    var isConnected: () -> Bool
    var supports: (String) -> Bool
    var hubAddress: () -> URL
    var key: () -> String
    var loadProfile: () throws -> HubNetworkProfileConfiguration
    var bind: (AppleAppAgentBindRequest) async throws -> HubNetworkLocalAgentStatus
    var renew: (AppleAppAgentRenewRequest) async throws -> HubNetworkLocalAgentStatus
    var unbind: (AppleAppAgentUnbindRequest) async throws -> Void
    /// Registers this device's membership on the hub again, which it forgets when a connection drops
    var reregister: () async throws -> Void = {}
    /// The key the agent signs with, for the services on this machine (`LocalShareAgent`)
    var identity: () -> KeyChain? = { nil }
    var now: () -> Date = Date.init
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  }

  private let runtime: Runtime
  private let agentServices: HubService.Group?
  private var task: Task<Void, Never>?
  private var tunnel: (any PacketTunnelControlling)?
  private var desiredEnabled = false
  private var currentAssertion: AppleAppAgentReadinessAssertion?
  private var runGeneration: UInt64 = 0

  private(set) var state = ShareNetworkAppAgentState.disabled {
    didSet {
      guard state != oldValue else { return }
      print("[agent] \(state)")
      updateShareAgent()
    }
  }

  #if os(macOS)
  private var shareAgent: LocalShareAgent?
  #endif

  /// While this app is its machine's agent, the services on the machine get their shares attested by it
  private func updateShareAgent() {
    #if os(macOS)
    if case .available = state {
      guard shareAgent == nil, let identity = runtime.identity() else { return }
      let agent = LocalShareAgent(identity: identity)
      do {
        try agent.start()
        shareAgent = agent
        print("[agent] attesting shares on \(LocalShareAgent.socketPath)")
      } catch {
        print("[agent] can't listen on \(LocalShareAgent.socketPath): \(error)")
      }
    } else {
      shareAgent?.stop()
      shareAgent = nil
    }
    #endif
  }

  var errorMessage: String? {
    guard case .unavailable(let message) = state else { return nil }
    return message
  }

  var availableIdentity: PacketTunnelBootstrapIdentity? {
    guard case .available(let identity) = state else { return nil }
    return identity
  }

  init(hub: Hub) {
    agentServices = hub.service.group(enabled: false).hubNetworkAgentService()
    runtime = Runtime(
      isConnected: { [weak hub] in hub?.isConnected == true },
      supports: { [weak hub] in hub?.api.contains($0) == true },
      hubAddress: { hub.settings.address },
      key: { hub.key },
      loadProfile: { try HubNetworkProfileStore().load() },
      bind: { [weak hub] request in
        guard let hub else { throw CancellationError() }
        let response: AppleAppAgentControlResponse = try await hub.client.send(
          "hub/net/apple-agent/bind", request
        )
        guard response.success else {
          throw ShareNetworkAppAgentCoordinatorError.bindingRejected
        }
        return response.status
      },
      renew: { [weak hub] request in
        guard let hub else { throw CancellationError() }
        let response: AppleAppAgentControlResponse = try await hub.client.send(
          "hub/net/apple-agent/renew", request
        )
        guard response.success else {
          throw ShareNetworkAppAgentCoordinatorError.bindingRejected
        }
        return response.status
      },
      unbind: { [weak hub] request in
        guard let hub else { return }
        let _: AppleAppAgentControlResponse = try await hub.client.send(
          "hub/net/apple-agent/unbind", request
        )
      },
      reregister: { [weak hub] in
        guard let hub else { return }
        try await hub.net.registerAgain(tunnel: PacketTunnelController())
      },
      identity: { [weak hub] in hub?.identity }
    )
  }

  init(runtime: Runtime) {
    self.runtime = runtime
    agentServices = nil
  }

  func enable(tunnel: any PacketTunnelControlling) {
    print("ShareNetworkAppAgentCoordinator.enable")
    desiredEnabled = true
    agentServices?.isEnabled = true
    self.tunnel = tunnel
    restart()
  }

  func disable(tunnel: any PacketTunnelControlling) async {
    desiredEnabled = false
    agentServices?.isEnabled = false
    runGeneration &+= 1
    task?.cancel()
    task = nil
    await unbindCurrent()
    currentAssertion = nil
    self.tunnel = nil
    state = .disabled
  }

  func channelConnectionChanged(_ connected: Bool) {
    guard desiredEnabled else { return }
    if connected {
      guard task == nil else { return }
      restart()
    } else {
      runGeneration &+= 1
      task?.cancel()
      task = nil
      currentAssertion = nil
      state = .unavailable(
        Self.boundedMessage(
          ShareNetworkAppAgentCoordinatorError.channelDisconnected
        )
      )
    }
  }

  func apiCapabilitiesChanged() {
    guard desiredEnabled, runtime.isConnected() else { return }
    guard state == .unavailable(
      Self.boundedMessage(ShareNetworkAppAgentCoordinatorError.incompatibleHub)
    ) else { return }
    restart()
  }

  func systemDidWake() {
    guard desiredEnabled, let tunnel else { return }
    runGeneration &+= 1
    let generation = runGeneration
    task?.cancel()
    currentAssertion = nil
    task = Task { [weak self] in
      guard let self else { return }
      await self.recoverAfterWake(tunnel: tunnel, generation: generation)
    }
  }

  private func restart() {
    guard desiredEnabled, runtime.isConnected(), let tunnel else { return }
    runGeneration &+= 1
    let generation = runGeneration
    task?.cancel()
    currentAssertion = nil
    task = Task { [weak self] in
      await self?.run(tunnel: tunnel, generation: generation)
    }
  }

  private func recoverAfterWake(
    tunnel: any PacketTunnelControlling,
    generation: UInt64
  ) async {
    do {
      switch await tunnel.status {
      case .connected:
        do {
          let assertion = try await tunnel.bootstrapReadiness()
          try validate(assertion)
        } catch {
          try await restartTunnel(tunnel)
        }
      case .connecting, .reasserting:
        try await waitForConnectedTunnel(tunnel)
      case .disconnected:
        try await tunnel.start()
      case .notInstalled, .disconnecting, .invalid:
        throw ShareNetworkAppAgentCoordinatorError.tunnelDisconnected
      }
      try Task.checkCancellation()
      guard generation == runGeneration,
            desiredEnabled, runtime.isConnected() else { return }
      await run(tunnel: tunnel, generation: generation)
    } catch is CancellationError {
      return
    } catch {
      state = .unavailable(Self.boundedMessage(error))
    }
  }

  private func waitForConnectedTunnel(
    _ tunnel: any PacketTunnelControlling
  ) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      try Task.checkCancellation()
      switch await tunnel.status {
      case .connected:
        return
      case .disconnected:
        try await tunnel.start()
        return
      case .notInstalled, .disconnecting, .invalid:
        throw ShareNetworkAppAgentCoordinatorError.tunnelDisconnected
      case .connecting, .reasserting:
        try await runtime.sleep(Self.healthPollInterval)
      }
    }
    try await restartTunnel(tunnel)
  }

  private func restartTunnel(
    _ tunnel: any PacketTunnelControlling
  ) async throws {
    await tunnel.stop()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      try Task.checkCancellation()
      switch await tunnel.status {
      case .disconnected:
        try await tunnel.start()
        return
      case .notInstalled, .invalid:
        throw ShareNetworkAppAgentCoordinatorError.tunnelDisconnected
      case .connecting, .connected, .disconnecting, .reasserting:
        try await runtime.sleep(Self.healthPollInterval)
      }
    }
    throw ShareNetworkAppAgentCoordinatorError.tunnelDisconnected
  }

  private func run(
    tunnel: any PacketTunnelControlling,
    generation: UInt64
  ) async {
    var isRenewal = false
    // Failures in a row: each waits longer before trying again, up to 30 seconds
    var failures = 0

    while generation == runGeneration,
          desiredEnabled, !Task.isCancelled {
      do {
        guard runtime.isConnected() else {
          throw ShareNetworkAppAgentCoordinatorError.channelDisconnected
        }
        guard await tunnel.status == .connected else {
          throw ShareNetworkAppAgentCoordinatorError.tunnelDisconnected
        }

        state = .binding
        let assertion = try await tunnel.bootstrapReadiness()
        try Task.checkCancellation()
        guard generation == runGeneration else { throw CancellationError() }
        try validate(assertion)
        let path = isRenewal
          ? "hub/net/apple-agent/renew"
          : "hub/net/apple-agent/bind"
        guard runtime.supports(path) else {
          throw ShareNetworkAppAgentCoordinatorError.incompatibleHub
        }

        let status: HubNetworkLocalAgentStatus
        if isRenewal {
          status = try await runtime.renew(
            AppleAppAgentRenewRequest(
              version: hubNetworkModelVersion,
              assertion: assertion
            )
          )
        } else {
          status = try await runtime.bind(
            AppleAppAgentBindRequest(
              version: hubNetworkModelVersion,
              assertion: assertion
            )
          )
        }
        try Task.checkCancellation()
        guard generation == runGeneration else { throw CancellationError() }
        guard status.bindingKind == .appleApp,
              status.tunnelInstanceId == assertion.tunnelInstanceId,
              status.generation == assertion.generation else {
          throw ShareNetworkAppAgentCoordinatorError.bindingRejected
        }

        currentAssertion = assertion
        isRenewal = true
        failures = 0
        state = .available(
          PacketTunnelBootstrapIdentity(
            tunnelInstanceId: assertion.tunnelInstanceId,
            generation: assertion.generation
          )
        )
        try await waitUntilRenewal(
          assertion: assertion, tunnel: tunnel, generation: generation
        )
      } catch is CancellationError {
        break
      } catch {
        guard generation == runGeneration else { break }
        await unbindCurrent()
        currentAssertion = nil
        state = .unavailable(Self.boundedMessage(error))
        guard desiredEnabled, runtime.isConnected() else { break }
        isRenewal = false
        if error as? ShareNetworkAppAgentCoordinatorError == .tunnelDisconnected {
          try? await runtime.sleep(Self.healthPollInterval)
          continue
        }
        // The hub forgot this device (a new connection, a restarted hub): register it again before the next try
        if String(describing: error).contains("agent profile not registered") {
          do {
            try await runtime.reregister()
          } catch {
            print("ShareNetworkAppAgentCoordinator: couldn't register again:", error)
          }
        }
        // Anything else (a profile mid-write) may pass: try again, never give up while the hub and the tunnel are there
        failures += 1
        do {
          try await runtime.sleep(.seconds(min(30, 1 << min(failures - 1, 5))))
        } catch {
          break
        }
      }
    }
  }

  private func validate(
    _ assertion: AppleAppAgentReadinessAssertion
  ) throws {
    guard assertion.version == hubNetworkModelVersion,
          assertion.signatureDomain
            == "hub-network/apple-app-agent-readiness/v1",
          assertion.capabilities.contains(.invitationBootstrap) else {
      throw ShareNetworkAppAgentCoordinatorError.incompatibleExtension
    }
    let profile = try runtime.loadProfile()
    guard profile.hubURL == runtime.hubAddress(),
          profile.hubNetworkID == assertion.hubNetworkId,
          profile.profileKey == runtime.key(),
          profile.wireGuardPublicKey == nil
            || profile.wireGuardPublicKey == assertion.wireGuardKey else {
      throw ShareNetworkAppAgentCoordinatorError.profileReplaced
    }
    guard let expiry = Self.date(from: assertion.expiresAt),
          expiry > runtime.now() else {
      throw ShareNetworkAppAgentCoordinatorError.expiredReadiness
    }
  }

  private func waitUntilRenewal(
    assertion: AppleAppAgentReadinessAssertion,
    tunnel: any PacketTunnelControlling,
    generation: UInt64
  ) async throws {
    guard let expiry = Self.date(from: assertion.expiresAt)
    else {
      throw ShareNetworkAppAgentCoordinatorError.expiredReadiness
    }
    let renewalDate = expiry.addingTimeInterval(-Self.renewalLeadTime)
    while runtime.now() < renewalDate {
      try Task.checkCancellation()
      guard generation == runGeneration else { throw CancellationError() }
      guard runtime.isConnected() else {
        throw ShareNetworkAppAgentCoordinatorError.channelDisconnected
      }
      guard await tunnel.status == .connected else {
        throw ShareNetworkAppAgentCoordinatorError.tunnelDisconnected
      }
      let profile = try runtime.loadProfile()
      guard profile.hubNetworkID == assertion.hubNetworkId,
            profile.profileKey == runtime.key() else {
        throw ShareNetworkAppAgentCoordinatorError.profileReplaced
      }
      try await runtime.sleep(Self.healthPollInterval)
    }
  }

  private func unbindCurrent() async {
    guard runtime.isConnected(),
          runtime.supports("hub/net/apple-agent/unbind"),
          let assertion = currentAssertion else { return }
    let request = AppleAppAgentUnbindRequest(
      version: hubNetworkModelVersion,
      hubNetworkId: assertion.hubNetworkId,
      tunnelInstanceId: assertion.tunnelInstanceId,
      generation: assertion.generation
    )
    try? await runtime.unbind(request)
  }

  private static func boundedMessage(_ error: Error) -> String {
    String(String(describing: error).prefix(240))
  }

  private static func date(from string: String) -> Date? {
    ISO8601DateFormatter.js.date(from: string)
  }
}

enum ShareNetworkAppAgentCoordinatorError: Error, Equatable {
  case channelDisconnected
  case tunnelDisconnected
  case incompatibleHub
  case incompatibleExtension
  case bindingRejected
  case profileReplaced
  case expiredReadiness
  case invalidBootstrapCommand
}
