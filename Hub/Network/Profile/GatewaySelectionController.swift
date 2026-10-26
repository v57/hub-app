import Foundation
import HubService
import Network
import Darwin

private struct GatewayGrantRequest: Encodable, Sendable {
  let clientKey: String
  let clientWireGuardKey: String
  let gatewayKey: String
  let ipv4: Bool
  let ipv6: Bool
  let dns: Bool
}

private struct GatewayGrantResponse: Decodable, Sendable {
  let grant: GatewayGrant
}

struct ReachableGateway: Identifiable, Equatable, Sendable {
  var id: String { status.key }

  let status: GatewayStatus
  let overlayAddress: String
  let peerEndpoint: String
}

@MainActor
final class GatewaySelectionController {
  static func reachable(
    statuses: [GatewayStatus],
    agents: [HubNetworkAgent]
  ) -> [ReachableGateway] {
    var reachable = [ReachableGateway]()
    for status in statuses {
      guard isUsable(status),
            let agent = matchingAgent(for: status, in: agents),
            let address = gatewayAddress(for: status, agent: agent),
            let endpoint = Optional(status.endpoint),
            endpointHost(endpoint) != nil else {
        continue
      }
      reachable.append(
        ReachableGateway(
          status: status,
          overlayAddress: address,
          peerEndpoint: endpoint
        )
      )
    }
    return reachable.sorted {
      if $0.status.capability.metered != $1.status.capability.metered {
        return !$0.status.capability.metered
      }
      return $0.status.key < $1.status.key
    }
  }

  private static func isUsable(_ status: GatewayStatus) -> Bool {
    status.version == hubNetworkWireVersion
      && status.state == .available
      && status.capability.capability == "internet-gateway-v1"
      && status.capability.dns
      && (status.capability.ipv4 || status.capability.ipv6)
  }

  private static func matchingAgent(
    for status: GatewayStatus,
    in agents: [HubNetworkAgent]
  ) -> HubNetworkAgent? {
    agents.first {
      $0.key == status.key
        && $0.key == status.key
        && $0.wireGuardKey == status.wireGuardKey
    }
  }

  private static func gatewayAddress(
    for status: GatewayStatus,
    agent: HubNetworkAgent
  ) -> String? {
    agent.overlayAddresses.first {
      if status.capability.ipv4 {
        return IPv4Address($0) != nil
      }
      return IPv6Address($0) != nil
    }
  }

  func select(
    _ gateway: ReachableGateway,
    hub: Hub,
    tunnel: PacketTunnelController,
    controlPlaneHosts: [String] = []
  ) async throws {
    try await tunnel.replaceAndStart(
      configuration: configuration(gateway, hub: hub, controlPlaneHosts: controlPlaneHosts)
    )
  }

  /// The profile that sends this device's traffic through `gateway`, with a grant the hub issues for it now
  private func configuration(
    _ gateway: ReachableGateway,
    hub: Hub,
    controlPlaneHosts: [String]
  ) async throws -> HubNetworkProfileConfiguration {
    let wireGuardKey = try HubNetworkWireGuardKeyStore().publicKeyBase64()
    let current = try HubNetworkProfileStore().load()
    guard current.profilePublicKey == hub.key,
          current.hubNetworkID == gateway.status.hubNetworkId,
          current.trustedHubKey != nil else {
      throw GatewaySelectionError.membershipMismatch
    }

    let response: GatewayGrantResponse = try await hub.client.send(
      "network/gateway/grant",
      GatewayGrantRequest(
        clientKey: hub.key,
        clientWireGuardKey: wireGuardKey,
        gatewayKey: gateway.status.key,
        ipv4: gateway.status.capability.ipv4,
        ipv6: gateway.status.capability.ipv6,
        dns: true
      )
    )
    let grant = response.grant
    try HubNetworkSignedEnvelope.validateGatewayGrant(
      grant,
      binding: GatewayGrantBinding(
        trustedHubKey: current.trustedHubKey!,
        hubNetworkId: current.hubNetworkID,
        gatewayKey: gateway.status.key,
        gatewayWireGuardKey: gateway.status.wireGuardKey,
        generation: grant.generation,
        clientKey: hub.key,
        clientWireGuardKey: wireGuardKey,
        ipv4: gateway.status.capability.ipv4,
        ipv6: gateway.status.capability.ipv6,
        dns: true
      )
    )

    let endpointHostValue = Self.endpointHost(gateway.peerEndpoint)
    // A gateway names itself (`mac.local:51820`); the tunnel takes it by address, resolved here where local names
    // resolve
    let peerEndpoint = Self.numericEndpoint(gateway.peerEndpoint, preferring: hub.settings.address.host)
      ?? gateway.peerEndpoint
    let namedControlHosts = [hub.settings.address.host, endpointHostValue]
      .compactMap { $0 }
    var resolvedControlHosts = [String]()
    for host in namedControlHosts {
      resolvedControlHosts.append(contentsOf: Self.resolve(host))
    }
    let allControlHosts = controlPlaneHosts + namedControlHosts
      + resolvedControlHosts
    let ipv4Hosts = Array(Set(allControlHosts.filter { IPv4Address($0) != nil })).sorted()
    let ipv6Hosts = Array(Set(allControlHosts.filter { IPv6Address($0) != nil })).sorted()

    return HubNetworkProfileConfiguration(
      version: current.version,
      hubURL: current.hubURL,
      hubNetworkID: current.hubNetworkID,
      profilePublicKey: current.profilePublicKey,
      overlayIPv4Address: current.overlayIPv4Address,
      overlayIPv6Address: current.overlayIPv6Address,
      dnsSuffix: current.dnsSuffix,
      overlayIPv4Route: current.overlayIPv4Route,
      overlayIPv6Route: current.overlayIPv6Route,
      dnsRecords: [
        HubNetworkDNSRecord(
          authority: "gateway.\(current.dnsSuffix)",
          address: gateway.overlayAddress
        )
      ],
      dnsServerAddress: gateway.overlayAddress,
      trustedHubKey: current.trustedHubKey,
      wireGuardPublicKey: wireGuardKey,
      gatewayGrant: grant,
      peerEndpoint: peerEndpoint,
      controlPlaneIPv4Hosts: ipv4Hosts,
      controlPlaneIPv6Hosts: ipv6Hosts,
      gatewayServingEnabled: current.servesGateway,
      // The links, the inviter and the hub host stay as they were: a gateway away from this device's network is
      // reached through the link to it
      servesInviter: current.inviterEnabled,
      nodeEndpoint: current.nodeEndpoint,
      hubPeer: current.hubPeer,
      gatewayFallback: HubNet.gatewayFallback
    )
  }

  /// A new grant for the gateway in use: the running tunnel takes it in place, so its flows go on; a tunnel that
  /// can't (stopped, another gateway) starts again with it
  func renew(
    _ gateway: ReachableGateway,
    hub: Hub,
    tunnel: PacketTunnelController,
    controlPlaneHosts: [String] = []
  ) async throws {
    let configuration = try await configuration(gateway, hub: hub, controlPlaneHosts: controlPlaneHosts)
    guard await !tunnel.renewGateway(configuration: configuration) else { return }
    try await tunnel.replaceAndStart(configuration: configuration)
  }

  func disable(tunnel: PacketTunnelController) async throws {
    print("GatewaySelectionController.disable")
    try await tunnel.replaceAndStart(configuration: try HubNetworkProfileStore().load().withoutGateway())
  }

  private static func endpointHost(_ endpoint: String) -> String? {
    if endpoint.hasPrefix("["),
       let closingBracket = endpoint.firstIndex(of: "]") {
      return String(endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket])
    }
    guard let separator = endpoint.lastIndex(of: ":"),
          separator != endpoint.startIndex,
          Int(endpoint[endpoint.index(after: separator)...]) != nil else {
      return nil
    }
    return String(endpoint[..<separator])
  }

  /// `host:port` with the host resolved to an address, IPv4 first (`192.168.1.21:51820`, `[fd00::1]:51820`); nil when
  /// it doesn't resolve. A Mac answers with one address per interface: `preferring` (the address this device reaches
  /// the hub at, when the gateway is the hub's machine) wins.
  static func numericEndpoint(_ endpoint: String, preferring preferred: String? = nil) -> String? {
    guard let host = endpointHost(endpoint), let colon = endpoint.lastIndex(of: ":") else { return nil }
    let port = endpoint[endpoint.index(after: colon)...]
    let addresses = resolve(host)
    if let preferred, addresses.contains(preferred) {
      return IPv6Address(preferred) != nil ? "[\(preferred)]:\(port)" : "\(preferred):\(port)"
    }
    if let ipv4 = addresses.filter({ IPv4Address($0) != nil }).sorted().first(where: { !$0.hasPrefix("169.254.") }) {
      return "\(ipv4):\(port)"
    }
    // A scoped link-local address (`fe80::1%awdl0`) only reaches the gateway from this device's own link
    return addresses.first { IPv6Address($0) != nil && !$0.contains("%") }.map { "[\($0)]:\(port)" }
  }

  private static func resolve(_ host: String) -> [String] {
    if IPv4Address(host) != nil || IPv6Address(host) != nil {
      return [host]
    }
    var hints = addrinfo(
      ai_flags: AI_ADDRCONFIG,
      ai_family: AF_UNSPEC,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
    defer { freeaddrinfo(result) }
    var values = Set<String>()
    var current = result
    while let info = current?.pointee {
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(
        info.ai_addr,
        info.ai_addrlen,
        &buffer,
        socklen_t(buffer.count),
        nil,
        0,
        NI_NUMERICHOST
      ) == 0 {
        values.insert(String(cString: buffer))
      }
      current = info.ai_next
    }
    return values.sorted()
  }
}

enum GatewaySelectionError: Error, Equatable {
  case membershipMismatch
}
