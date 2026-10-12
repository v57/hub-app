import Foundation
import HubService

private struct HubNetworkAgentRegistration: Encodable {
  let version = 1
  let bindingKind: HubNetworkLocalAgentBindingKind
  let wireGuardKey: String
  let name: String
  let platform = "macOS"
  let overlayAddresses: [String]
  let connectedAt: String
}

private struct HubNetworkGrantRequest: Encodable {
  let callerWireGuardKey: String
  let resourceId: String
  let preferredProviderId: String
}

private struct HubNetworkAgentRegistrationResponse: Decodable {
  struct Profile: Decodable {
    let key: String
    let wireGuardKey: String
    let overlayAddresses: [String]
  }

  let success: Bool
  let profile: Profile
  let hubKey: String
  let hubNetworkId: String
}

private struct HubNetworkGrantResponse: Decodable {
  let grant: ConnectionGrant
}

extension PacketTunnelController {
  /// Restores server-side registration for an already-installed profile.
  ///
  /// hub-pro may restart while NetworkExtension state remains installed. Any
  /// capability mutation must recreate and verify that ephemeral registration
  /// before using it.
  func restoreInstalledLocalMembership(hub: Hub) async throws {
    print("restoreInstalledLocalMembership")
    // No installed profile (first join, or the profile was dropped) is not an
    // error — fall back to a fresh authorize-and-install below.
    let current: HubNetworkProfileConfiguration
    do {
      current = try installedConfigurationForMigration()
      try current.validate()
    } catch {
      try await authorizeAndInstallLocalHub(hub: hub)
      return
    }
    guard current.profilePublicKey == hub.key,
          let currentWireGuardKey = current.wireGuardPublicKey else {
      try await authorizeAndInstallLocalHub(hub: hub)
      return
    }
    let wireGuardKey = try HubNetworkWireGuardKeyStore().publicKeyBase64()
    guard wireGuardKey == currentWireGuardKey else {
      try await authorizeAndInstallLocalHub(hub: hub)
      return
    }

    let registration = try await registerLocalMembership(
      hub: hub,
      wireGuardKey: wireGuardKey
    )
    guard registration.hubNetworkId == current.hubNetworkID,
          registration.hubKey == current.trustedHubKey,
          "\(registration.ipv4)/32" == current.overlayIPv4Address,
          "\(registration.ipv6)/128" == current.overlayIPv6Address else {
      try await authorizeAndInstallLocalHub(hub: hub)
      return
    }
    // Refresh the online-inviter intent on the persisted profile: the node
    // endpoint is only known once the owner sets it, which happens after the
    // profile may have been installed. Re-saving with the flags set lets the
    // extension start the inviter on the next tunnel activation.
    let nodeEndpoint = HubService.Group.HubNetworkNodeEndpointStore.shared.current()
    let controlPlaneIPv4 = HubNetworkNodeEndpoint.ipv4Host(from: nodeEndpoint)
      .map { [$0] } ?? (current.controlPlaneIPv4Hosts ?? [])
    if current.inviterEnabled != !nodeEndpoint.isEmpty || current.nodeEndpoint != (nodeEndpoint.isEmpty ? nil : nodeEndpoint) || current.controlPlaneIPv4Hosts != controlPlaneIPv4 {
      try await install(
        configuration: HubNetworkProfileConfiguration(
          version: current.version,
          hubURL: current.hubURL,
          hubNetworkID: current.hubNetworkID,
          profilePublicKey: current.profilePublicKey,
          overlayIPv4Address: current.overlayIPv4Address,
          overlayIPv6Address: current.overlayIPv6Address,
          dnsSuffix: current.dnsSuffix,
          overlayIPv4Route: current.overlayIPv4Route,
          overlayIPv6Route: current.overlayIPv6Route,
          dnsRecords: current.dnsRecords ?? [],
          dnsServerAddress: current.dnsServerAddress,
          trustedHubKey: current.trustedHubKey,
          wireGuardPublicKey: current.wireGuardPublicKey,
          connectionGrant: current.connectionGrant,
          gatewayGrant: current.gatewayGrant,
          peerEndpoint: current.peerEndpoint,
          controlPlaneIPv4Hosts: controlPlaneIPv4,
          controlPlaneIPv6Hosts: current.controlPlaneIPv6Hosts ?? [],
          gatewayServingEnabled: current.servesGateway,
          servesInviter: !nodeEndpoint.isEmpty,
          nodeEndpoint: nodeEndpoint.isEmpty ? nil : nodeEndpoint
        )
      )
      // Stop so the caller's `start()` re-activates the updated profile in the
      // extension (an already-connected tunnel would otherwise keep the old
      // configuration, leaving the inviter off).
      await stop()
    }
  }

  /// Registers and installs current Hub as an overlay-only membership.
  ///
  /// No resource peer, gateway route, forwarding, or NAT is enabled. Later
  /// resource or gateway selection may replace this base profile with a
  /// purpose-bound peer configuration.
  func authorizeAndInstallLocalHub(hub: Hub) async throws {
    print("authorizeAndInstallLocalHub")
    let wireGuardKey = try HubNetworkWireGuardKeyStore().publicKeyBase64()
    let registration = try await registerLocalMembership(hub: hub, wireGuardKey: wireGuardKey)
    let nodeEndpoint = HubService.Group.HubNetworkNodeEndpointStore.shared.current()
    let controlPlaneIPv4 = HubNetworkNodeEndpoint.ipv4Host(from: nodeEndpoint)
      .map { [$0] } ?? []
    try await install(
      configuration: HubNetworkProfileConfiguration(
        hubURL: hub.settings.address,
        hubNetworkID: registration.hubNetworkId,
        profilePublicKey: hub.key,
        overlayIPv4Address: "\(registration.ipv4)/32",
        overlayIPv6Address: "\(registration.ipv6)/128",
        trustedHubKey: registration.hubKey,
        wireGuardPublicKey: wireGuardKey,
        controlPlaneIPv4Hosts: controlPlaneIPv4,
        servesInviter: !nodeEndpoint.isEmpty,
        nodeEndpoint: nodeEndpoint.isEmpty ? nil : nodeEndpoint
      )
    )
  }

  /// Registers Hub app as app-scoped network principal, obtains and validates
  /// one resource grant, then atomically installs extension configuration.
  ///
  /// Hub registration response travels over existing authenticated Hub
  /// channel and supplies stable allocated addresses plus signing trust root.
  /// Grant self-declared trust material is never accepted.
  func authorizeAndInstall(
    hub: Hub,
    resource: HubNetworkResource,
    provider: HubNetworkProvider,
    peerEndpoint: String
  ) async throws {
    guard provider.resourceId == resource.resourceId else {
      throw PacketTunnelActivationError.invalidProvisioning
    }

    let wireGuardKey = try HubNetworkWireGuardKeyStore().publicKeyBase64()
    let registration = try await registerLocalMembership(
      hub: hub,
      wireGuardKey: wireGuardKey
    )

    let response: HubNetworkGrantResponse = try await hub.client.send(
      "network/connection/grant",
      HubNetworkGrantRequest(
        callerWireGuardKey: wireGuardKey,
        resourceId: resource.resourceId,
        preferredProviderId: provider.providerId
      )
    )
    let grant = response.grant
    guard let generation = UInt64(exactly: resource.generation) else {
      throw PacketTunnelActivationError.invalidProvisioning
    }
    try HubNetworkSignedEnvelope.validateConnectionGrant(
      grant,
      binding: ConnectionGrantBinding(
        trustedHubKey: registration.hubKey,
        hubNetworkId: registration.hubNetworkId,
        callerKey: hub.key,
        callerWireGuardKey: wireGuardKey,
        generation: generation
      )
    )
    guard grant.providerId == provider.providerId,
          grant.resourceId == resource.resourceId,
          grant.destinationAddress == provider.overlayAddress,
          grant.destinationPort == provider.port else {
      throw PacketTunnelActivationError.providerBindingMismatch
    }

    try await install(
      configuration: HubNetworkProfileConfiguration(
        hubURL: hub.settings.address,
        hubNetworkID: registration.hubNetworkId,
        profilePublicKey: hub.key,
        overlayIPv4Address: "\(registration.ipv4)/32",
        overlayIPv6Address: "\(registration.ipv6)/128",
        dnsRecords: [
          HubNetworkDNSRecord(
            authority: resource.authority,
            address: provider.overlayAddress
          )
        ],
        trustedHubKey: registration.hubKey,
        wireGuardPublicKey: wireGuardKey,
        connectionGrant: grant,
        peerEndpoint: peerEndpoint
      )
    )
  }

  private func registerLocalMembership(
    hub: Hub,
    wireGuardKey: String
  ) async throws -> (
    hubKey: String,
    hubNetworkId: String,
    ipv4: String,
    ipv6: String
  ) {
    let registration: HubNetworkAgentRegistrationResponse = try await hub.client.send(
      "hub/net/bind",
      HubNetworkAgentRegistration(
        bindingKind: .appleApp,
        wireGuardKey: wireGuardKey,
        name: "Hub App",
        overlayAddresses: [],
        connectedAt: ISO8601DateFormatter.js.string(from: Date())
      )
    )
    guard registration.success,
          registration.profile.key == hub.key,
          registration.profile.wireGuardKey == wireGuardKey,
          let ipv4 = registration.profile.overlayAddresses.first(
            where: { !$0.contains(":") }
          ),
          let ipv6 = registration.profile.overlayAddresses.first(
            where: { $0.contains(":") }
          ) else {
      throw PacketTunnelActivationError.invalidProvisioning
    }
    return (
      registration.hubKey,
      registration.hubNetworkId,
      ipv4,
      ipv6
    )
  }
}

enum PacketTunnelActivationError: Error, Equatable {
  case invalidProvisioning
  case providerBindingMismatch
}

extension PacketTunnelActivationError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidProvisioning:
      "Hub Network registration does not match this App profile."
    case .providerBindingMismatch:
      "Hub Network provider binding is invalid."
    }
  }
}
