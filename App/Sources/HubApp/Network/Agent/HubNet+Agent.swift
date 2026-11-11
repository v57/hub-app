//
//  HubNet+Agent.swift
//  Hub
//
//  Hub Network through the hub-net agent, where there's no NetworkExtension (Linux and Windows). The app does the hub's side as on
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

  /// `nil` where Hub Network isn't available
  static var current: HubNetworkBackend? {
#if canImport(NetworkExtension)
    .packetTunnel
#elseif os(Linux) || os(Windows)
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
    let address = hub.settings.address
    if let id = HubNetAgentMemberships.id(for: address), let membership = list.first(where: { $0.id == id }) {
      return membership
    }
    // A membership this app didn't make (the agent's CLI joined, or joined again): the one that reaches this hub
    if let membership = list.first(where: { $0.hubAddress.flatMap(URL.init(string:)) == address }) {
      HubNetAgentMemberships.set(membership.id, for: address)
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
        let invitation = try await requestInvitation()
        // The hub holds a device its machine's agent invited until an owner approves it: an owner signed in here
        // approves the device this agent joins as, the one whose safety code the agent shows
        let approving = Task { await approveAgentDevice(of: invitation, through: agent) }
        defer { approving.cancel() }
        joined = try await agent.join(invitation: invitation)
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

  /// While the agent's join of `invitation` waits for an owner, approves the hub's pending device with the code the
  /// agent shows, when this app may approve devices. The code ties the pending request to this machine's agent: the
  /// hub works it out from the device's key, and the agent from the same key and the hub key it pinned.
  private func approveAgentDevice(of invitation: String, through agent: HubNetDaemon) async {
    guard hub.require(permissions: "hub/device/approve") else { return }
    let subscription = hub.state.pendingDevices.subscribe(hub: hub)
    defer { withExtendedLifetime(subscription) {} }
    while !Task.isCancelled {
      if let code = try? await agent.joinStatus(invitation: invitation),
         let device = hub.state.pendingDevices.value.first(where: { hub.safetyCode(of: $0) == code }) {
        _ = try? await hub.client.devices.approve(device.id)
        return
      }
      try? await Task.sleep(for: .seconds(1))
    }
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
      // The hub may hold this device for an owner's approval: show the code the agent gives to compare
      let status = Task { @MainActor in
        var shown: String?
        while !Task.isCancelled {
          if let code = try? await agent.joinStatus(invitation: invitation.url), code != shown {
            shown = code
            report(.init(transactionId: invitation.replayId, state: .awaitingApproval, approvalCode: code))
          }
          try? await Task.sleep(for: .seconds(1))
        }
      }
      let joined: HubNetDaemon.Joined
      do {
        defer { status.cancel() }
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
