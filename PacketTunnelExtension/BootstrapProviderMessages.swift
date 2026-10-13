import Foundation
import HubService
import Channel

private let extensionReadinessDomain = "hub-network/apple-app-agent-readiness/v1"

struct ExtensionReadinessAssertion: Encodable {
  let version: Int
  let signatureDomain: String
  let hubNetworkId: String
  let wireGuardKey: String
  let tunnelInstanceId: String
  let capabilities: [String]
  let generation: UInt64
  let issuedAt: String
  let expiresAt: String
  let signature: String

  static func signed(
    profile: Profile,
    tunnelInstanceId: String,
    generation: UInt64,
    now: Date = Date()
  ) throws -> Self {
    guard let wireGuardKey = profile.wireGuardPublicKey else {
      throw ExtensionReadinessError.incompleteProfile
    }
    let unsigned = ExtensionReadinessAssertion(
      version: 1, signatureDomain: extensionReadinessDomain,
      hubNetworkId: profile.hubNetworkID,
       wireGuardKey: wireGuardKey,
      tunnelInstanceId: tunnelInstanceId,
      capabilities: ["invitation-bootstrap-v1"], generation: generation,
      issuedAt: ISO8601DateFormatter.js.string(from: now),
      expiresAt: ISO8601DateFormatter.js.string(from: now.addingTimeInterval(30)), signature: ""
    )
    let input = try HubNetworkSignedEnvelope.signatureInput(for: unsigned, domain: extensionReadinessDomain)
    let identity = try KeyChain.hubIdentity()
    let signature = identity.sign(data: input)
    // profile.profilePublicKey is canonical SPKI on the owner path (hub.key)
    // and raw base64 on the joiner path (the staged key's rawRepresentation);
    // normalize before comparing with the identity's SPKI public key.
    let profileKey = KeyChain.spkiPublicKey(rawBase64: profile.profilePublicKey)
      ?? profile.profilePublicKey
    guard identity.publicKey() == profileKey else {
      throw ExtensionReadinessError.keyMismatch
    }
    return ExtensionReadinessAssertion(
      version: unsigned.version, signatureDomain: unsigned.signatureDomain,
      hubNetworkId: unsigned.hubNetworkId,
       wireGuardKey: unsigned.wireGuardKey,
      tunnelInstanceId: unsigned.tunnelInstanceId,
      capabilities: unsigned.capabilities, generation: unsigned.generation,
      issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt,
      signature: signature
    )
  }
}

enum ExtensionReadinessError: Error {
  case incompleteProfile
  case keyMismatch
}

enum ExtensionBootstrapCommand: String, Codable {
  case readiness
  case health
}

struct ExtensionBootstrapMessage: Decodable {
  let version: Int
  let command: ExtensionBootstrapCommand
  let tunnelInstanceId: String?
  let generation: UInt64?
}

enum ExtensionBootstrapHealthState: String, Encodable {
  case ready
  case busy
  case unavailable
}

struct ExtensionBootstrapHealth: Encodable {
  let state: ExtensionBootstrapHealthState
  let activeAssignmentIds: [String]
  let checkedAt: String
  let hubNetworkId: String
  let key: String
  let wireGuardKey: String
  let tunnelInstanceId: String
  let capabilities: [String]
  let expiresAt: String
}

struct ExtensionBootstrapResponse: Encodable {
  let version: Int
  let command: ExtensionBootstrapCommand
  let tunnelInstanceId: String
  let generation: UInt64
  let readiness: ExtensionReadinessAssertion?
  let health: ExtensionBootstrapHealth?
}

enum ExtensionNativeJoinCommand: String, Codable {
  case start = "native-join-start"
  case status = "native-join-status"
  case cancel = "native-join-cancel"
  case commit = "native-join-commit"
}

enum ExtensionNativeJoinState: String, Encodable {
  case accepted, rendezvous
  case peerInstalled = "peer-installed"
  case readyToEnroll = "ready-to-enroll"
  case committing, committed, failed, cancelled
}

struct ExtensionNativeJoinStart: Decodable, Equatable {
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

struct ExtensionNativeJoinCommit: Decodable, Equatable {
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

struct ExtensionNativeJoinCancel: Decodable {
  let version: Int
  let transactionId: String
  let tunnelInstanceId: String
  let generation: UInt64
  let reason: String
}

struct ExtensionNativeJoinMessage: Decodable {
  let version: Int
  let command: ExtensionNativeJoinCommand
  let tunnelInstanceId: String
  let generation: UInt64
  let transactionId: String
  let start: ExtensionNativeJoinStart?
  let commit: ExtensionNativeJoinCommit?
  let cancel: ExtensionNativeJoinCancel?
}

struct ExtensionNativeJoinStatus: Encodable {
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
  /// The inviter-signed bootstrap response; hub-pro requires it as the
  /// admission on the joiner's first bind.
  let admission: DirectBootstrapResponse?
  /// The inviter's WireGuard endpoint the bootstrap link uses; the app keeps
  /// it as the hub peer of the committed membership.
  let hubPeerEndpoint: String?
  let state: ExtensionNativeJoinState
  let updatedAt: String
  let error: NetworkError?
}

struct ExtensionNativeJoinResponse: Encodable {
  let version: Int
  let command: ExtensionNativeJoinCommand
  let tunnelInstanceId: String
  let generation: UInt64
  let transactionId: String
  let status: ExtensionNativeJoinStatus
}

extension KeyChain {
  static func hubIdentity() throws -> Self {
    let accessGroup = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String
    return try KeyChain(
      keychain: .init(
        service: "dev.v57.Hub.identity.v1",
        account: "ed25519-private-key",
        accessGroup: accessGroup?.isEmpty == false ? accessGroup : nil,
        useDataProtectionKeychain: true
      ),
      createIfMissing: false
    )
  }
}
