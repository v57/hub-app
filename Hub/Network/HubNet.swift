import Foundation
import Channel
import HubService
import Network
import Observation

@Observable
@MainActor
final class HubNets {
  static let main = HubNets()

  private(set) var vpn = false
  private(set) var joinProgress: NativeJoinProgress?
  private var activeJoin: Task<Hub, Error>?
  private var activeJoinTokenId: String?

  init() {
    Task { [weak self] in
      guard let self else { return }
      self.vpn = (try? await Self.vpnActive()) ?? false
    }
  }

  func vpn(enabled: Bool) async throws {
    let tunnel = try PacketTunnelController()
    if enabled {
      try await tunnel.start()
    } else {
      await tunnel.stop()
    }
    vpn = enabled
  }

  static func vpnActive() async throws -> Bool {
    await (try PacketTunnelController()).status == .connected
  }

  /// Starts or resumes one native Apple Hub Network join.
  ///
  /// Calls are serialized on MainActor. Repeating same canonical invitation
  /// shares in-flight transaction; different invitation fails closed.
  func join(link: String) async throws -> Hub {
    if activeJoin == nil {
      joinProgress = .init(transactionId: "", state: .validating)
    }
    let decoded = try NetworkInvitationParser.decode(link)
    if let activeJoin {
      guard activeJoinTokenId == decoded.replayId else {
        throw NativeJoinError.transactionConflict
      }
      return try await activeJoin.value
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      return try await NativeJoinCoordinator.live.run(
        decoded,
        { progress in self.joinProgress = progress }
      )
    }
    activeJoinTokenId = decoded.replayId
    activeJoin = task
    defer {
      activeJoin = nil
      activeJoinTokenId = nil
    }
    return try await task.value
  }

  fileprivate func refresh() async {
    vpn = (try? await Self.vpnActive()) ?? false
  }
}

@Observable
@MainActor
final class HubNet {
  struct Address: Hashable, Sendable {
    let ipv4: String
    let ipv6: String
  }

  struct Device: Hashable, Identifiable, Sendable {
    var id: String { key }

    let key: String
    let name: String?
    let platform: String?
    let endpoint: String
    let overlayAddresses: [String]
    let capability: GatewayCapability

    let gateway: GatewayStatus
    let overlayAddress: String

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(key)
    }
  }

  let hub: Hub
  private var nets: HubNets { .main }
  private var vpnRenewalTask: Task<Void, Never>?
  private var inviterAgentWatcherTask: Task<Void, Never>?

  private(set) var isJoined = false
  private(set) var isSharing = false
  private(set) var vpn: Device?
  private(set) var address: Address?
  private(set) var sharedTcp = Set<Int>()
  private(set) var sharedUdp = Set<Int>()

  var devices: Set<Device> {
    Set(
      GatewaySelectionController.reachable(
        statuses: hub.state.networkGateways.value,
        agents: hub.state.networkAgents.value
      ).map { reachable in
        let agent = hub.state.networkAgents.value.first {
          $0.key == reachable.status.key
            && $0.key == reachable.status.key
        }
        return Device(
          key: reachable.status.key,
          
          name: agent?.name,
          platform: agent?.platform,
          endpoint: reachable.peerEndpoint,
          overlayAddresses: agent?.overlayAddresses ?? [],
          capability: reachable.status.capability,
          gateway: reachable.status,
          overlayAddress: reachable.overlayAddress
        )
      }
    )
  }

  init(hub: Hub) {
    self.hub = hub
  }

  func joinNetwork(enabled: Bool) async throws {
    let tunnel = try PacketTunnelController()
    if enabled {
      if await tunnel.status == .notInstalled {
        try await tunnel.authorizeAndInstallLocalHub(hub: hub)
      } else {
        try await tunnel.restoreInstalledLocalMembership(hub: hub)
      }
      try await tunnel.start()
      hub.networkAppAgent.enable(tunnel: tunnel)
      try refreshAddress(from: tunnel)
      isJoined = true
      await refreshGlobalVPN()
      startInviterAgentWatcher()
      print("done")
    } else {
      inviterAgentWatcherTask?.cancel()
      inviterAgentWatcherTask = nil
      if vpn != nil {
        try await disableVpn()
      }
      if isSharing {
        try await shareNetwork(enabled: false)
      }
      for port in sharedTcp.sorted() {
        try await shareTcp(port: port, enabled: false)
      }
      for port in sharedUdp.sorted() {
        try await shareUdp(port: port, enabled: false)
      }
      await hub.networkAppAgent.disable(tunnel: tunnel)
      await tunnel.stop()
      isJoined = false
      address = nil
      await refreshGlobalVPN()
    }
  }

  func shareTcp(port: Int, enabled: Bool) async throws {
    print("HubNet.shareTcp", port, enabled)
    try await share(port: port, protocol: .tcp, enabled: enabled)
  }

  func shareUdp(port: Int, enabled: Bool) async throws {
    print("HubNet.shareUdp", port, enabled)
    try await share(port: port, protocol: .udp, enabled: enabled)
  }

  func shareNetwork(enabled: Bool) async throws {
    print("HubNet.shareNetwork", enabled)
    let controller = GatewayServingController()
    try await controller.setEnabled(enabled, hub: hub, tunnel: PacketTunnelController())
    isSharing = enabled
  }

  func createInviteCode() async throws -> String {
    guard isJoined else { throw HubNetError.notJoined }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var identity: PacketTunnelBootstrapIdentity?
    while identity == nil {
      identity = hub.networkAppAgent.availableIdentity
      guard ContinuousClock.now < deadline else {
        throw HubNetError.localAgentUnavailable
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    try await waitForInvitationAgent(identity!)
    guard let agent = hub.state.hubNetAgents.value.first(where: {
      $0.localIp == "127.0.0.1"
    }) else {
      throw HubNetError.localAgentUnavailable
    }
    guard let node = await Self.currentNodeEndpoint(hub: hub) else {
      throw HubNetError.nodeNotSet
    }
    HubService.Group.HubNetworkNodeEndpointStore.shared.set(node)
    let link = try await hub.createNetworkInvitation(service: agent.id)
    guard (try? NetworkInvitationParser.decode(link)) != nil else {
      throw HubNetError.invalidInvitation
    }
    return link
  }

  func vpn(through device: Device) async throws {
    print("HubNet.vpn through", device)
    guard let device = devices.first(where: { $0.id == device.id }) else {
      throw HubNetError.deviceUnavailable
    }
    let reachable = ReachableGateway(
      status: device.gateway,
      overlayAddress: device.overlayAddress,
      peerEndpoint: device.endpoint
    )
    try await GatewaySelectionController().select(
      reachable,
      hub: hub,
      tunnel: PacketTunnelController()
    )
    vpn = device
    vpnRenewalTask?.cancel()
    vpnRenewalTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(240))
        guard !Task.isCancelled, let self,
              let current = self.devices.first(where: { $0.id == device.id }) else {
          return
        }
        do {
          try await GatewaySelectionController().renew(
            ReachableGateway(
              status: current.gateway,
              overlayAddress: current.overlayAddress,
              peerEndpoint: current.endpoint
            ),
            hub: self.hub,
            tunnel: PacketTunnelController()
          )
          self.vpn = current
        } catch {
          self.vpn = nil
          return
        }
      }
    }
    try refreshAddress(from: PacketTunnelController())
    await refreshGlobalVPN()
  }

  func disableVpn() async throws {
    print("HubNet.disableVpn")
    vpnRenewalTask?.cancel()
    vpnRenewalTask = nil
    let tunnel = try PacketTunnelController()
    try await GatewaySelectionController().disable(tunnel: tunnel)
    vpn = nil
    try refreshAddress(from: tunnel)
    await refreshGlobalVPN()
  }

  func service() -> HubService.Group {
    hub.service.group(enabled: isJoined)
  }

  func restoreIfActive() async {
    guard let tunnel = try? PacketTunnelController(),
          let profile = try? tunnel.installedConfiguration(),
          profile.hubURL == hub.settings.address,
          await tunnel.status == .connected else { return }
    // A joined non-owner device must not bind as the Apple local agent; the
    // bind API is only present for owners, so gate on it to avoid a
    // misleading `unavailable` state.
    if hub.api.contains("hub/net/apple-agent/bind") {
      hub.networkAppAgent.enable(tunnel: tunnel)
    }
    address = Self.address(from: profile)
    isJoined = true
    isSharing = profile.servesGateway
    if profile.usesGateway {
      vpn = devices.first { $0.key == profile.gatewayGrant?.gatewayKey }
    }
    await refreshGlobalVPN()
  }

  func connectionChanged(_ connected: Bool) {
    hub.networkAppAgent.channelConnectionChanged(connected)
  }

  func apiCapabilitiesChanged() {
    hub.networkAppAgent.apiCapabilitiesChanged()
  }

  private func share(
    port: Int,
    protocol networkProtocol: NetworkProtocol,
    enabled: Bool
  ) async throws {
    let validatedPort = try Self.validatedPort(port)
    guard isJoined else { throw HubNetError.notJoined }
    var ports = networkProtocol == .tcp ? sharedTcp : sharedUdp
    guard ports.contains(port) != enabled else { return }
    let name = "\(networkProtocol.rawValue)-\(port)"
    if enabled {
      try await hub.service.network.publish(
        NetworkShare(
          name: name,
          protocol: networkProtocol,
          target: LocalTarget(port: validatedPort)
        )
      )
      ports.insert(port)
    } else {
      try await hub.service.network.remove(name)
      ports.remove(port)
    }
    if networkProtocol == .tcp {
      sharedTcp = ports
    } else {
      sharedUdp = ports
    }
  }

  private func refreshAddress(from tunnel: PacketTunnelController) throws {
    print("HubNet.refreshAddress")
    address = Self.address(from: try tunnel.installedConfiguration())
  }

  private static func address(
    from profile: HubNetworkProfileConfiguration
  ) -> Address? {
    address(ipv4: profile.overlayIPv4Address, ipv6: profile.overlayIPv6Address)
  }

  static func address(ipv4 rawIPv4: String, ipv6 rawIPv6: String) -> Address? {
    let ipv4 = rawIPv4.split(separator: "/").first.map(String.init)
    let ipv6 = rawIPv6.split(separator: "/").first.map(String.init)
    guard let ipv4, let ipv6,
          IPv4Address(ipv4) != nil,
          IPv6Address(ipv6) != nil else { return nil }
    return Address(ipv4: ipv4, ipv6: ipv6)
  }

  static func validatedPort(_ port: Int) throws -> UInt16 {
    guard let port = UInt16(exactly: port), port > 0 else {
      throw HubNetError.invalidPort(port)
    }
    return port
  }

  static func date(from string: String) -> Date? {
    ISO8601DateFormatter.js.date(from: string)
  }

  private func waitForInvitationAgent(
    _ identity: PacketTunnelBootstrapIdentity
  ) async throws {
    for try await status: HubNetworkLocalAgentStatus in
      hub.client.values("hub/net/local-agent") {
      guard status.canIssueInvitation,
            status.tunnelInstanceId == identity.tunnelInstanceId,
            status.generation == identity.generation else { continue }
      return
    }
    throw HubNetError.localAgentUnavailable
  }

  /// The node `hub/net/node` names, `nil` when no owner has set one (there is no default node)
  private static func currentNodeEndpoint(hub: Hub) async -> String? {
    hub.state.hubNetNode.subscribe(hub: hub)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if let node = hub.state.hubNetNode.value, !node.isEmpty {
        return node
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return nil
  }

  /// Sets or clears (`nil`) the node invitations name. Owners only.
  func setNode(_ endpoint: String?) async throws {
    let endpoint = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
    try await hub.client.send("hub/net/node/set", endpoint?.isEmpty == false ? endpoint : nil)
  }

  private func refreshGlobalVPN() async {
    print("refreshGlobalVPN")
    await nets.refresh()
  }

  /// While serving as the hub's inviter, mirror every member from
  /// `network/agents/list` into the extension as a WireGuard peer. Members
  /// reach hub-pro and shared ports only through this host, after their
  /// temporary bootstrap peer expires.
  private func startInviterAgentWatcher() {
    guard (try? PacketTunnelController()) != nil,
          (try? PacketTunnelController().installedConfiguration())?.inviterEnabled == true else {
      return
    }
    inviterAgentWatcherTask?.cancel()
    inviterAgentWatcherTask = Task { [weak self] in
      guard let self else { return }
      let hub = self.hub
      hub.state.networkAgents.subscribe(hub: hub)
      var sent: [HubNetworkPeer]?
      while !Task.isCancelled {
        let peers = hub.state.networkAgents.value
          .filter { $0.key != hub.key && !$0.wireGuardKey.isEmpty && !$0.overlayAddresses.isEmpty }
          .map { agent in
            HubNetworkPeer(
              publicKey: agent.wireGuardKey,
              endpoint: "",
              allowedIPs: agent.overlayAddresses.map { $0.contains(":") ? "\($0)/128" : "\($0)/32" }
            )
          }
          .sorted { $0.publicKey < $1.publicKey }
        if peers != sent, (try? await PacketTunnelController().setMemberPeers(peers)) != nil {
          sent = peers
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }
}

enum HubNetError: LocalizedError, Equatable {
  case deviceUnavailable
  case invalidInvitation
  case invalidPort(Int)
  case localAgentUnavailable
  case notJoined
  case nodeNotSet

  var errorDescription: String? {
    switch self {
    case .deviceUnavailable:
      "Selected Hub Network device is no longer available."
    case .invalidInvitation:
      "Hub returned an invalid invitation."
    case .invalidPort(let port):
      "Port \(port) must be between 1 and 65535."
    case .localAgentUnavailable:
      "Local Hub Network agent is not ready to create invitations."
    case .notJoined:
      "Join Hub Network before sharing ports."
    case .nodeNotSet:
      "This Hub has no Hub Network node. An owner has to set one before invitations work."
    }
  }
}
