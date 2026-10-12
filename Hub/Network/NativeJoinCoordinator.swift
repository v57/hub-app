import CryptoKit
import Foundation
import HubService

enum NativeJoinProgressState: String, Sendable {
  case validating
  case staging
  case awaitingVPNConsent = "awaiting-vpn-consent"
  case startingTunnel = "starting-tunnel"
  case rendezvous
  case connected
  case binding
  case activating
  case recovering
}

struct NativeJoinProgress: Equatable, Sendable {
  let transactionId: String
  let state: NativeJoinProgressState
}

enum NativeJoinFailureStage: String, Equatable, Sendable {
  case vpnInstall = "VPN installation"
  case tunnelStart = "Tunnel start"
  case readiness = "Extension readiness"
  case providerMessage = "Extension command"
  case rendezvous = "Direct rendezvous"
  case connection = "Hub connection"
  case bind = "Membership bind"
  case activation = "Membership activation"
}

enum NativeJoinError: LocalizedError, Equatable {
  case transactionConflict
  case activeVPNConflict
  case invalidBootstrapIdentity
  case bootstrapFailed(String)
  case bootstrapTimedOut
  case staged(NativeJoinFailureStage, String)

  var errorDescription: String? {
    switch self {
    case .transactionConflict:
      "Another Hub Network join is already in progress."
    case .activeVPNConflict:
      "Disconnect active Hub Network VPN before joining another Hub."
    case .invalidBootstrapIdentity:
      "Hub Network extension returned an invalid bootstrap identity."
    case .bootstrapFailed(let message):
      message
    case .bootstrapTimedOut:
      "Direct Hub Network connection timed out."
    case .staged(let stage, let cause):
      "\(stage.rawValue) failed: \(cause)"
    }
  }
}

@MainActor
struct NativeJoinCoordinator {
  typealias Progress = @MainActor (NativeJoinProgress) -> Void

  var run: @MainActor (DecodedNetworkInvitation, @escaping Progress) async throws -> Hub

  static let live = NativeJoinCoordinator { invitation, report in
    let transactionId = invitation.replayId
    report(.init(transactionId: transactionId, state: .staging))
    let record = try await NativeJoinStore.main.stage(tokenId: transactionId)
    let tunnel = try PacketTunnelController()
    var bootstrapIdentity: PacketTunnelBootstrapIdentity?
    var bindClient: HubClient?
    var bindingRecorded = record.stage != .staged

    do {
      switch await tunnel.status {
      case .connected, .connecting, .reasserting, .disconnecting:
        throw NativeJoinError.activeVPNConflict
      case .invalid:
        throw NativeJoinError.activeVPNConflict
      case .notInstalled, .disconnected:
        break
      }

      report(.init(transactionId: transactionId, state: .awaitingVPNConsent))
      try await classified(.vpnInstall, invitation: invitation, record: record) {
        // The extension reads the device WireGuard identity (wireguard.v1)
        // at adapter start and signs the bootstrap readiness with the device
        // hub identity (identity.v1), requiring both to match the profile's
        // keys. The joiner stages a per-transaction keypair (native-join.v1);
        // install both staged keys as the device identities before the
        // tunnel starts (the owner/local flows create these implicitly via
        // HubNetworkWireGuardKeyStore.publicKeyBase64() / KeyChain.main).
        if let wireGuardData = try await NativeJoinStore.main.wireGuardPrivateKey(
          transactionId: transactionId
        ) {
          try HubNetworkWireGuardKeyStore().install(
            Curve25519.KeyAgreement.PrivateKey(rawRepresentation: wireGuardData)
          )
        }
        if let profileData = try await NativeJoinStore.main.profilePrivateKey(
          transactionId: transactionId
        ) {
          try KeyChain.installHubIdentity(rawRepresentation: profileData)
        }
        try await tunnel.install(
          configuration: bootstrapConfiguration(invitation: invitation, record: record)
        )
      }
      report(.init(transactionId: transactionId, state: .startingTunnel))
      try await classified(.tunnelStart, invitation: invitation, record: record) {
        try await tunnel.start()
      }

      let readiness = try await classified(
        .readiness, invitation: invitation, record: record
      ) { try await tunnel.bootstrapReadiness() }
      guard !readiness.tunnelInstanceId.isEmpty, readiness.generation > 0 else {
        throw NativeJoinError.invalidBootstrapIdentity
      }
      let identity = PacketTunnelBootstrapIdentity(
        tunnelInstanceId: readiness.tunnelInstanceId,
        generation: readiness.generation
      )
      bootstrapIdentity = identity
      let start = nativeStart(
        invitation: invitation, record: record, identity: identity
      )
      var status = try await classified(
        .providerMessage, invitation: invitation, record: record
      ) { try await tunnel.startNativeJoin(start) }
      report(.init(transactionId: transactionId, state: .rendezvous))

      let deadline = ContinuousClock.now + .seconds(35)
      while status.state != .readyToEnroll {
        if status.state == .failed || status.state == .cancelled {
          throw NativeJoinError.staged(
            .rendezvous,
            NativeJoinPresentation.sanitizeCause(
              status.error?.message ?? "Direct connection failed.",
              secrets: Self.secrets(invitation: invitation, record: record)
            )
          )
        }
        guard ContinuousClock.now < deadline else {
          throw NativeJoinError.bootstrapTimedOut
        }
        try await Task.sleep(for: .milliseconds(200))
        status = try await classified(
          .providerMessage, invitation: invitation, record: record
        ) {
          try await tunnel.nativeJoinStatus(
            transactionId: transactionId, identity: identity
          )
        }
      }
      report(.init(transactionId: transactionId, state: .connected))

#if DEBUG
      if let data = try? JSONEncoder().encode(status),
         let json = String(data: data, encoding: .utf8) {
        print("[HN9XX] coordinator status at readyToEnroll: \(json)")
      }
#endif

      guard let hubProHost = status.hubProHost,
            !hubProHost.isEmpty,
            let hubURL = bootstrapHubURL(hubProHost) else {
        throw NativeJoinError.invalidBootstrapIdentity
      }
      report(.init(transactionId: transactionId, state: .binding))
      let enrollment: NativeJoinEnrollment
      if let recorded = record.enrollment {
        report(.init(transactionId: transactionId, state: .recovering))
        enrollment = recorded
        let identityKey = try await NativeJoinStore.main.serviceKey(
          transactionId: transactionId,
          profilePublicKey: record.profilePublicKey
        )
        bindClient = HubClient(hubURL, keyChain: identityKey)
      } else {
        let identityKey = try await NativeJoinStore.main.serviceKey(
          transactionId: transactionId,
          profilePublicKey: record.profilePublicKey
        )
        let client = HubClient(hubURL, keyChain: identityKey)
        bindClient = client
        let binding = try await classified(.bind, invitation: invitation, record: record) {
          try await performBind(client: client, record: record)
        }
        enrollment = NativeJoinEnrollment(
          hubKey: binding.hubKey,
          hubNetworkId: binding.hubNetworkId,
          profile: AgentProfile(
            key: record.profilePublicKey,
            wireGuardKey: record.wireGuardPublicKey,
            name: nil,
            platform: nativePlatform,
            overlayAddresses: binding.overlayAddresses,
            connectedAt: ISO8601DateFormatter.js.string(from: Date())
          )
        )
        _ = try await NativeJoinStore.main.recordEnrollment(
          transactionId: transactionId, enrollment: enrollment
        )
        bindingRecorded = true
      }

      let header: HubHeader = try await classified(
        .connection, invitation: invitation, record: record
      ) {
        guard let bindClient else {
          throw NativeJoinError.invalidBootstrapIdentity
        }
        // hub/header is a STREAM on the TS reference hub-pro; a request/
        // response send to a stream-only path is rejected with an RPC error.
        // Read one stream value instead (the stream is cancelled on return).
        return try await bindClient.oneValue("hub/header", as: HubHeader.self)
      }
      report(.init(transactionId: transactionId, state: .activating))
      let membershipConfiguration = try committedConfiguration(
        hubProHost: hubProHost, record: record, enrollment: enrollment
      )
      try tunnel.stageNativeJoinMembership(configuration: membershipConfiguration)
      let committed = try await classified(
        .activation, invitation: invitation, record: record
      ) {
        try await tunnel.commitNativeJoin(PacketTunnelNativeJoinCommit(
          version: 1,
          transactionId: transactionId,
          tunnelInstanceId: identity.tunnelInstanceId,
          generation: identity.generation,
          key: record.profilePublicKey,
          wireGuardKey: record.wireGuardPublicKey,
          hubNetworkId: enrollment.hubNetworkId,
          overlayAddresses: enrollment.profile.overlayAddresses,
          expiresAt: ISO8601DateFormatter.js.string(from: invitation.expiresAt)
        ))
      }
      guard committed.state == .committed else {
        throw NativeJoinError.staged(
          .activation,
          NativeJoinPresentation.sanitizeCause(
            committed.error?.message ?? "Membership activation was rejected.",
            secrets: Self.secrets(invitation: invitation, record: record)
          )
        )
      }
      try await waitForCommittedTunnel(
        tunnel,
        enrollment: enrollment,
        record: record,
        identity: identity
      )
      let identityTag = "dev.v57.Hub.network.membership.\(record.tokenDigest)"
      try await NativeJoinStore.main.promoteProfileIdentity(
        transactionId: transactionId, keychainTag: identityTag
      )
      let hub = Hubs.main.insert(with: Hub.Settings(
        name: header.name, address: hubURL, identityTag: identityTag
      ))
      guard hub.settings.identityTag == identityTag,
            Hubs.main.selectedHub === hub else {
        throw NativeJoinError.invalidBootstrapIdentity
      }
      try await waitForHubConnection(hub)
      bindClient?.stop()
      bindClient = nil
      _ = try await NativeJoinStore.main.markCommitted(transactionId: transactionId)
      try await NativeJoinStore.main.cleanup(transactionId: transactionId)
      return hub
    } catch {
      await rollback(
        transactionId: transactionId,
        tunnel: tunnel,
        identity: bootstrapIdentity,
        bindClient: bindClient,
        preserveEnrollment: bindingRecorded
      )
      throw error
    }
  }

  /// Cleanup is deliberately best-effort: original join failure remains visible.
  private static func rollback(
    transactionId: String,
    tunnel: PacketTunnelController,
    identity: PacketTunnelBootstrapIdentity?,
    bindClient: HubClient?,
    preserveEnrollment: Bool
  ) async {
    if let identity {
      let cancel = PacketTunnelNativeJoinCancel(
        version: 1,
        transactionId: transactionId,
        tunnelInstanceId: identity.tunnelInstanceId,
        generation: identity.generation,
        reason: preserveEnrollment ? "recoverable-incomplete-join" : "join-rollback"
      )
      _ = try? await tunnel.cancelNativeJoin(cancel)
    }
    bindClient?.stop()
    if !preserveEnrollment {
      try? await tunnel.remove()
      try? await NativeJoinStore.main.cleanup(transactionId: transactionId)
    }
  }

  private static func performBind(
    client: HubClient,
    record: NativeJoinRecord
  ) async throws -> (hubKey: String, hubNetworkId: String, overlayAddresses: [String]) {
    let registration: HubNetworkAgentRegistrationResponse = try await client.send(
      "hub/net/bind",
      HubNetworkAgentRegistration(
        bindingKind: .join,
        wireGuardKey: record.wireGuardPublicKey,
        name: "Hub App",
        overlayAddresses: [],
        connectedAt: ISO8601DateFormatter.js.string(from: Date())
      )
    )
    // hub-pro returns profile.key in the canonical SPKI form (the auth
    // header key it verified at upgrade); the staged record stores the raw
    // 32-byte form. Normalize before comparing — pitfall #12, 5th site.
    let expectedProfileKey =
      KeyChain.spkiPublicKey(rawBase64: record.profilePublicKey) ?? record.profilePublicKey
    guard registration.success,
          registration.profile.key == expectedProfileKey,
          registration.profile.wireGuardKey == record.wireGuardPublicKey,
          let ipv4 = registration.profile.overlayAddresses.first(where: { !$0.contains(":") }),
          let ipv6 = registration.profile.overlayAddresses.first(where: { $0.contains(":") }) else {
      throw NativeJoinError.invalidBootstrapIdentity
    }
    return (
      registration.hubKey,
      registration.hubNetworkId,
      [ipv4, ipv6]
    )
  }

  private static func classified<T>(
    _ stage: NativeJoinFailureStage,
    invitation: DecodedNetworkInvitation,
    record: NativeJoinRecord,
    operation: () async throws -> T
  ) async throws -> T {
    do {
      return try await operation()
    } catch let error as NativeJoinError {
      throw error
    } catch {
      throw NativeJoinError.staged(
        stage,
        NativeJoinPresentation.sanitizeCause(
          error.localizedDescription,
          secrets: secrets(invitation: invitation, record: record)
        )
      )
    }
  }

  private static func secrets(
    invitation: DecodedNetworkInvitation,
    record: NativeJoinRecord
  ) -> [String] {
    [
      invitation.code, invitation.replayId, record.transactionId,
      record.profilePublicKey, record.wireGuardPublicKey,
    ]
  }

  private static func bootstrapConfiguration(
    invitation: DecodedNetworkInvitation,
    record: NativeJoinRecord
  ) throws -> HubNetworkProfileConfiguration {
    guard let hubURL = bootstrapHubURL(invitation.node) else {
      throw NetworkInvitationError(
        code: .malformed, message: "invitation hub-pro address is invalid"
      )
    }
    // The node lives on the inviter's host. If its endpoint is a Tailscale /
    // CGNAT address inside the frozen overlay prefix (100.96.0.0/11), the
    // bootstrap tunnel would route the rendezvous probe back into the tunnel.
    // Exclude the node's host IP from the tunnel so the probe reaches the node
    // directly over the physical network.
    let controlPlaneIPv4 = HubNetworkNodeEndpoint.ipv4Host(from: invitation.node)
      .map { [$0] } ?? []
    return HubNetworkProfileConfiguration(
      hubURL: hubURL,
      hubNetworkID: record.transactionId,
      profilePublicKey: record.profilePublicKey,
      overlayIPv4Address: "100.127.254.10/32",
      overlayIPv6Address: "fd48:5542:4e45:fffe::10/128",
      trustedHubKey: invitation.agentKey,
      wireGuardPublicKey: record.wireGuardPublicKey,
      controlPlaneIPv4Hosts: controlPlaneIPv4,
      controlPlaneIPv6Hosts: []
    )
  }

  private static func nativeStart(
    invitation: DecodedNetworkInvitation,
    record: NativeJoinRecord,
    identity: PacketTunnelBootstrapIdentity
  ) -> PacketTunnelNativeJoinStart {
    PacketTunnelNativeJoinStart(
      version: 1, invitationCode: invitation.code,
      replayId: invitation.replayId, transactionId: record.transactionId,
      invitingKey: invitation.agentKey, node: invitation.node,
      key: record.profilePublicKey,
      wireGuardKey: record.wireGuardPublicKey,
      tunnelInstanceId: identity.tunnelInstanceId,
      generation: identity.generation,
      expiresAt: ISO8601DateFormatter.js.string(from: invitation.expiresAt)
    )
  }

  private static func committedConfiguration(
    hubProHost: String,
    record: NativeJoinRecord,
    enrollment: NativeJoinEnrollment
  ) throws -> HubNetworkProfileConfiguration {
    guard let hubURL = bootstrapHubURL(hubProHost),
          let ipv4 = enrollment.profile.overlayAddresses.first(where: { !$0.contains(":") }),
          let ipv6 = enrollment.profile.overlayAddresses.first(where: { $0.contains(":") }) else {
      throw NativeJoinError.invalidBootstrapIdentity
    }
    return HubNetworkProfileConfiguration(
      hubURL: hubURL,
      hubNetworkID: enrollment.hubNetworkId,
      profilePublicKey: record.profilePublicKey,
      overlayIPv4Address: "\(ipv4)/32",
      overlayIPv6Address: "\(ipv6)/128",
      trustedHubKey: enrollment.hubKey,
      wireGuardPublicKey: record.wireGuardPublicKey,
      controlPlaneIPv4Hosts: [],
      controlPlaneIPv6Hosts: []
    )
  }

  private static func waitForHubConnection(_ hub: Hub) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !hub.isConnected {
      guard ContinuousClock.now < deadline else {
        throw NativeJoinError.bootstrapTimedOut
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private static func waitForCommittedTunnel(
    _ tunnel: PacketTunnelController,
    enrollment: NativeJoinEnrollment,
    record: NativeJoinRecord,
    identity: PacketTunnelBootstrapIdentity
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if await tunnel.status == .connected,
         let readiness = try? await tunnel.bootstrapReadiness(),
         readiness.hubNetworkId == enrollment.hubNetworkId,
         readiness.wireGuardKey == record.wireGuardPublicKey,
         readiness.tunnelInstanceId == identity.tunnelInstanceId,
         readiness.generation == identity.generation {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeJoinError.bootstrapTimedOut
  }

  /// Derives the hub-pro URL (port 1997 on the same host) from a node
  /// endpoint or inviter host value. Accepts bare hosts ("100.96.0.3"),
  /// host:port, and full URLs ("ws://mac.local:1964"). Plain (non-TLS)
  /// hub-pro is the default — wss only when the endpoint itself is
  /// wss/https (TLS-terminating proxy deployment).
  private static func bootstrapHubURL(_ node: String) -> URL? {
    let value = node.trimmingCharacters(in: .whitespaces)
    let secure = value.hasPrefix("wss://") || value.hasPrefix("https://")
    guard let host = HubNetworkNodeEndpoint.host(from: value), !host.isEmpty else {
      return nil
    }
    let bracketed = host.contains(":") ? "[\(host)]" : host
    return URL(string: "\(secure ? "wss" : "ws")://\(bracketed):1997")
  }

  private static var nativePlatform: String {
#if os(macOS)
    "macos"
#elseif os(iOS)
    "ios"
#else
    "apple"
#endif
  }
}

private struct HubNetworkAgentRegistration: Encodable {
  let version = 1
  let bindingKind: HubNetworkLocalAgentBindingKind
  let wireGuardKey: String
  let name: String
  let platform = "macOS"
  let overlayAddresses: [String]
  let connectedAt: String
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
