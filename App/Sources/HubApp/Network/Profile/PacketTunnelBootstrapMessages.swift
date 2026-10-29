import Foundation

enum PacketTunnelBootstrapCommand: String, Codable, Sendable {
  case readiness
  case health
}

struct PacketTunnelBootstrapMessage: Codable, Hashable, Sendable {
  static let version = 1

  let version: Int
  let command: PacketTunnelBootstrapCommand
  let tunnelInstanceId: String?
  let generation: UInt64?

  init(
    command: PacketTunnelBootstrapCommand,
    tunnelInstanceId: String? = nil,
    generation: UInt64? = nil
  ) {
    self.version = Self.version
    self.command = command
    self.tunnelInstanceId = tunnelInstanceId
    self.generation = generation
  }
}

enum PacketTunnelBootstrapHealthState: String, Codable, Sendable {
  case ready
  case busy
  case unavailable
}

struct PacketTunnelBootstrapHealth: Codable, Hashable, Sendable {
  let state: PacketTunnelBootstrapHealthState
  let activeAssignmentIds: [String]
  let checkedAt: String
  let error: HubNetworkError?
  let hubNetworkId: String?
  let key: String?
  let wireGuardKey: String?
  let tunnelInstanceId: String?
  let capabilities: [AppleAppAgentCapability]?
  let expiresAt: String?

  init(
    state: PacketTunnelBootstrapHealthState,
    activeAssignmentIds: [String],
    checkedAt: String,
    error: HubNetworkError? = nil,
    hubNetworkId: String? = nil,
    key: String? = nil,
    wireGuardKey: String? = nil,
    tunnelInstanceId: String? = nil,
    capabilities: [AppleAppAgentCapability]? = nil,
    expiresAt: String? = nil
  ) {
    self.state = state
    self.activeAssignmentIds = activeAssignmentIds
    self.checkedAt = checkedAt
    self.error = error
    self.hubNetworkId = hubNetworkId
    self.key = key
    self.wireGuardKey = wireGuardKey
    self.tunnelInstanceId = tunnelInstanceId
    self.capabilities = capabilities
    self.expiresAt = expiresAt
  }
}

struct PacketTunnelBootstrapResponse: Codable, Hashable, Sendable {
  let version: Int
  let command: PacketTunnelBootstrapCommand
  let tunnelInstanceId: String
  let generation: UInt64
  let readiness: AppleAppAgentReadinessAssertion?
  let health: PacketTunnelBootstrapHealth?
}

struct PacketTunnelBootstrapIdentity: Codable, Hashable, Sendable {
  let tunnelInstanceId: String
  let generation: UInt64
}
