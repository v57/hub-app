import Foundation
import HubService
#if canImport(Network)
import Network
#endif
#if canImport(Darwin)
import Darwin
#endif

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

  private static func isOverlay(_ host: String) -> Bool {
    if let address = IPv4Address(host) {
      let bytes = Array(address.rawValue)
      return bytes[0] == 100 && (bytes[1] & 0b1110_0000) == 96
    }
    if let address = IPv6Address(host) { return Array(address.rawValue).starts(with: [0xfd, 0x48, 0x55, 0x42, 0x4e, 0x45]) }
    return false
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

  /// `isWanted`: whether the caller still wants this gateway once the hub granted it (the user may have cancelled or
  /// chosen another meanwhile); when not, the tunnel stays as it is and this throws `CancellationError`
  func select(
    _ gateway: ReachableGateway,
    hub: Hub,
    tunnel: PacketTunnelController,
    controlPlaneHosts: [String] = [],
    isWanted: @MainActor () -> Bool = { true }
  ) async throws {
    let configuration = try await configuration(gateway, hub: hub, controlPlaneHosts: controlPlaneHosts)
    guard isWanted(), !Task.isCancelled else { throw CancellationError() }
    try await tunnel.replaceAndStart(configuration: configuration)
  }

  /// How long the hub has to grant a gateway: a hub that went away doesn't answer, and the channel would wait for it
  static let grantTimeout: Duration = .seconds(20)

  /// The profile that sends this device's traffic through `gateway`, with a grant the hub issues for it now
  private func configuration(
    _ gateway: ReachableGateway,
    hub: Hub,
    controlPlaneHosts: [String]
  ) async throws -> HubNetworkProfileConfiguration {
    let wireGuardKey = try HubNetworkWireGuardKeyStore().publicKeyBase64()
    let current = try HubNetworkProfileStore().load()
    guard current.profileKey == hub.key,
          current.hubNetworkID == gateway.status.hubNetworkId,
          current.trustedHubKey != nil else {
      throw GatewaySelectionError.membershipMismatch
    }

    let request = GatewayGrantRequest(
      clientKey: hub.key,
      clientWireGuardKey: wireGuardKey,
      gatewayKey: gateway.status.key,
      ipv4: gateway.status.capability.ipv4,
      ipv6: gateway.status.capability.ipv6,
      dns: true
    )
    let hubName = hub.settings.name
    let response: GatewayGrantResponse = try await bounded(
      Self.grantTimeout, timedOut: { GatewaySelectionError.hubDidNotAnswer(hubName) }
    ) { @MainActor in
      try await hub.client.send("network/gateway/grant", request)
    }
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
    // A member that joined by invitation reaches its hub at the hub machine's overlay address: that one stays in the
    // tunnel, or the hub is out of reach while the gateway is in use
    let allControlHosts = (controlPlaneHosts + namedControlHosts + resolvedControlHosts).filter { !Self.isOverlay($0) }
    let ipv4Hosts = Array(Set(allControlHosts.filter { IPv4Address($0) != nil })).sorted()
    let ipv6Hosts = Array(Set(allControlHosts.filter { IPv6Address($0) != nil })).sorted()

    return HubNetworkProfileConfiguration(
      version: current.version,
      hubURL: current.hubURL,
      hubNetworkID: current.hubNetworkID,
      profilePublicKey: current.profilePublicKey,
      keyScope: current.keyScope,
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
    var hints = addrinfo()
    hints.ai_flags = AI_ADDRCONFIG
    hints.ai_family = AF_UNSPEC
#if canImport(Darwin)
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
#else
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    hints.ai_protocol = Int32(IPPROTO_TCP)
#endif
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

enum GatewaySelectionError: LocalizedError, Equatable {
  case membershipMismatch
  /// The hub didn't grant the gateway in time (`grantTimeout`)
  case hubDidNotAnswer(String)

  var errorDescription: String? {
    switch self {
    case .membershipMismatch:
      String(localized: "This device’s Hub Network membership doesn’t match that device’s network. Turn Hub Network off and on, then try again.")
    case .hubDidNotAnswer(let hub):
      String(localized: "\(hub) didn’t answer, so that device’s internet couldn’t be used. Check that \(hub) is online, then try again.")
    }
  }
}

/// `operation`'s result, or `timedOut()` once `limit` passes, or `CancellationError` once the caller is cancelled,
/// whichever comes first. A channel send waits on through a hub that went away and ignores cancellation, so it can't
/// be awaited directly where someone waits; when it answers late, its answer is dropped.
@MainActor
func bounded<T: Sendable>(
  _ limit: Duration,
  timedOut: @escaping @Sendable () -> Error,
  _ operation: @escaping @MainActor @Sendable () async throws -> T
) async throws -> T {
  let once = BoundedResult<T>()
  let work = Task { @MainActor in
    do { once.finish(.success(try await operation())) } catch { once.finish(.failure(error)) }
  }
  let timer = Task {
    try? await Task.sleep(for: limit)
    once.finish(.failure(timedOut()))
  }
  defer {
    work.cancel()
    timer.cancel()
  }
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in once.wait(continuation) }
  } onCancel: {
    once.finish(.failure(CancellationError()))
  }
}

/// The first of `bounded`'s outcomes, handed to its waiter once
private final class BoundedResult<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?
  private var result: Result<T, Error>?

  func wait(_ continuation: CheckedContinuation<T, Error>) {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func finish(_ result: Result<T, Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}
