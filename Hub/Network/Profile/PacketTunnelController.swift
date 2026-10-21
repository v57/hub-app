import Foundation
@preconcurrency import NetworkExtension

@MainActor
final class PacketTunnelController: PacketTunnelControlling {
  static let providerBundleIdentifier = "dev.v57.Hub.PacketTunnelExtension"
  static let localizedDescription = "Hub Network"

  private let store: HubNetworkProfileStore
  private var manager: NETunnelProviderManager?

  init(store: HubNetworkProfileStore) {
    self.store = store
  }

  convenience init() throws {
    try self.init(store: HubNetworkProfileStore())
  }

  var status: PacketTunnelStatus {
    get async {
      do {
        guard let manager = try await loadManager() else {
          return .notInstalled
        }
        return Self.status(for: manager.connection.status)
      } catch {
        return .invalid
      }
    }
  }

  func install(configuration: HubNetworkProfileConfiguration) async throws {
    try configuration.validate()
    try store.save(configuration)

    do {
      let manager = try await loadManager() ?? NETunnelProviderManager()
      let tunnelProtocol = NETunnelProviderProtocol()
      tunnelProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
      tunnelProtocol.serverAddress = configuration.hubURL.host ?? configuration.hubURL.absoluteString
      tunnelProtocol.providerConfiguration = [
        "profileVersion": configuration.version,
        "profileFile": HubNetworkAppGroup.profileFile,
      ]

      manager.localizedDescription = Self.localizedDescription
      manager.protocolConfiguration = tunnelProtocol
      manager.isEnabled = true
      try await save(manager)
      try await load(manager)
      self.manager = manager
    } catch {
      try? store.remove()
      throw error
    }
  }

  /// Stages validated membership data for an in-place native-join commit.
  /// Provider reads this shared file before replacing temporary bootstrap peer.
  func stageNativeJoinMembership(
    configuration: HubNetworkProfileConfiguration
  ) throws {
    try configuration.validate()
    try store.save(configuration)
  }

  func start() async throws {
    print("PacketTunnelController.start")
    guard let manager = try await loadManager() else {
      throw PacketTunnelControllerError.notInstalled
    }
    guard manager.isEnabled else {
      throw PacketTunnelControllerError.disabled
    }
    try manager.connection.startVPNTunnel()
    try await waitForConnection(manager, expected: .connected)
  }

  func replaceAndStart(
    configuration: HubNetworkProfileConfiguration
  ) async throws {
    if let manager = try await loadManager(),
       manager.connection.status != .disconnected {
      manager.connection.stopVPNTunnel()
      try await waitForConnection(manager, expected: .disconnected)
    }
    try await install(configuration: configuration)
    try await start()
  }

  /// Stops the tunnel and waits until it is down (at most 15 seconds), so a join or start right after doesn't find
  /// it still disconnecting
  func stop() async {
    guard let manager = try? await loadManager() else { return }
    guard manager.connection.status != .disconnected, manager.connection.status != .invalid else { return }
    manager.connection.stopVPNTunnel()
    try? await waitForConnection(manager, expected: .disconnected)
  }

  /// Waits for a tunnel that is going down to finish, at most 15 seconds
  func waitUntilDisconnected() async {
    guard let manager = try? await loadManager(), manager.connection.status == .disconnecting else { return }
    try? await waitForConnection(manager, expected: .disconnected)
  }

  /// Stops the tunnel, disables the system VPN profile and deletes the shared
  /// membership file.
  ///
  /// The profile itself stays installed: creating a new one shows the system
  /// "Add VPN Configurations" consent prompt, while reusing an existing one
  /// does not. `install(configuration:)` re-enables it.
  func remove() async throws {
    if let manager = try await loadManager() {
      manager.connection.stopVPNTunnel()
      if manager.isEnabled {
        manager.isEnabled = false
        try await save(manager)
      }
    }
    try store.remove()
  }

  /// Deletes the system VPN profile. The next install asks for consent again.
  ///
  /// Only needed when the installed profile belongs to a differently signed
  /// build (macOS rejects it with a tunnel activation failure).
  func deleteSystemProfile() async throws {
    if let manager = try await loadManager() {
      manager.connection.stopVPNTunnel()
      try await remove(manager)
    }
    self.manager = nil
    try store.remove()
  }

  /// Updates explicit gateway-serving intent in shared extension state.
  ///
  /// Caller must remove Hub advertisement before disabling and advertise only
  /// after this method succeeds.
  func setGatewayServing(_ enabled: Bool) async throws {
    let current = try store.load()
    let updated = current.withGatewayServing(enabled)
    try store.save(updated)

    guard let manager = try await loadManager() else {
      if enabled {
        try? store.save(current)
        throw PacketTunnelControllerError.notInstalled
      }
      return
    }
    guard manager.connection.status == .connected else {
      if enabled {
        try? store.save(current)
        throw PacketTunnelControllerError.notConnected
      }
      return
    }

    do {
      try await restart(manager)
      let status = try await providerGatewayStatus(manager)
      guard status == (enabled ? .available : .disabled) else {
        throw PacketTunnelControllerError.gatewayRuntimeUnavailable
      }
    } catch {
      try? store.save(current)
      try? await restart(manager)
      throw error
    }
  }

  func gatewayServingStatus() async -> GatewayServingState {
    let enabled = (try? store.load().servesGateway) == true
    return Self.gatewayServingStatus(enabled: enabled, tunnelStatus: await status)
  }

  func installedConfiguration() throws -> HubNetworkProfileConfiguration {
    try store.load()
  }

  func installedConfigurationForMigration() throws
    -> HubNetworkProfileConfiguration {
    try store.loadWithoutValidation()
  }

  func bootstrapReadiness() async throws -> AppleAppAgentReadinessAssertion {
    let response = try await sendBootstrapMessage(
      PacketTunnelBootstrapMessage(command: .readiness)
    )
    guard let readiness = response.readiness,
          readiness.tunnelInstanceId == response.tunnelInstanceId,
          readiness.generation == response.generation else {
      throw PacketTunnelControllerError.bootstrapResponseMismatch
    }
    return readiness
  }

  func bootstrapHealth(
    identity: PacketTunnelBootstrapIdentity
  ) async throws -> PacketTunnelBootstrapHealth {
    let response = try await sendBootstrapMessage(
      PacketTunnelBootstrapMessage(
        command: .health,
        tunnelInstanceId: identity.tunnelInstanceId,
        generation: identity.generation
      ),
      expected: identity
    )
    guard let health = response.health else {
      throw PacketTunnelControllerError.bootstrapRuntimeUnavailable
    }
    return health
  }

  /// Live online-inviter registration state from the extension. The owner
  /// waits for `registered == true` before issuing an invitation so the node
  /// accepts the joiner's `session.open`.
  func inviterStatus() async throws -> PacketTunnelInviterStatus {
    guard let manager = try await loadManager(),
          manager.connection.status == .connected,
          let session = manager.connection as? NETunnelProviderSession else {
      throw PacketTunnelControllerError.notConnected
    }
    let request = try JSONEncoder().encode(GatewayProviderMessage(command: "inviterStatus"))
    let response = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      do {
        try session.sendProviderMessage(request) { data in
          guard let data else {
            continuation.resume(
              throwing: PacketTunnelControllerError.bootstrapRuntimeUnavailable
            )
            return
          }
          continuation.resume(returning: data)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    return try JSONDecoder().decode(PacketTunnelInviterStatus.self, from: response)
  }

  /// Gives the extension every network member's WireGuard key and overlay
  /// addresses. The hub host keeps one peer per member: members reach hub-pro
  /// and shared ports only through it, after their bootstrap peer expires.
  func setMemberPeers(_ peers: [HubNetworkPeer]) async throws {
    guard let manager = try await loadManager(),
          manager.connection.status == .connected,
          let session = manager.connection as? NETunnelProviderSession else {
      throw PacketTunnelControllerError.notConnected
    }
    struct Request: Codable {
      let command: String
      let peers: [HubNetworkPeer]
    }
    struct Response: Codable {
      let ok: Bool
    }
    let request = try JSONEncoder().encode(Request(command: "memberPeers", peers: peers))
    let response = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      do {
        try session.sendProviderMessage(request) { data in
          guard let data else {
            continuation.resume(
              throwing: PacketTunnelControllerError.bootstrapRuntimeUnavailable
            )
            return
          }
          continuation.resume(returning: data)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    _ = try JSONDecoder().decode(Response.self, from: response)
  }

  func startNativeJoin(_ start: PacketTunnelNativeJoinStart) async throws
    -> PacketTunnelNativeJoinStatus {
    try await sendNativeJoinMessage(.init(
      command: .start, tunnelInstanceId: start.tunnelInstanceId,
      generation: start.generation, transactionId: start.transactionId,
      start: start
    ))
  }

  func nativeJoinStatus(
    transactionId: String,
    identity: PacketTunnelBootstrapIdentity
  ) async throws -> PacketTunnelNativeJoinStatus {
    try await sendNativeJoinMessage(.init(
      command: .status, tunnelInstanceId: identity.tunnelInstanceId,
      generation: identity.generation, transactionId: transactionId
    ))
  }

  func cancelNativeJoin(_ cancel: PacketTunnelNativeJoinCancel) async throws
    -> PacketTunnelNativeJoinStatus {
    try await sendNativeJoinMessage(.init(
      command: .cancel, tunnelInstanceId: cancel.tunnelInstanceId,
      generation: cancel.generation, transactionId: cancel.transactionId,
      cancel: cancel
    ))
  }

  func commitNativeJoin(_ commit: PacketTunnelNativeJoinCommit) async throws
    -> PacketTunnelNativeJoinStatus {
    try await sendNativeJoinMessage(.init(
      command: .commit, tunnelInstanceId: commit.tunnelInstanceId,
      generation: commit.generation, transactionId: commit.transactionId,
      commit: commit
    ))
  }

  static func gatewayServingStatus(
    enabled: Bool,
    tunnelStatus: PacketTunnelStatus
  ) -> GatewayServingState {
    guard enabled else { return .disabled }
    switch tunnelStatus {
    case .connected:
      return .available
    case .connecting, .reasserting:
      return .enabling
    case .disconnecting:
      return .disabling
    case .notInstalled, .disconnected, .invalid:
      return .unavailable
    }
  }

  private func loadManager() async throws -> NETunnelProviderManager? {
    if let manager { return manager }
    let result = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<
        UnsafeSendable<[NETunnelProviderManager]>,
        Error
      >) in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(
            returning: UnsafeSendable(value: managers ?? [])
          )
        }
      }
    }
    let managers = result.value
    let manager = managers.first {
      ($0.protocolConfiguration as? NETunnelProviderProtocol)?
        .providerBundleIdentifier == Self.providerBundleIdentifier
    }
    self.manager = manager
    return manager
  }

  private func save(_ manager: NETunnelProviderManager) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      manager.saveToPreferences { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func load(_ manager: NETunnelProviderManager) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      manager.loadFromPreferences { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func remove(_ manager: NETunnelProviderManager) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      manager.removeFromPreferences { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func waitForConnection(
    _ manager: NETunnelProviderManager,
    expected: NEVPNStatus
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    var observedTransition = false
    while ContinuousClock.now < deadline {
      let status = manager.connection.status
      if status == expected { return }
      if status == .connecting || status == .reasserting
        || status == .disconnecting {
        observedTransition = true
      }
      if status == .invalid
        || (expected == .connected && observedTransition && status == .disconnected) {
        throw PacketTunnelControllerError.tunnelActivationFailed
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw PacketTunnelControllerError.tunnelActivationTimedOut
  }

  private func restart(_ manager: NETunnelProviderManager) async throws {
    manager.connection.stopVPNTunnel()
    try await waitForConnection(manager, expected: .disconnected)
    try manager.connection.startVPNTunnel()
    try await waitForConnection(manager, expected: .connected)
  }

  private func providerGatewayStatus(
    _ manager: NETunnelProviderManager
  ) async throws -> GatewayServingState {
    guard let session = manager.connection as? NETunnelProviderSession else {
      throw PacketTunnelControllerError.gatewayRuntimeUnavailable
    }
    let request = try JSONEncoder().encode(
      GatewayProviderMessage(command: "gatewayStatus")
    )
    let response = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      do {
        try session.sendProviderMessage(request) { data in
          guard let data else {
            continuation.resume(
              throwing: PacketTunnelControllerError.gatewayRuntimeUnavailable
            )
            return
          }
          continuation.resume(returning: data)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    return try JSONDecoder().decode(GatewayProviderStatus.self, from: response).state
  }

  private func sendBootstrapMessage(
    _ message: PacketTunnelBootstrapMessage,
    expected: PacketTunnelBootstrapIdentity? = nil
  ) async throws -> PacketTunnelBootstrapResponse {
    guard let manager = try await loadManager(),
          manager.connection.status == .connected,
          let session = manager.connection as? NETunnelProviderSession else {
      throw PacketTunnelControllerError.notConnected
    }
    let responseData = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      do {
        try session.sendProviderMessage(try JSONEncoder().encode(message)) { data in
          guard let data else {
            continuation.resume(
              throwing: PacketTunnelControllerError.bootstrapRuntimeUnavailable
            )
            return
          }
          continuation.resume(returning: data)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    let response = try JSONDecoder().decode(
      PacketTunnelBootstrapResponse.self,
      from: responseData
    )
    guard response.version == PacketTunnelBootstrapMessage.version,
          response.command == message.command else {
      throw PacketTunnelControllerError.bootstrapResponseMismatch
    }
    if let expected {
      guard response.tunnelInstanceId == expected.tunnelInstanceId,
            response.generation == expected.generation else {
        throw PacketTunnelControllerError.bootstrapResponseMismatch
      }
    }
    return response
  }

  private func sendNativeJoinMessage(
    _ message: PacketTunnelNativeJoinMessage
  ) async throws -> PacketTunnelNativeJoinStatus {
    guard let manager = try await loadManager(),
          manager.connection.status == .connected,
          let session = manager.connection as? NETunnelProviderSession else {
      throw PacketTunnelControllerError.notConnected
    }
    let data = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      do {
        try session.sendProviderMessage(try JSONEncoder().encode(message)) { data in
          guard let data else {
            continuation.resume(
              throwing: PacketTunnelControllerError.bootstrapRuntimeUnavailable
            )
            return
          }
          continuation.resume(returning: data)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    let response: PacketTunnelNativeJoinResponse
    do {
      response = try JSONDecoder().decode(PacketTunnelNativeJoinResponse.self, from: data)
    } catch {
      print("[HN9XX] native-join response decode failed: \(error)")
      print("[HN9XX] raw response: \(data.base64EncodedString())")
      throw error
    }
    guard response.version == PacketTunnelNativeJoinMessage.version,
          response.command == message.command,
          response.transactionId == message.transactionId,
          response.tunnelInstanceId == message.tunnelInstanceId,
          response.generation == message.generation,
          response.status.transactionId == message.transactionId,
          response.status.tunnelInstanceId == message.tunnelInstanceId,
          response.status.generation == message.generation else {
      throw PacketTunnelControllerError.bootstrapResponseMismatch
    }
    return response.status
  }

#if DEBUG
  /// Pulls the extension's in-memory diagnostics buffer (acceptance use).
  /// Returns nil when the tunnel is not connected.
  func extensionDiagnostics() async -> String? {
    guard let manager = try? await loadManager(),
          let session = manager.connection as? NETunnelProviderSession else {
      return nil
    }
    // A freshly loaded manager's connection starts `.connecting`; give it a
    // moment to attach to the live tunnel before giving up.
    for _ in 0..<20 {
      if manager.connection.status == .connected { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard manager.connection.status == .connected else { return nil }
    return await withCheckedContinuation { continuation in
      do {
        try session.sendProviderMessage(Data("hn9xx-diag".utf8)) { data in
          continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
        }
      } catch {
        continuation.resume(returning: nil)
      }
    }
  }

  /// Signed-host acceptance probe for shared Keychain access.
  ///
  /// Response contains only public key and signature. No private key bytes
  /// cross the provider-message boundary.
  func keychainProof() async throws -> KeychainProof {
    guard let manager = try await loadManager(),
          manager.connection.status == .connected,
          let session = manager.connection as? NETunnelProviderSession else {
      throw PacketTunnelControllerError.notConnected
    }
    let response = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      do {
        try session.sendProviderMessage(
          try JSONEncoder().encode(GatewayProviderMessage(command: "keychainProof"))
        ) { data in
          guard let data else {
            continuation.resume(
              throwing: PacketTunnelControllerError.gatewayRuntimeUnavailable
            )
            return
          }
          continuation.resume(returning: data)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
    return try JSONDecoder().decode(KeychainProof.self, from: response)
  }
#endif

  static func status(for status: NEVPNStatus) -> PacketTunnelStatus {
    switch status {
    case .invalid: .invalid
    case .disconnected: .disconnected
    case .connecting: .connecting
    case .connected: .connected
    case .reasserting: .reasserting
    case .disconnecting: .disconnecting
    @unknown default: .invalid
    }
  }
}

enum PacketTunnelControllerError: Error, Equatable {
  case notInstalled
  case disabled
  case notConnected
  case gatewayRuntimeUnavailable
  case bootstrapRuntimeUnavailable
  case bootstrapResponseMismatch
  case tunnelActivationFailed
  case tunnelActivationTimedOut
}

extension PacketTunnelControllerError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .notInstalled:
      "Hub Network profile is not installed."
    case .disabled:
      "Hub Network profile is disabled."
    case .notConnected:
      "Connect to Hub Network before changing Internet Gateway."
    case .gatewayRuntimeUnavailable:
      "Internet Gateway could not start in the network extension."
    case .bootstrapRuntimeUnavailable:
      "Hub Network extension is unavailable."
    case .bootstrapResponseMismatch:
      "Hub Network extension returned an invalid response."
    case .tunnelActivationFailed:
      "Hub Network connection failed."
    case .tunnelActivationTimedOut:
      "Hub Network connection timed out."
    }
  }
}

private struct GatewayProviderMessage: Codable, Sendable {
  let command: String
}

private struct GatewayProviderStatus: Codable, Sendable {
  let state: GatewayServingState
}

#if DEBUG
struct KeychainProof: Codable, Sendable {
  static let message = Data("hub-network/readiness-keychain-proof/v1".utf8)
  let publicKey: String
  let signature: String
}
#endif

private struct UnsafeSendable<Value>: @unchecked Sendable {
  let value: Value
}
