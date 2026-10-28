//
//  HubNet+Agent.swift
//  Hub
//
//  Hub Network through the hub-net agent, where there's no NetworkExtension (Linux). The app does the hub's side as on
//  Apple platforms (the hub's machine issues an invitation, the hub lists the network) and hands the tunnel to the
//  agent: `join` with the invitation, `local` for the hub that runs on this machine, `leave`, and `list` for what this
//  device is on and its address.
//

import Foundation
import HubService

/// Where this device's Hub Network runs
enum HubNetworkBackend: Sendable {
  /// Apple's packet tunnel extension (NetworkExtension, WireGuardKit)
  case packetTunnel
  /// The hub-net agent, a privileged service with kernel WireGuard
  case agent(HubNetDaemon)

  /// `nil` where Hub Network isn't available (Windows, until hub-net runs there)
  static var current: HubNetworkBackend? {
#if canImport(NetworkExtension)
    .packetTunnel
#elseif os(Linux)
    .agent(HubNetDaemon())
#else
    nil
#endif
  }

  var agent: HubNetDaemon? {
    if case .agent(let agent) = self { return agent }
    return nil
  }
}

/// Which of the agent's memberships belongs to which hub: the app notes it when it joins
@MainActor
enum HubNetAgentMemberships {
  private static func key(_ hub: URL) -> String { "HubNet.agent.\(hub.absoluteString)" }

  static func id(for hub: URL) -> String? {
    UserDefaults.standard.string(forKey: key(hub))
  }

  static func set(_ id: String?, for hub: URL) {
    UserDefaults.standard.set(id, forKey: key(hub))
  }
}

extension HubNet {
  /// This hub's membership among the agent's
  func membership(in list: [HubNetDaemon.Membership]) -> HubNetDaemon.Membership? {
    if let id = HubNetAgentMemberships.id(for: hub.settings.address), let membership = list.first(where: { $0.id == id }) {
      return membership
    }
    // The hub on this machine: the agent serves it with `local`, which it may have done from its CLI
    if hub.isOnHubMachine { return list.first { $0.id.hasPrefix("local-") } }
    return nil
  }

  /// Reads the agent's list. An agent that isn't running leaves this device off the network.
  func refresh(from agent: HubNetDaemon) async {
    do {
      apply(agent: membership(in: try await agent.list()))
    } catch {
      print("[HubNet] hub-net agent: \(error)")
      apply(agent: nil)
    }
  }

  /// A session that just started connects to its hub in a few seconds, and only then knows the address the hub
  /// registered it with: read the list until then (half a minute at most)
  func refreshUntilConnected(_ agent: HubNetDaemon) async {
    for _ in 0..<30 {
      await refresh(from: agent)
      guard let membership = agentMembership, membership.status == .starting else { return }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  /// On: the membership the agent keeps comes back; without one the hub's machine invites this device and the
  /// agent joins with the invitation, or for the hub on this machine the agent becomes its network agent. Off: the
  /// agent takes the tunnel down and keeps the membership, as the packet tunnel keeps its profile.
  func joinNetwork(enabled: Bool, through agent: HubNetDaemon) async throws {
    if enabled {
      if let current = membership(in: try await agent.list()) {
        if current.status == .paused { try await agent.setPaused(false, alias: current.alias) }
        await refreshUntilConnected(agent)
        await HubNets.main.refresh()
        return
      }
      let joined: HubNetDaemon.Joined
      if hub.isOnHubMachine {
        // The hub proves its machine's agent over the agent's own socket (/run/hub-net/agent.sock)
        joined = try await agent.local(address: hub.settings.address.absoluteString)
      } else {
        joined = try await agent.join(invitation: try await requestInvitation())
      }
      HubNetAgentMemberships.set(joined.record.id, for: hub.settings.address)
      await refreshUntilConnected(agent)
    } else {
      if let current = membership(in: try await agent.list()) {
        try await agent.setPaused(true, alias: current.alias)
      }
      await refresh(from: agent)
    }
    await HubNets.main.refresh()
  }

  /// Lets the hub's devices use this device's internet (`hub-net vpn allow`), or stops
  func shareNetwork(enabled: Bool, through agent: HubNetDaemon) async throws {
    guard let membership = agentMembership else { throw HubNetError.notJoined }
    try await agent.setGateway(alias: membership.alias, allowed: enabled)
    await refresh(from: agent)
  }

  /// Shares a port with the hub's devices (`hub-net open|close`), TCP and UDP together
  func share(port: UInt16, enabled: Bool, through agent: HubNetDaemon) async throws {
    guard let membership = agentMembership else { throw HubNetError.notJoined }
    try await agent.setPort(port, open: enabled, alias: membership.alias)
    apply(agentPort: Int(port), shared: enabled)
  }

  /// An invitation for another device, from the agent on the hub's machine
  func createInviteCodeThroughAgent() async throws -> String {
    try await requestInvitation()
  }

  /// Asks the hub for an invitation its machine's agent signs (`net/invite`), as an owner inviting a device does
  private func requestInvitation() async throws -> String {
    let subscription = hub.state.hubNetAgents.subscribe(hub: hub)
    defer { withExtendedLifetime(subscription) {} }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while true {
      if let inviter = hub.state.hubNetAgents.value.first(where: { $0.localIp == "127.0.0.1" }) {
        return try await hub.createNetworkInvitation(service: inviter.id)
      }
      guard ContinuousClock.now < deadline else { throw HubNetError.localAgentUnavailable }
      try await Task.sleep(for: .milliseconds(100))
    }
  }
}

extension NativeJoinCoordinator {
  /// The join this platform runs: the packet tunnel's, or the hub-net agent's
  static var current: NativeJoinCoordinator {
    HubNetworkBackend.current?.agent.map(agent) ?? live
  }

  /// Joins through the hub-net agent: it meets the inviting device, enrolls and brings the tunnel up itself. The app
  /// then opens the hub at its address on the network, as after a native join.
  static func agent(_ agent: HubNetDaemon) -> NativeJoinCoordinator {
    NativeJoinCoordinator { invitation, report in
      report(.init(transactionId: invitation.replayId, state: .rendezvous))
      let joined: HubNetDaemon.Joined
      do {
        joined = try await agent.join(invitation: invitation.url)
      } catch HubNetDaemon.Failure.refused(let message) {
        throw NativeJoinError.bootstrapFailed(NativeJoinPresentation.sanitizeCause(message))
      }
      report(.init(transactionId: invitation.replayId, state: .activating))
      guard let address = joined.record.hubAddress.flatMap(URL.init(string:)) else {
        throw NativeJoinError.invalidBootstrapIdentity
      }
      HubNetAgentMemberships.set(joined.record.id, for: address)
      if let stale = Hubs.main.list.first(where: { $0.settings.address == address }) {
        Hubs.main.remove(with: stale.settings)
      }
      let hub = Hubs.main.insert(with: Hub.Settings(name: joined.record.header, address: address))
      // Its page reads the agent again once its session connects
      await hub.net.refresh(from: agent)
      await HubNets.main.refresh()
      return hub
    }
  }
}
