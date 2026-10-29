import Foundation

/// Main-app boundary for the separately built packet-tunnel extension.
///
/// The concrete implementation may use `NETunnelProviderManager`, but the rest
/// of Hub only depends on this contract and shared Codable configuration.
@MainActor
protocol PacketTunnelControlling {
  var status: PacketTunnelStatus { get async }

  func install(configuration: HubNetworkProfileConfiguration) async throws
  func start() async throws
  func stop() async
  func remove() async throws
  func setGatewayServing(_ enabled: Bool) async throws
  func gatewayServingStatus() async -> GatewayServingState
  func bootstrapReadiness() async throws -> AppleAppAgentReadinessAssertion
  func bootstrapHealth(
    identity: PacketTunnelBootstrapIdentity
  ) async throws -> PacketTunnelBootstrapHealth
  func startNativeJoin(_ start: PacketTunnelNativeJoinStart) async throws
    -> PacketTunnelNativeJoinStatus
  func nativeJoinStatus(
    transactionId: String,
    identity: PacketTunnelBootstrapIdentity
  ) async throws -> PacketTunnelNativeJoinStatus
  func cancelNativeJoin(_ cancel: PacketTunnelNativeJoinCancel) async throws
    -> PacketTunnelNativeJoinStatus
  func commitNativeJoin(_ commit: PacketTunnelNativeJoinCommit) async throws
    -> PacketTunnelNativeJoinStatus
}

extension PacketTunnelControlling {
  func startNativeJoin(_ start: PacketTunnelNativeJoinStart) async throws
    -> PacketTunnelNativeJoinStatus {
    throw PacketTunnelControllerError.bootstrapRuntimeUnavailable
  }

  func nativeJoinStatus(
    transactionId: String,
    identity: PacketTunnelBootstrapIdentity
  ) async throws -> PacketTunnelNativeJoinStatus {
    throw PacketTunnelControllerError.bootstrapRuntimeUnavailable
  }

  func cancelNativeJoin(_ cancel: PacketTunnelNativeJoinCancel) async throws
    -> PacketTunnelNativeJoinStatus {
    throw PacketTunnelControllerError.bootstrapRuntimeUnavailable
  }

  func commitNativeJoin(_ commit: PacketTunnelNativeJoinCommit) async throws
    -> PacketTunnelNativeJoinStatus {
    throw PacketTunnelControllerError.bootstrapRuntimeUnavailable
  }
}

enum GatewayServingState: String, Codable, Sendable {
  case disabled
  case enabling
  case available
  case disabling
  case unavailable
}

enum PacketTunnelStatus: String, Codable, Sendable {
  case notInstalled
  case disconnected
  case connecting
  case connected
  case disconnecting
  case reasserting
  case invalid
}

enum ShareNetworkState: String, Codable, Sendable {
  case inactive
  case installing
  case activating
  case active
  case deactivating
  case unavailable

  static func status(_ tunnelStatus: PacketTunnelStatus) -> Self {
    switch tunnelStatus {
    case .notInstalled, .disconnected:
      .inactive
    case .connecting, .reasserting:
      .activating
    case .connected:
      .active
    case .disconnecting:
      .deactivating
    case .invalid:
      .unavailable
    }
  }
}
