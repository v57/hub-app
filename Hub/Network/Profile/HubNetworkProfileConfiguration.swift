import Foundation
import HubService
import Network

/// Configuration exchanged between Hub and its packet-tunnel extension.
///
/// Keep this model free of NetworkExtension and WireGuard types: the app owns
/// profile selection and persistence while the extension owns packet handling.
/// The WireGuard peer of the hub host (the inviting agent) for a joined
/// membership. A member reaches hub-server only through it, so it is persisted
/// with the profile and installed on every tunnel start.
struct HubNetworkPeer: Codable, Equatable, Sendable {
  let publicKey: String
  let endpoint: String
  let allowedIPs: [String]
}

struct HubNetworkProfileConfiguration: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let hubURL: URL
  let hubNetworkID: String
  let profilePublicKey: String
  let overlayIPv4Address: String
  let overlayIPv6Address: String
  let dnsSuffix: String
  let overlayIPv4Route: String
  let overlayIPv6Route: String
  let dnsRecords: [HubNetworkDNSRecord]?
  let dnsServerAddress: String?
  let trustedHubKey: String?
  let wireGuardPublicKey: String?
  let connectionGrant: ConnectionGrant?
  let gatewayGrant: GatewayGrant?
  let peerEndpoint: String?
  let controlPlaneIPv4Hosts: [String]?
  let controlPlaneIPv6Hosts: [String]?
  private(set) var gatewayServingEnabled: Bool?
  let servesInviter: Bool?
  let nodeEndpoint: String?
  let hubPeer: HubNetworkPeer?

  var servesGateway: Bool { gatewayServingEnabled == true }
  var usesGateway: Bool { gatewayGrant != nil }
  var inviterEnabled: Bool { servesInviter == true }

  init(
    version: Int = currentVersion,
    hubURL: URL,
    hubNetworkID: String,
    profilePublicKey: String,
    overlayIPv4Address: String,
    overlayIPv6Address: String,
    dnsSuffix: String = "hub.invalid",
    overlayIPv4Route: String = "100.96.0.0/11",
    overlayIPv6Route: String = "fd48:5542:4e45::/48",
    dnsRecords: [HubNetworkDNSRecord] = [],
    dnsServerAddress: String? = nil,
    trustedHubKey: String? = nil,
    wireGuardPublicKey: String? = nil,
    connectionGrant: ConnectionGrant? = nil,
    gatewayGrant: GatewayGrant? = nil,
    peerEndpoint: String? = nil,
    controlPlaneIPv4Hosts: [String] = [],
    controlPlaneIPv6Hosts: [String] = [],
    gatewayServingEnabled: Bool = false,
    servesInviter: Bool = false,
    nodeEndpoint: String? = nil,
    hubPeer: HubNetworkPeer? = nil
  ) {
    self.version = version
    self.hubURL = hubURL
    self.hubNetworkID = hubNetworkID
    self.profilePublicKey = profilePublicKey
    self.overlayIPv4Address = overlayIPv4Address
    self.overlayIPv6Address = overlayIPv6Address
    self.dnsSuffix = dnsSuffix
    self.overlayIPv4Route = overlayIPv4Route
    self.overlayIPv6Route = overlayIPv6Route
    self.dnsRecords = dnsRecords
    self.dnsServerAddress = dnsServerAddress
    self.trustedHubKey = trustedHubKey
    self.wireGuardPublicKey = wireGuardPublicKey
    self.connectionGrant = connectionGrant
    self.gatewayGrant = gatewayGrant
    self.peerEndpoint = peerEndpoint
    self.controlPlaneIPv4Hosts = controlPlaneIPv4Hosts
    self.controlPlaneIPv6Hosts = controlPlaneIPv6Hosts
    self.gatewayServingEnabled = gatewayServingEnabled
    self.servesInviter = servesInviter
    self.nodeEndpoint = nodeEndpoint
    self.hubPeer = hubPeer
  }

  /// A copy with only gateway serving changed.
  func withGatewayServing(_ enabled: Bool) -> Self {
    var copy = self
    copy.gatewayServingEnabled = enabled
    return copy
  }

  func validate() throws {
    guard version == Self.currentVersion else {
      throw HubNetworkProfileConfigurationError.unsupportedVersion(version)
    }
    guard hubURL.scheme == "wss" || hubURL.scheme == "ws" else {
      throw HubNetworkProfileConfigurationError.invalidHubURL
    }
    guard dnsSuffix == "hub.invalid" else {
      throw HubNetworkProfileConfigurationError.invalidDNSSuffix
    }
    guard overlayIPv4Route == "100.96.0.0/11",
          overlayIPv6Route == "fd48:5542:4e45::/48" else {
      throw HubNetworkProfileConfigurationError.nonOverlayRouteNotAllowed
    }
    guard Self.isOverlayIPv4Address(overlayIPv4Address),
          Self.isOverlayIPv6Address(overlayIPv6Address) else {
      throw HubNetworkProfileConfigurationError.invalidOverlayAddress
    }
    for record in dnsRecords ?? [] {
      guard record.authority.hasSuffix(".\(dnsSuffix)"),
            !record.authority.contains("..") else {
        throw HubNetworkProfileConfigurationError.invalidDNSRecord
      }
      let hostAddress = record.address.contains(":")
        ? "\(record.address)/128"
        : "\(record.address)/32"
      guard record.address.contains(":")
        ? Self.isOverlayIPv6Address(hostAddress)
        : Self.isOverlayIPv4Address(hostAddress) else {
        throw HubNetworkProfileConfigurationError.invalidDNSRecord
      }
    }
    if let dnsServerAddress {
      guard (dnsRecords ?? []).contains(where: {
        $0.address == dnsServerAddress
      }) else {
        throw HubNetworkProfileConfigurationError.invalidDNSRecord
      }
      if let connectionGrant {
        guard dnsServerAddress == connectionGrant.destinationAddress else {
          throw HubNetworkProfileConfigurationError.invalidDNSRecord
        }
      }
    }
    guard connectionGrant == nil || gatewayGrant == nil else {
      throw HubNetworkProfileConfigurationError.incompletePeerConfiguration
    }
    let signedGrantPresent = connectionGrant != nil || gatewayGrant != nil
    guard !signedGrantPresent
      || (wireGuardPublicKey != nil && peerEndpoint != nil) else {
      throw HubNetworkProfileConfigurationError.incompletePeerConfiguration
    }
    if let wireGuardPublicKey, let connectionGrant {
      guard let trustedHubKey else {
        throw HubNetworkProfileConfigurationError.incompletePeerConfiguration
      }
      try HubNetworkSignedEnvelope.validateConnectionGrant(
        connectionGrant,
        binding: ConnectionGrantBinding(
          trustedHubKey: trustedHubKey,
          hubNetworkId: hubNetworkID,
          callerKey: profilePublicKey,
          callerWireGuardKey: wireGuardPublicKey,
          generation: connectionGrant.generation
        )
      )
    }
    if let wireGuardPublicKey, let gatewayGrant {
      guard let trustedHubKey else {
        throw HubNetworkProfileConfigurationError.incompletePeerConfiguration
      }
      try HubNetworkSignedEnvelope.validateGatewayGrant(
        gatewayGrant,
        binding: GatewayGrantBinding(
          trustedHubKey: trustedHubKey,
          hubNetworkId: hubNetworkID,
          gatewayKey: gatewayGrant.gatewayKey,
          gatewayWireGuardKey: gatewayGrant.gatewayWireGuardKey,
          generation: gatewayGrant.generation,
          clientKey: profilePublicKey,
          clientWireGuardKey: wireGuardPublicKey,
          ipv4: gatewayGrant.ipv4,
          ipv6: gatewayGrant.ipv6,
          dns: gatewayGrant.dns
        )
      )
      guard gatewayGrant.dns else {
        throw HubNetworkProfileConfigurationError.gatewayDNSRequired
      }
    }
    guard (controlPlaneIPv4Hosts ?? []).allSatisfy(Self.isIPv4Host),
          (controlPlaneIPv6Hosts ?? []).allSatisfy(Self.isIPv6Host) else {
      throw HubNetworkProfileConfigurationError.invalidControlPlaneRoute
    }
    if let hubPeer {
      guard Data(base64Encoded: hubPeer.publicKey)?.count == 32,
            !hubPeer.endpoint.isEmpty,
            !hubPeer.allowedIPs.isEmpty,
            hubPeer.allowedIPs.allSatisfy({
              $0.contains(":") ? Self.isOverlayIPv6Address($0) : Self.isOverlayIPv4Address($0)
            }) else {
        throw HubNetworkProfileConfigurationError.incompletePeerConfiguration
      }
    }
  }

  private static func isOverlayIPv4Address(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[1] == "32",
          let address = IPv4Address(String(parts[0])) else { return false }
    let bytes = Array(address.rawValue)
    return bytes.count == 4
      && bytes[0] == 100
      && (bytes[1] & 0b1110_0000) == 96
  }

  private static func isOverlayIPv6Address(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[1] == "128",
          let address = IPv6Address(String(parts[0])) else { return false }
    return Array(address.rawValue).starts(with: [0xfd, 0x48, 0x55, 0x42, 0x4e, 0x45])
  }

  private static func isIPv4Host(_ value: String) -> Bool {
    IPv4Address(value) != nil
  }

  private static func isIPv6Host(_ value: String) -> Bool {
    IPv6Address(value) != nil
  }
}

enum HubNetworkProfileConfigurationError: Error, Equatable {
  case unsupportedVersion(Int)
  case invalidHubURL
  case invalidDNSSuffix
  case nonOverlayRouteNotAllowed
  case invalidOverlayAddress
  case invalidDNSRecord
  case incompletePeerConfiguration
  case gatewayDNSRequired
  case invalidControlPlaneRoute
}

struct HubNetworkDNSRecord: Codable, Equatable, Hashable, Sendable {
  let authority: String
  let address: String
}

enum HubNetworkAppGroup {
  static let identifier = "group.dev.v57.hub"
  static let profileFile = "hub-network-profile-v1.json"

  static func profileURL(
    containerURL: URL? = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: identifier
    )
  ) throws -> URL {
    guard let containerURL else {
      throw HubNetworkAppGroupError.containerUnavailable
    }
    return containerURL.appendingPathComponent(profileFile, isDirectory: false)
  }
}

enum HubNetworkAppGroupError: Error {
  case containerUnavailable
}

/// Atomic persistence shared by the containing app and packet-tunnel extension.
///
/// The profile intentionally contains public binding material only. Private
/// profile and WireGuard keys belong in a shared-access Keychain group.
struct HubNetworkProfileStore: Sendable {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    fileURL: URL,
    encoder: JSONEncoder = JSONEncoder(),
    decoder: JSONDecoder = JSONDecoder()
  ) {
    self.fileURL = fileURL
    self.encoder = encoder
    self.decoder = decoder
  }

  init() throws {
    try self.init(fileURL: HubNetworkAppGroup.profileURL())
  }

  func save(_ configuration: HubNetworkProfileConfiguration) throws {
    try configuration.validate()
    let data = try encoder.encode(configuration)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
  }

  func load() throws -> HubNetworkProfileConfiguration {
    let configuration = try loadWithoutValidation()
    try configuration.validate()
    return configuration
  }

  /// Decodes persisted state for fail-closed migration only. Callers must
  /// validate or replace the result before using it as tunnel configuration.
  func loadWithoutValidation() throws -> HubNetworkProfileConfiguration {
    try decoder.decode(
      HubNetworkProfileConfiguration.self,
      from: Data(contentsOf: fileURL)
    )
  }

  func remove() throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }
}
