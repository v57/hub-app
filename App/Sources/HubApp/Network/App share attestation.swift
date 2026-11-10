//
//  App share attestation.swift
//  Hub
//
//  The attestation of a Hub Network share the app serves itself (a security camera, This Device's Storage).
//

#if canImport(PlatformCamera) || canImport(S3ServerSwift)
import Foundation
import HubService

/// A share's attestation signed by this app's own key, the key of this device's Hub Network membership: what a
/// machine's agent (`LocalShareAgent`) signs for the services it fronts, here for the app's own servers. Every share
/// of one hub's connection gets it from the same provider, so the camera and Storage set the same one.
enum AppShareAttestation {
  static func attest(_ share: NetworkShare, serviceKey: String, identity: KeyChain) throws -> AgentAttestation {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = Date()
    DevicePorts.main.noteAttested(protocol: share.protocol.rawValue, port: share.target.port)
    let unsigned = AgentAttestation(
      attestationId: UUID().uuidString.lowercased(), serviceKey: serviceKey, key: identity.publicKey(), shareName: share.name,
      protocol: share.protocol, target: share.target, issuedAt: formatter.string(from: now),
      expiresAt: formatter.string(from: now.addingTimeInterval(120)), signature: "")
    let input = try HubNetworkSignedEnvelope.signatureInput(for: unsigned, domain: "hub-network/agent-attestation/v1")
    return AgentAttestation(
      attestationId: unsigned.attestationId, serviceKey: serviceKey, key: unsigned.key, shareName: share.name,
      protocol: share.protocol, target: share.target, issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt,
      signature: identity.sign(data: input))
  }

  /// Sets the provider on `hub`'s connection
  @MainActor static func provide(for hub: Hub) {
    let identity = hub.identity
    hub.service.network.setAttestationProvider { share, serviceKey, _ in
      try attest(share, serviceKey: serviceKey, identity: identity)
    }
  }
}
#endif
