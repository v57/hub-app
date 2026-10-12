import Foundation

let hubNetworkModelVersion = 1

enum HubNetworkProtocol: String, Codable, Sendable {
  case tcp
  case udp
}

enum HubNetworkPolicyMode: String, Codable, Sendable {
  case hub
  case group
  case keys
  case `private`
  case disabled
}

struct HubNetworkPolicy: Codable, Hashable, Sendable {
  let mode: HubNetworkPolicyMode
  let group: String?
  let keys: [String]?
}

struct HubNetworkResource: Codable, Hashable, Identifiable, Sendable {
  var id: String { resourceId }

  let version: Int
  let resourceId: String
  let ownerKey: String
  let shareName: String
  let authority: String
  let policy: HubNetworkPolicy
  let generation: Int
}

struct HubNetworkProvider: Codable, Hashable, Identifiable, Sendable {
  var id: String { providerId }

  let version: Int
  let providerId: String
  let resourceId: String
  let serviceKey: String
  let key: String
  let `protocol`: HubNetworkProtocol
  let overlayAddress: String
  let port: UInt16
  let connectedAt: String
}

struct HubNetworkAgent: Codable, Hashable, Identifiable, Sendable {
  var id: String { key }

  let version: Int
  let key: String
  let wireGuardKey: String
  let name: String?
  let platform: String?
  let overlayAddresses: [String]
  let connectedAt: String
  /// False for a known member that is not connected (member lists only).
  let online: Bool?
}

enum HubNetworkLocalAgentBindingKind: String, Codable, Sendable {
  case machine
  case appleApp = "apple-app"
  case join
}

enum AppleAppAgentCapability: String, Codable, Sendable {
  case invitationBootstrap = "invitation-bootstrap-v1"
}

struct AppleAppAgentReadinessAssertion: Codable, Hashable, Sendable {
  let version: Int
  let signatureDomain: String
  let hubNetworkId: String
  let wireGuardKey: String
  let tunnelInstanceId: String
  let capabilities: [AppleAppAgentCapability]
  let generation: UInt64
  let issuedAt: String
  let expiresAt: String
  let signature: String
}

struct AppleAppAgentBindRequest: Codable, Hashable, Sendable {
  let version: Int
  let assertion: AppleAppAgentReadinessAssertion
}

struct AppleAppAgentRenewRequest: Codable, Hashable, Sendable {
  let version: Int
  let assertion: AppleAppAgentReadinessAssertion
}

struct AppleAppAgentUnbindRequest: Codable, Hashable, Sendable {
  let version: Int
  let hubNetworkId: String
  let tunnelInstanceId: String
  let generation: UInt64
}

enum HubNetworkConnectionPhase: String, Codable, Sendable {
  case idle
  case discovering
  case connecting
  case connected
  case failed
}

enum HubNetworkErrorCode: String, Codable, Sendable {
  case unsupportedVersion = "unsupported_version"
  case invalidRequest = "invalid_request"
  case unauthorized
  case forbidden
  case agentUnavailable = "agent_unavailable"
  case localAgentUnavailable = "local_agent_unavailable"
  case invalidAttestation = "invalid_attestation"
  case resourceIdCollision = "resource_id_collision"
  case resourceUnavailable = "resource_unavailable"
  case providerUnavailable = "provider_unavailable"
  case grantExpired = "grant_expired"
  case grantRevoked = "grant_revoked"
  case ticketExpired = "ticket_expired"
  case replayDetected = "replay_detected"
  case directConnectFailed = "direct_connect_failed"
  case rateLimited = "rate_limited"
  case nativeJoinBootstrapFailed = "native_join_bootstrap_failed"
  case nativeJoinCommitFailed = "native_join_commit_failed"
  case nativeJoinExpired = "native_join_expired"
  case `internal`
}

enum HubNetworkErrorDetail: Codable, Hashable, Sendable {
  case string(String)
  case number(Double)
  case boolean(Bool)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .boolean(let value): try container.encode(value)
    }
  }
}

struct HubNetworkError: Codable, Hashable, Sendable {
  let version: Int
  let code: HubNetworkErrorCode
  let message: String
  let retryable: Bool
  let details: [String: HubNetworkErrorDetail]?
}

struct HubNetworkConnectionStatus: Codable, Hashable, Identifiable, Sendable {
  var id: String { resourceId }

  let version: Int
  let resourceId: String
  let providerId: String?
  let phase: HubNetworkConnectionPhase
  let direct: Bool
  let updatedAt: String
  let error: HubNetworkError?
}

typealias HubNetworkDiagnostic = HubNetworkConnectionStatus

struct HubNetworkAgentStatus: Codable, Hashable, Identifiable, Sendable {
  var id: String { key }

  let version: Int
  let key: String
  let available: Bool
  let addresses: [String]
  let peers: Int
  let shares: Int
  let updatedAt: String
  let error: HubNetworkError?
}

enum HubNetworkLocalAgentState: String, Codable, Sendable {
  case unbound
  case available
  case unavailable
}

struct HubNetworkLocalAgentStatus: Codable, Hashable, Sendable {
  let version: Int
  let state: HubNetworkLocalAgentState
  let bindingKind: HubNetworkLocalAgentBindingKind?
  let key: String?
  let tunnelInstanceId: String?
  let generation: UInt64?
  let expiresAt: String?
  let capabilities: [String]
  let connected: Bool
  let bootstrapCapable: Bool
  let updatedAt: String
  let error: HubNetworkError?

  static let unavailable = Self(
    version: hubNetworkModelVersion,
    state: .unavailable,
    bindingKind: nil,
    key: nil,
    
    tunnelInstanceId: nil,
    generation: nil,
    expiresAt: nil,
    capabilities: [],
    connected: false,
    bootstrapCapable: false,
    updatedAt: "",
    error: nil
  )

  var canIssueInvitation: Bool {
    state == .available && connected && bootstrapCapable
  }

  var readinessLabel: String {
    guard canIssueInvitation else {
      if state == .unbound { return "Not bound" }
      if !connected { return "Unavailable" }
      return "Bootstrap unavailable"
    }
    return bindingKind == .appleApp
      ? "Available (This Mac)"
      : "Available (Local Agent)"
  }

  var readinessHelp: String? {
    guard !canIssueInvitation else { return nil }
    if let message = error?.message, !message.isEmpty {
      return String(message.prefix(240))
    }
    if state == .unbound {
      return "Turn on Join Network on this Mac, or start a bound hub-net agent."
    }
    if !connected {
      return "Reconnect this Hub and keep Join Network running."
    }
    return "Update or restart the local agent so invitation bootstrap is supported."
  }
}

struct HubNetworkInvitationResponse: Decodable, Sendable {
  let url: String
  let expiresAt: String
}

struct HubNetworkInvitationRequest: Encodable, Sendable {
  let hubProHost: String?
}

struct HubNetworkPolicyUpdate: Encodable, Sendable {
  let resourceId: String
  let policy: HubNetworkPolicy
}

struct HubNetworkResourceRevoke: Encodable, Sendable {
  let resourceId: String
}

extension HubNetworkPolicy {
  static func hub() -> Self {
    Self(mode: .hub, group: nil, keys: nil)
  }

  static func group(_ group: String) -> Self {
    Self(mode: .group, group: group, keys: nil)
  }

  static func keys(_ keys: [String]) -> Self {
    Self(mode: .keys, group: nil, keys: keys)
  }

  static func privateAccess() -> Self {
    Self(mode: .private, group: nil, keys: nil)
  }

  static func disabled() -> Self {
    Self(mode: .disabled, group: nil, keys: nil)
  }
}
