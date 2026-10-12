import Foundation

enum PacketTunnelNativeJoinCommand: String, Codable, Sendable {
  case start = "native-join-start"
  case status = "native-join-status"
  case cancel = "native-join-cancel"
  case commit = "native-join-commit"
}

enum PacketTunnelNativeJoinState: String, Codable, Sendable {
  case accepted
  case rendezvous
  case peerInstalled = "peer-installed"
  case readyToEnroll = "ready-to-enroll"
  case committing
  case committed
  case failed
  case cancelled
}

struct PacketTunnelNativeJoinStart: Codable, Hashable, Sendable {
  let version: Int
  let invitationCode: String
  let replayId: String
  let transactionId: String
  let invitingKey: String
  let node: String
  let key: String
  let wireGuardKey: String
  let tunnelInstanceId: String
  let generation: UInt64
  let expiresAt: String
}

struct PacketTunnelNativeJoinCommit: Codable, Hashable, Sendable {
  let version: Int
  let transactionId: String
  let tunnelInstanceId: String
  let generation: UInt64
  let key: String
  let wireGuardKey: String
  let hubNetworkId: String
  let overlayAddresses: [String]
  let expiresAt: String
}

struct PacketTunnelNativeJoinCancel: Codable, Hashable, Sendable {
  let version: Int
  let transactionId: String
  let tunnelInstanceId: String
  let generation: UInt64
  let reason: String
}

struct PacketTunnelNativeJoinMessage: Codable, Hashable, Sendable {
  static let version = 1

  let version: Int
  let command: PacketTunnelNativeJoinCommand
  let tunnelInstanceId: String
  let generation: UInt64
  let transactionId: String
  let start: PacketTunnelNativeJoinStart?
  let commit: PacketTunnelNativeJoinCommit?
  let cancel: PacketTunnelNativeJoinCancel?

  init(
    command: PacketTunnelNativeJoinCommand,
    tunnelInstanceId: String,
    generation: UInt64,
    transactionId: String,
    start: PacketTunnelNativeJoinStart? = nil,
    commit: PacketTunnelNativeJoinCommit? = nil,
    cancel: PacketTunnelNativeJoinCancel? = nil
  ) {
    version = Self.version
    self.command = command
    self.tunnelInstanceId = tunnelInstanceId
    self.generation = generation
    self.transactionId = transactionId
    self.start = start
    self.commit = commit
    self.cancel = cancel
  }
}

struct PacketTunnelNativeJoinStatus: Codable, Hashable, Sendable {
  let version: Int
  let replayId: String
  let transactionId: String
  let tunnelInstanceId: String
  let generation: UInt64
  let key: String
  let wireGuardKey: String
  let expiresAt: String
  let hubProHost: String?
  let bootstrapAddresses: [String]?
  let state: PacketTunnelNativeJoinState
  let updatedAt: String
  let error: HubNetworkError?
}

struct PacketTunnelNativeJoinResponse: Codable, Hashable, Sendable {
  let version: Int
  let command: PacketTunnelNativeJoinCommand
  let tunnelInstanceId: String
  let generation: UInt64
  let transactionId: String
  let status: PacketTunnelNativeJoinStatus
}

/// Online-inviter registration state reported by the extension.
struct PacketTunnelInviterStatus: Codable, Hashable, Sendable {
  let registered: Bool
  let serviceKey: String
  let listenerEndpoint: String
}
