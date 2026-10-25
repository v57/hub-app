import Foundation
import Channel
import HubService
import Network
import NetworkExtension
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

  /// Reset Data: the tunnel and its profile are gone
  func reset() {
    vpn = false
    joinProgress = nil
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
  private var linksWatcherTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  @ObservationIgnored private var tunnelObserver: NSObjectProtocol?
  @ObservationIgnored private var tunnelWasConnected = false
  @ObservationIgnored private var registration: Task<Void, Error>?
  /// A restore runs to its end: what it does (saving the profile, restarting the tunnel) would start it again
  @ObservationIgnored private var isRestoring = false

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
    // A tunnel that comes up after the hub's connection (started from Settings, back after a rebuild or a wake)
    // finds the hub without its registration: restore it then too
    tunnelObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: nil, queue: .main
    ) { [weak self] notification in
      let status = (notification.object as? NEVPNConnection)?.status
      MainActor.assumeIsolated {
        guard let self else { return }
        // Only the change to connected: saving a profile posts the same status again and again
        let wasConnected = self.tunnelWasConnected
        self.tunnelWasConnected = status == .connected
        guard status == .connected, !wasConnected, self.hub.isConnected, !self.isRestoring else { return }
        self.reconnectTask = Task { [weak self] in await self?.restoreAfterConnecting() }
      }
    }
  }

  /// `node`: the hub's node when the caller just set it, since `hub/net/node` may not have streamed it back yet
  func joinNetwork(enabled: Bool, node: String? = nil) async throws {
    let tunnel = try PacketTunnelController()
    if enabled {
      // The profile saves whether this device serves invitations, which needs the hub's node: learn it first, or a
      // device that joins right after its owner sets the node never registers its inviter
      var node = node
      if node == nil { node = await Self.currentNodeEndpoint(hub: hub, timeout: .seconds(2)) }
      if let node {
        HubService.Group.HubNetworkNodeEndpointStore.shared.set(node)
      }
      if await tunnel.status == .notInstalled {
        try await tunnel.authorizeAndInstallLocalHub(hub: hub)
      } else {
        // The same one-at-a-time registration a reconnect and the agent use
        try await registerAgain(tunnel: tunnel)
      }
      try await tunnel.start()
      if hub.isOnHubMachine {
        hub.networkAppAgent.enable(tunnel: tunnel)
      }
      try refreshAddress(from: tunnel)
      isJoined = true
      await refreshGlobalVPN()
      startInviterAgentWatcher()
      startLinksWatcher()
      print("done")
    } else {
      inviterAgentWatcherTask?.cancel()
      inviterAgentWatcherTask = nil
      linksWatcherTask?.cancel()
      linksWatcherTask = nil
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
    // misleading `unavailable` state. Nor may a device away from the hub's
    // machine: the hub's agent runs where the hub runs.
    if hub.api.contains("hub/net/apple-agent/bind"), hub.isOnHubMachine {
      hub.networkAppAgent.enable(tunnel: tunnel)
    }
    address = Self.address(from: profile)
    isJoined = true
    isSharing = profile.servesGateway
    if profile.usesGateway {
      vpn = devices.first { $0.key == profile.gatewayGrant?.gatewayKey }
    }
    await refreshGlobalVPN()
    // After a relaunch the inviter still has to mirror members into the extension
    startInviterAgentWatcher()
    startLinksWatcher()
  }

  func connectionChanged(_ connected: Bool) {
    guard connected else {
      reconnectTask?.cancel()
      hub.networkAppAgent.channelConnectionChanged(false)
      return
    }
    reconnectTask = Task { [weak self] in await self?.restoreAfterConnecting() }
  }

  /// The hub forgets a member when its connection drops, hub-server and HubServer alike: its registration, its agent
  /// binding and the internet it offers. Each new connection binds them again, the registration before the agent.
  private func restoreAfterConnecting() async {
    guard !isRestoring else { return }
    isRestoring = true
    defer {
      isRestoring = false
      hub.networkAppAgent.channelConnectionChanged(true)
    }
    guard let tunnel = try? PacketTunnelController(),
          let profile = try? tunnel.installedConfiguration(),
          profile.hubURL == hub.settings.address,
          await tunnel.status == .connected else {
      print("[HubNet] connected: no tunnel up for \(hub.settings.name)")
      return
    }
    print("[HubNet] connected: registering on \(hub.settings.name) again")
    do {
      try await registerAgain(tunnel: tunnel)
    } catch {
      print("HubNet: couldn't register on the hub again:", error)
      return
    }
    guard !Task.isCancelled else { return }
    await restoreIfActive()
    print("[HubNet] restored: joined=\(isJoined) sharing=\(isSharing)")
    if isSharing {
      do {
        try await GatewayServingController().advertise(hub: hub)
      } catch {
        print("HubNet: couldn't offer this device's internet again:", error)
      }
    }
  }

  /// Registers this device's membership on the hub again (it forgets it with each connection), keeping the profile's
  /// inviter: that follows the coordinator, which only joining used to learn, so learn it first.
  /// One at a time: a reconnect, the agent and a page may all ask at once, and parallel installs of the VPN
  /// configuration fail as stale and stop each other's tunnel. A caller that comes during one waits for it.
  func registerAgain(tunnel: PacketTunnelController) async throws {
    if let registration {
      try await registration.value
      return
    }
    let task = Task { @MainActor [hub] in
      if let node = await Self.currentNodeEndpoint(hub: hub, timeout: .seconds(3)) {
        HubService.Group.HubNetworkNodeEndpointStore.shared.set(node)
      }
      try await tunnel.restoreInstalledLocalMembership(hub: hub)
      // It stops the tunnel when the profile had to change: start it with the new one
      if await tunnel.status != .connected { try await tunnel.start() }
    }
    registration = task
    defer { registration = nil }
    try await task.value
  }

  func apiCapabilitiesChanged() {
    // The bind API can arrive after the connection: the hub's machine starts its agent then
    if isJoined, hub.isOnHubMachine, hub.api.contains("hub/net/apple-agent/bind"),
       hub.networkAppAgent.state == .disabled, let tunnel = try? PacketTunnelController() {
      hub.networkAppAgent.enable(tunnel: tunnel)
    }
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

  /// The node `hub/net/node` names (v57.dev's by default), `nil` from a hub older than that default with none set
  private static func currentNodeEndpoint(hub: Hub, timeout: Duration = .seconds(5)) async -> String? {
    hub.state.hubNetNode.subscribe(hub: hub)
    let deadline = ContinuousClock.now.advanced(by: timeout)
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
    // A joined device's inviter registers with the node its profile names: apply the new one to the running tunnel.
    // Clearing it goes back to the default.
    let applied = endpoint?.isEmpty == false ? endpoint ?? HubNetworkNodeEndpoint.default : HubNetworkNodeEndpoint.default
    guard isJoined, applied != HubService.Group.HubNetworkNodeEndpointStore.shared.current() else { return }
    try await joinNetwork(enabled: true, node: applied)
  }

  private func refreshGlobalVPN() async {
    print("refreshGlobalVPN")
    await nets.refresh()
  }

  /// Forwards `network/links` to the extension while joined: the grants that let this device link to the hub's machine
  /// directly, and where to meet it. The extension keeps them, so it can link from a network where the hub itself is
  /// out of reach.
  private func startLinksWatcher() {
    linksWatcherTask?.cancel()
    linksWatcherTask = Task { [weak self] in
      guard let hub = self?.hub else { return }
      var sent: HubNetworkPeerLinks?
      while !Task.isCancelled {
        do {
          for try await links: HubNetworkPeerLinks in hub.client.values("network/links") {
            // The tunnel may still be starting: retry until it takes them
            for _ in 0..<10 where links != sent {
              if (try? await PacketTunnelController().setLinks(links)) != nil {
                sent = links
                break
              }
              try? await Task.sleep(for: .seconds(2))
            }
          }
        } catch {
          print("network/links: \(error)")
        }
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  /// While serving as the hub's inviter, mirror every member from
  /// `network/agents/list` into the extension as a WireGuard peer. Members
  /// reach hub-server and shared ports only through this host, after their
  /// temporary bootstrap peer expires.
  private func startInviterAgentWatcher() {
    // The inviter takes joiners through, a gateway answers its clients: both need every member as a peer
    guard (try? PacketTunnelController()) != nil,
          let profile = try? PacketTunnelController().installedConfiguration(),
          profile.inviterEnabled || profile.servesGateway else {
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

extension Hub {
  /// True when this app runs on the hub's machine (the hub this app runs, or a hub-server beside it), the only place
  /// the hub's Hub Network agent can be: the Hub app there stands in for hub-net. Elsewhere a device only joins.
  var isOnHubMachine: Bool {
    guard let host = settings.address.host()?.lowercased() else { return false }
    return host == "127.0.0.1" || host == "localhost" || host == "::1"
  }
}
