import Foundation
import HubService
import Network

/// The hub host's WireGuard peer for a joined membership (see the app's
/// `HubNetworkPeer`).
struct HubPeer: Decodable {
  let publicKey: String
  let endpoint: String
  let allowedIPs: [String]
}

struct Profile: Decodable {
  static let currentVersion = 1
  static let appGroupIdentifier = "group.dev.v57.hub"
  static let profileFile = "hub-network-profile-v1.json"

  let version: Int
  let hubURL: URL
  let hubNetworkID: String
  let profilePublicKey: String
  /// The profile's key as the hub writes it (SPKI): a join stores the raw 32-byte key
  var profileKey: String { KeyChain.spkiPublicKey(rawBase64: profilePublicKey) ?? profilePublicKey }
  let overlayIPv4Address: String
  let overlayIPv6Address: String
  let dnsSuffix: String
  let overlayIPv4Route: String
  let overlayIPv6Route: String
  let dnsRecords: [DNS.Record]?
  let dnsServerAddress: String?
  let trustedHubKey: String?
  let wireGuardPublicKey: String?
  let connectionGrant: ConnectionGrant?
  let gatewayGrant: GatewayGrant?
  let peerEndpoint: String?
  let controlPlaneIPv4Hosts: [String]?
  let controlPlaneIPv6Hosts: [String]?
  let gatewayServingEnabled: Bool?
  let servesInviter: Bool?
  let nodeEndpoint: String?
  let hubPeer: HubPeer?
  /// Through a gateway, whether traffic goes through this device's own network while the gateway can't be reached
  let gatewayFallback: Bool?

  var servesGateway: Bool { gatewayServingEnabled == true }
  var usesGateway: Bool { gatewayGrant != nil }
  var fallsBack: Bool { usesGateway && gatewayFallback == true }
  var inviterEnabled: Bool { servesInviter == true }

  static func load() throws -> Self {
    let profile = try decode()
    try profile.validate()
    return profile
  }

  static func decode() throws -> Self {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
      throw Error.containerUnavailable
    }
    let url = container.appendingPathComponent(profileFile, isDirectory: false)
    return try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
  }

  func validate() throws {
    guard version == Profile.currentVersion else {
      throw Error.unsupportedVersion
    }
    guard hubURL.scheme == "wss" || hubURL.scheme == "ws", hubURL.host != nil else { throw Error.invalidHubURL }
    guard dnsSuffix == "hub.invalid" else { throw Error.invalidDNSSuffix }
    guard overlayIPv4Route == "100.96.0.0/11", overlayIPv6Route == "fd48:5542:4e45::/48" else { throw Error.nonOverlayRouteNotAllowed }
    _ = try Address(overlay: overlayIPv4Address)
    _ = try Address(overlay: overlayIPv6Address)
    for record in dnsRecords ?? [] {
      guard record.authority.hasSuffix(".\(dnsSuffix)"), !record.authority.contains("..") else { throw Error.invalidDNSRecord }
      _ = try Address(record.address)
    }
    if let dnsServerAddress {
      guard dnsRecords?.contains(where: { $0.address == dnsServerAddress }) ?? false else { throw Error.invalidDNSRecord }
      if let connectionGrant {
        guard dnsServerAddress == connectionGrant.destinationAddress else { throw Error.invalidDNSRecord }
      }
    }
    guard connectionGrant == nil || gatewayGrant == nil else { throw Error.incompletePeerConfiguration }
    let signedGrantPresent = connectionGrant != nil || gatewayGrant != nil
    guard !signedGrantPresent || (wireGuardPublicKey != nil && peerEndpoint != nil) else { throw Error.incompletePeerConfiguration }
    if let wireGuardPublicKey, let connectionGrant {
      guard let trustedHubKey else { throw Error.incompletePeerConfiguration }
      try HubNetworkSignedEnvelope.validateConnectionGrant(
        connectionGrant,
        binding: ConnectionGrantBinding(
          trustedHubKey: trustedHubKey,
          hubNetworkId: hubNetworkID,
          callerKey: profileKey,
          callerWireGuardKey: wireGuardPublicKey,
          generation: connectionGrant.generation
        )
      )
    }
    if let wireGuardPublicKey, let gatewayGrant {
      guard let trustedHubKey else {
        throw Error.incompletePeerConfiguration
      }
      try HubNetworkSignedEnvelope.validateGatewayGrant(
        gatewayGrant,
        binding: GatewayGrantBinding(
          trustedHubKey: trustedHubKey,
          hubNetworkId: hubNetworkID,
          gatewayKey: gatewayGrant.gatewayKey,
          gatewayWireGuardKey: gatewayGrant.gatewayWireGuardKey,
          generation: gatewayGrant.generation,
          clientKey: profileKey,
          clientWireGuardKey: wireGuardPublicKey,
          ipv4: gatewayGrant.ipv4,
          ipv6: gatewayGrant.ipv6,
          dns: gatewayGrant.dns
        )
      )
      guard gatewayGrant.dns else { throw Error.gatewayDNSRequired }
    }
    guard (controlPlaneIPv4Hosts ?? []).allSatisfy({ IPv4Address($0) != nil }),
          (controlPlaneIPv6Hosts ?? []).allSatisfy({ IPv6Address($0) != nil }) else {
      throw Error.invalidControlPlaneRoute
    }
  }
  
  enum Error: Swift.Error {
    case containerUnavailable
    case unsupportedVersion
    case invalidHubURL
    case invalidDNSSuffix
    case nonOverlayRouteNotAllowed
    case invalidDNSRecord
    case incompletePeerConfiguration
    case gatewayDNSRequired
    case invalidControlPlaneRoute
  }
}
