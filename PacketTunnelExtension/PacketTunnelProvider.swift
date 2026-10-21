//
//  PacketTunnelProvider.swift
//  PacketTunnelExtension
//
//  Created by Dmitry on 27.07.26.
//

import NetworkExtension
import HubService
import Channel
import CryptoKit

/// Temporary diagnostics shared by the inviter and joiner paths: appends one
/// line to `hn9xx-diag.log` in the app group container AND keeps an in-memory
/// buffer the app can pull over provider IPC (the macOS extension's container
/// writes land in a persona-scoped path the app cannot read, and its
/// NSLog/stdout is not captured — the IPC pull is the reliable channel).
/// The acceptance reads it after a failure (extension stderr is not bridged
/// by devicectl --console on iOS; the inviter's macOS extension writes land
/// in the Mac's app group).
func extensionDiagnostics(_ line: String) {
  let stamp = ISO8601DateFormatter().string(from: Date())
  let entry = "[\(stamp)] \(line)"
  extensionDiagnosticsBuffer.append(entry)
  if extensionDiagnosticsBuffer.count > 200 {
    extensionDiagnosticsBuffer.removeFirst(extensionDiagnosticsBuffer.count - 200)
  }
  guard let container = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.dev.v57.hub") else {
    return
  }
  let url = container.appendingPathComponent("hn9xx-diag.log", isDirectory: false)
  if let existing = try? String(contentsOf: url, encoding: .utf8) {
    try? (existing + entry + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
  } else {
    try? (entry + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
  }
}

/// In-memory diag buffer, pulled by the app via the "hn9xx-diag" provider
/// message (see `PacketTunnelProvider.handleAppMessage`).
nonisolated(unsafe) var extensionDiagnosticsBuffer: [String] = []

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private lazy var wireGuardAdapter = PacketTunnelWireGuardAdapter(provider: self)
  private var dnsListener: LocalReservedDNSListener?
  private var gatewayServingState = GatewayServingState.disabled
  private var gatewayExpiryTask: Task<Void, Never>?
  private var exitState = ExitState.disabled
  private var bootstrapIdentity = (tunnelInstanceId: UUID().uuidString, generation: UInt64(1))
  private var activeBootstrapProfile: Profile?
  private var nativeJoinStarts: [String: ExtensionNativeJoinStart] = [:]
  private var nativeJoinStatuses: [String: ExtensionNativeJoinStatus] = [:]
  private var nativeJoinTasks: [String: Task<Void, Never>] = [:]
  private var nativeJoinExpiryTasks: [String: Task<Void, Never>] = [:]
  private var nativeJoinClients: [String: InvitationBootstrapClient] = [:]
  private var inviterListener: InviterBootstrapListener?
  /// Reachable IPv4 advertised for the inviter's HUBB listener and WireGuard
  /// endpoints (see `ReachableAddress`); nil falls back to 0.0.0.0.
  private var inviterAdvertiseAddress: String?
  private var inviterNodeClient: InviterNodeClient?
  private var inviter: Inviter?
  private var inviterSweepTask: Task<Void, Never>?
  private var inviterRegistered = false

  override func startTunnel(options: [String: NSObject]?) async throws {
    bootstrapIdentity = (UUID().uuidString, bootstrapIdentity.generation + 1)
    reset()
    do {
      let profile = try Profile.decode()
      Self.writeDiagnostics("startTunnel: profile decoded")
      gatewayServingState = profile.servesGateway ? .enabling : .disabled
      if profile.usesGateway {
        exitState = .blocking
        try await setTunnelNetworkSettings(Self.killSwitchSettings(for: profile))
      } else {
        try profile.validate()
        Self.writeDiagnostics("startTunnel: profile validated")
      }
      try await startValidatedTunnel(profile)
    } catch {
      gatewayServingState = .unavailable
      exitState = .blocking
      Self.writeDiagnostics("startTunnel failed: \(error)")
      throw error
    }
  }

  private func startValidatedTunnel(_ profile: Profile) async throws {
    do {
      try profile.validate()
      Self.writeDiagnostics("adapter start begin")
      try await wireGuardAdapter.start(profile: profile)
      Self.writeDiagnostics("adapter started")
      let dnsServer: Address
      if let remoteDNS = profile.dnsServerAddress {
        dnsServer = try Address(remoteDNS)
      } else {
        let listener = try LocalReservedDNSListener(profile: profile)
        try listener.start()
        dnsListener = listener
        dnsServer = listener.address
      }
      Self.writeDiagnostics("dns listener ready")
      try await setTunnelNetworkSettings(Self.networkSettings(for: profile, dnsServer: dnsServer))
      Self.writeDiagnostics("network settings applied")
      gatewayServingState = profile.servesGateway ? .available : .disabled
      exitState = profile.usesGateway ? .connected : .disabled
      activeBootstrapProfile = profile
      if profile.usesGateway {
        scheduleGatewayHealth(profile)
      }
      if profile.inviterEnabled {
        startInviter(profile: profile)
      }
    } catch {
      gatewayServingState = profile.servesGateway ? .unavailable : .disabled
      await wireGuardAdapter.stop()
      if profile.usesGateway {
        exitState = .blocking
        try? await setTunnelNetworkSettings(Self.killSwitchSettings(for: profile))
      } else {
        Self.writeDiagnostics("startValidatedTunnel failed: \(error)")
        throw error
      }
    }
  }

  /// Temporary diagnostics: the app's acceptance reads this file after a
  /// tunnel-start failure (the extension's stderr is not visible to
  /// devicectl --console on iOS). Shared by the inviter paths on macOS.
  private static func writeDiagnostics(_ line: String) {
    extensionDiagnostics(line)
  }

  override func stopTunnel(with reason: NEProviderStopReason) async {
    gatewayServingState = .disabled
    gatewayExpiryTask?.cancel()
    gatewayExpiryTask = nil
    exitState = .disabled
    reset()
    dnsListener?.stop()
    dnsListener = nil
    await wireGuardAdapter.stop()
    try? await setTunnelNetworkSettings(nil)
  }
  
  private func reset() {
    nativeJoinStarts.removeAll()
    nativeJoinStatuses.removeAll()
    nativeJoinTasks.values.forEach { $0.cancel() }
    nativeJoinTasks.removeAll()
    nativeJoinExpiryTasks.values.forEach { $0.cancel() }
    nativeJoinExpiryTasks.removeAll()
    nativeJoinClients.values.forEach { $0.close() }
    nativeJoinClients.removeAll()
    activeBootstrapProfile = nil
    stopInviter()
  }

  // MARK: Inviter

  private func startInviter(profile: Profile) {
    guard inviter == nil else { return }
    let identity: KeyChain
    do {
      identity = try KeyChain.hubIdentity()
    } catch {
      return
    }
    guard let overlayIPv4 = profile.overlayIPv4Address.split(separator: "/").first.map(String.init) else {
      return
    }
    // The HUBB listener binds INADDR_ANY, so its socket address is not
    // routable by remote joiners. Advertise the host's primary non-loopback
    // IPv4 (mirrors the Go inviter's -advertise-address semantics; the
    // Tailscale CGNAT/overlay range is skipped so candidates do not loop
    // through the tunnel).
    let advertiseAddress = ReachableAddress.primaryIPv4()
    inviterAdvertiseAddress = advertiseAddress
    let inviter = Inviter(
      identity: identity,
      wireGuardPublicKey: profile.wireGuardPublicKey ?? "",
      installPeer: { [weak self] publicKey, allowedIPs, _ in
        guard let self else { return }
        try await self.wireGuardAdapter.installInviterPeer(
          assignmentId: "inviter-" + String(publicKey.prefix(16)),
          publicKeyBase64: publicKey,
          allowedIPs: allowedIPs
        )
      },
      removePeer: { [weak self] publicKey in
        guard let self else { return }
        try await self.wireGuardAdapter.removeBootstrapPeer(
          assignmentId: "inviter-" + String(publicKey.prefix(16))
        )
      },
      hubProHost: { overlayIPv4 },
      endpoints: { [weak self] in
        guard let self else { return [] }
        // Parity with the Go inviter (hub-net/agent): the signed response
        // advertises the WireGuard listen port on the advertised address so
        // the joiner's temporary-link handshake reaches the adapter's socket.
        guard let port = await self.wireGuardAdapter.listenPort() else { return [] }
        return [BootstrapEndpoint(
          address: advertiseAddress ?? "0.0.0.0",
          port: port,
          transport: "udp"
        )]
      }
    )
    self.inviter = inviter

    let listener: InviterBootstrapListener
    do {
      listener = try InviterBootstrapListener { [weak self] request in
        guard let self, let inviter = self.inviter else {
          throw InviterError.internalError("inviter unavailable")
        }
        return try await inviter.handle(request)
      }
    } catch {
      return
    }
    inviterListener = listener
    let listenerEndpoint = listener.start()

    // Register with the node hub-pro names (hub/net/node), which invitations
    // carry in ?e=. A node address inside the overlay range (Tailscale) is
    // excluded from the tunnel through controlPlaneIPv4Hosts.
    // There is no default node: without one the inviter can't register
    guard let nodeEndpoint = profile.nodeEndpoint, !nodeEndpoint.isEmpty else {
      listener.stop()
      inviterListener = nil
      return
    }
    let nodeClient = InviterNodeClient(
      nodeEndpoint: nodeEndpoint,
      identity: identity,
      probe: { [weak self] endpoint, payload in
        guard let self, let listener = self.inviterListener else {
          throw InviterNodeError.closed
        }
        try await listener.sendProbe(endpoint: endpoint, payload: payload)
      },
      candidates: { [weak self] in
        guard let self, let listener = self.inviterListener,
              let port = listener.port else { return nil }
        return InviterNodeClient.Candidate(
          version: 1, candidateId: UUID().uuidString, sessionId: "",
          key: identity.publicKey(), kind: "host", transport: "udp",
          address: advertiseAddress ?? "0.0.0.0", port: port, priority: 100,
          expiresAt: ISO8601DateFormatter.js.string(
            from: Date().addingTimeInterval(30)
          )
        )
      },
      onBootstrap: { [weak self] event in
        guard let self else { return }
        await self.handleInviterBootstrap(event)
      },
      onStatusChange: { [weak self] registered in
        self?.inviterRegistered = registered
      }
    )
    inviterNodeClient = nodeClient
    nodeClient.start()

    inviterSweepTask?.cancel()
    inviterSweepTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        await self?.inviter?.sweep()
      }
    }
    print("inviter started on \(listenerEndpoint)")
  }

  private func stopInviter() {
    inviterSweepTask?.cancel()
    inviterSweepTask = nil
    inviterNodeClient?.stop()
    inviterNodeClient = nil
    inviterListener?.stop()
    inviterListener = nil
    Task { await inviter?.closeAll() }
    inviter = nil
    inviterRegistered = false
  }

  private func handleInviterBootstrap(_ event: InviterNodeClient.BootstrapEvent) async {
    guard let inviter else { return }
    extensionDiagnostics("inviter push replayId=\(event.tokenDigest.prefix(8)) joiner=\(event.joinerKey.prefix(8))")
    inviter.expectBootstrap(
      replayId: event.tokenDigest,
      joinerServiceKey: event.joinerKey
    )
    print("inviter bootstrap for \(event.transactionId)")
  }

  private struct InviterStatus: Encodable {
    let registered: Bool
    let serviceKey: String
    let listenerEndpoint: String
  }

  override func handleAppMessage(_ messageData: Data) async -> Data? {
    if messageData == Data("hn9xx-diag".utf8) {
      return Data(extensionDiagnosticsBuffer.joined(separator: "\n").utf8)
    }
    if let message = try? JSONDecoder().decode(ExtensionNativeJoinMessage.self, from: messageData) {
      return await handleNativeJoinMessage(message)
    } else if let message = try? JSONDecoder().decode(ExtensionBootstrapMessage.self, from: messageData) {
      return await handleBootstrapMessage(message)
    } else {
      do {
        let message = try JSONDecoder().decode(GatewayProviderMessage.self, from: messageData)
        guard ["gatewayStatus", "exitStatus", "keychainProof", "inviterStatus", "memberPeers"].contains(message.command) else { return nil }
        switch message.command {
        case "gatewayStatus":
          return try JSONEncoder().encode(StateResponse(state: gatewayServingState))
        case "exitStatus":
          return try JSONEncoder().encode(StateResponse(state: exitState))
        case "keychainProof":
          let key = try KeyChain.hubIdentity()
          let signature = key.sign(text: "hub-network/readiness-keychain-proof/v1")
          let encoded = try JSONEncoder().encode(
            KeychainProof(publicKey: key.publicKey(), signature: signature)
          )
          return encoded
        case "inviterStatus":
          let key = try? KeyChain.hubIdentity()
          let status = InviterStatus(
            registered: inviterRegistered,
            serviceKey: key?.publicKey() ?? "",
            listenerEndpoint: inviterListener.map { "\(inviterAdvertiseAddress ?? "0.0.0.0"):\($0.port ?? 0)" } ?? ""
          )
          return try JSONEncoder().encode(status)
        case "memberPeers":
          let message = try JSONDecoder().decode(MemberPeersMessage.self, from: messageData)
          try await wireGuardAdapter.setMemberPeers(message.peers.map { ($0.publicKey, $0.allowedIPs) })
          return try JSONEncoder().encode(MemberPeersResponse(ok: true))
        default: return nil
        }
      } catch { return nil }
    }
  }

  private struct MemberPeersMessage: Decodable {
    struct Peer: Decodable {
      let publicKey: String
      let allowedIPs: [String]
    }
    let command: String
    let peers: [Peer]
  }

  private struct MemberPeersResponse: Encodable {
    let ok: Bool
  }

  private func handleNativeJoinMessage(_ message: ExtensionNativeJoinMessage) async -> Data? {
    let identity = bootstrapIdentity
    guard message.version == 1,
          message.tunnelInstanceId == identity.tunnelInstanceId,
          message.generation == identity.generation,
          !message.transactionId.isEmpty else {
      return nil
    }

    var status: ExtensionNativeJoinStatus
    switch message.command {
    case .start:
      guard let start = message.start,
            message.commit == nil, message.cancel == nil,
            validateNativeJoinStart(start, message: message) else {
        return nil
      }
      if let existing = nativeJoinStarts[start.transactionId] {
        guard existing == start, let existingStatus = nativeJoinStatuses[start.transactionId]
        else {
          return nil
        }
        status = existingStatus
      } else {
        guard nativeJoinStarts.isEmpty else {
          return nil
        }
        nativeJoinStarts[start.transactionId] = start
        status = nativeJoinStatus(start, state: .accepted)
        nativeJoinStatuses[start.transactionId] = status
        scheduleNativeJoinExpiry(start)
        startNativeJoinRendezvous(start)
      }
    case .status:
      guard message.start == nil, message.commit == nil, message.cancel == nil,
            let current = nativeJoinStatuses[message.transactionId] else {
        return nil
      }
      status = current
    case .cancel:
      guard message.start == nil, message.commit == nil,
            let cancel = message.cancel,
            let start = nativeJoinStarts[message.transactionId],
            cancel.version == 1,
            cancel.transactionId == start.transactionId,
            cancel.tunnelInstanceId == start.tunnelInstanceId,
            cancel.generation == start.generation else {
        return nil
      }
      status = nativeJoinStatus(start, state: .cancelled)
      nativeJoinStatuses[start.transactionId] = status
      teardownNativeJoin(start.transactionId)
    case .commit:
      guard message.start == nil, message.cancel == nil,
            let commit = message.commit,
            let start = nativeJoinStarts[message.transactionId],
            validateNativeJoinCommit(commit, start: start) else {
        return nil
      }
      if let current = nativeJoinStatuses[start.transactionId],
         current.state == .committed {
        status = current
      } else if let current = nativeJoinStatuses[start.transactionId],
                current.state == .committing {
        status = current
      } else {
        guard nativeJoinStatuses[start.transactionId]?.state == .readyToEnroll else {
          return nil
        }
        return await commitNativeJoin(commit, start: start, message: message)
      }
    }

    return try? JSONEncoder().encode(ExtensionNativeJoinResponse(
      version: 1, command: message.command,
      tunnelInstanceId: identity.tunnelInstanceId,
      generation: identity.generation,
      transactionId: message.transactionId, status: status
    ))
  }

  private func validateNativeJoinStart(
    _ start: ExtensionNativeJoinStart,
    message: ExtensionNativeJoinMessage
  ) -> Bool {
    guard start.version == 1,
          start.transactionId == message.transactionId,
          start.tunnelInstanceId == message.tunnelInstanceId,
          start.generation == message.generation,
          !start.key.isEmpty,
          !start.wireGuardKey.isEmpty,
          let decoded = try? NetworkInvitationParser.decode(start.invitationCode),
          decoded.replayId == start.replayId,
          decoded.agentKey == start.invitingKey,
          decoded.node == start.node,
          UInt32(ISO8601DateFormatter.js.date(from: start.expiresAt)?.timeIntervalSince1970 ?? 0)
            == decoded.expires,
          decoded.expiresAt > Date()
    else { return false }
    return true
  }

  private func validateNativeJoinCommit(
    _ commit: ExtensionNativeJoinCommit,
    start: ExtensionNativeJoinStart
  ) -> Bool {
    commit.version == 1 &&
      commit.transactionId == start.transactionId &&
      commit.tunnelInstanceId == start.tunnelInstanceId &&
      commit.generation == start.generation &&
      commit.key == start.key &&
      commit.wireGuardKey == start.wireGuardKey &&
      !commit.hubNetworkId.isEmpty &&
      !commit.overlayAddresses.isEmpty && commit.expiresAt == start.expiresAt
  }

  private func commitNativeJoin(_ commit: ExtensionNativeJoinCommit, start: ExtensionNativeJoinStart, message: ExtensionNativeJoinMessage) async -> Data? {
    nativeJoinStatuses[start.transactionId] = nativeJoinStatus(
      start, state: .committing
    )
    do {
      let profile = try Profile.load()
      try validateCommittedProfile(profile, commit: commit, start: start)
      let dnsServer: Address
      var replacementDNSListener: LocalReservedDNSListener?
      if let remoteDNS = profile.dnsServerAddress {
        dnsServer = try Address(remoteDNS)
      } else {
        let listener = try LocalReservedDNSListener(profile: profile)
        try listener.start()
        replacementDNSListener = listener
        dnsServer = listener.address
      }
      do {
        try await wireGuardAdapter.commitBootstrapMembership(
          assignmentId: start.transactionId, profile: profile
        )
        try await setTunnelNetworkSettings(
          Self.networkSettings(for: profile, dnsServer: dnsServer)
        )
      } catch {
        replacementDNSListener?.stop()
        throw error
      }
      dnsListener?.stop()
      dnsListener = replacementDNSListener
      activeBootstrapProfile = profile
      finishNativeJoinTransientState(start.transactionId)
      Self.writeDiagnostics("commit ok overlay=\(profile.overlayIPv4Address) hubNetwork=\(profile.hubNetworkID.prefix(8))")
      let status = nativeJoinStatus(start, state: .committed)
      nativeJoinStatuses[start.transactionId] = status
      return try? JSONEncoder().encode(ExtensionNativeJoinResponse(
        version: 1, command: message.command,
        tunnelInstanceId: start.tunnelInstanceId, generation: start.generation,
        transactionId: start.transactionId, status: status
      ))
    } catch {
      Self.writeDiagnostics("commit failed: \(error)")
      finishNativeJoinTransientState(start.transactionId)
      let status = nativeJoinStatus(
        start, state: .failed,
        error: NetworkError(code: "native_join_commit_failed",
                            message: String(describing: error), retryable: true)
      )
      nativeJoinStatuses[start.transactionId] = status
      return try? JSONEncoder().encode(ExtensionNativeJoinResponse(
        version: 1, command: message.command,
        tunnelInstanceId: start.tunnelInstanceId, generation: start.generation,
        transactionId: start.transactionId, status: status
      ))
    }
  }

  private func validateCommittedProfile(_ profile: Profile, commit: ExtensionNativeJoinCommit, start: ExtensionNativeJoinStart) throws {
    try profile.validate()
    let addresses = [profile.overlayIPv4Address, profile.overlayIPv6Address]
      .map { String($0.split(separator: "/", maxSplits: 1)[0]) }
      .sorted()
    guard profile.hubNetworkID == commit.hubNetworkId,
          profile.profilePublicKey == commit.key,
          profile.wireGuardPublicKey == commit.wireGuardKey,
          addresses == commit.overlayAddresses.sorted()
    else { throw Profile.Error.incompletePeerConfiguration }
  }

  private func scheduleNativeJoinExpiry(_ start: ExtensionNativeJoinStart) {
    nativeJoinExpiryTasks[start.transactionId]?.cancel()
    nativeJoinExpiryTasks[start.transactionId] = Task { [weak self] in
      guard let expiry = ISO8601DateFormatter.js.date(from: start.expiresAt) else { return }
      let delay = max(0, expiry.timeIntervalSinceNow)
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self,
            self.nativeJoinStatuses[start.transactionId]?.state != .committed else { return }
      self.finishNativeJoinTransientState(start.transactionId, cancelExpiry: false)
      self.nativeJoinStatuses[start.transactionId] = self.nativeJoinStatus(
        start, state: .failed,
        error: NetworkError(code: "native_join_expired",
                            message: "Invitation expired", retryable: false)
      )
      self.nativeJoinExpiryTasks.removeValue(forKey: start.transactionId)
    }
  }

  private func finishNativeJoinTransientState(
    _ transactionId: String,
    cancelExpiry: Bool = true
  ) {
    nativeJoinTasks.removeValue(forKey: transactionId)?.cancel()
    nativeJoinClients.removeValue(forKey: transactionId)?.close()
    if cancelExpiry { nativeJoinExpiryTasks.removeValue(forKey: transactionId)?.cancel() }
    Task { try? await wireGuardAdapter.removeBootstrapPeer(assignmentId: transactionId) }
  }

  private func nativeJoinStatus(
    _ start: ExtensionNativeJoinStart,
    state: ExtensionNativeJoinState,
    error: NetworkError? = nil,
    hubProHost: String? = nil,
    bootstrapAddresses: [String]? = nil,
    admission: DirectBootstrapResponse? = nil,
    hubPeerEndpoint: String? = nil
  ) -> ExtensionNativeJoinStatus {
    ExtensionNativeJoinStatus(
      version: 1, replayId: start.replayId,
      transactionId: start.transactionId,
      tunnelInstanceId: start.tunnelInstanceId, generation: start.generation,
      key: start.key, wireGuardKey: start.wireGuardKey,
      expiresAt: start.expiresAt,
      hubProHost: hubProHost, bootstrapAddresses: bootstrapAddresses,
      admission: admission,
      hubPeerEndpoint: hubPeerEndpoint,
      state: state, updatedAt: ISO8601DateFormatter.js.string(from: Date()),
      error: error
    )
  }

  private func startNativeJoinRendezvous(_ start: ExtensionNativeJoinStart) {
    let client = InvitationBootstrapClient()
    nativeJoinClients[start.transactionId] = client
    nativeJoinTasks[start.transactionId] = Task { [weak self, weak client] in
      guard let self, let client else { return }
      do {
        guard let port = await wireGuardAdapter.listenPort() else { throw InvitationBootstrapError.invalidCandidate }
        // The joiner's service identity travels in canonical SPKI form on the
        // wire (session key, candidate key, HUBB request joinerServiceKey) —
        // the inviter's verifier converts SPKI→raw before validating the
        // request signature, and the node's push/signal carry the session key
        // verbatim. The staged record's profilePublicKey is raw; normalize.
        let joinerServiceKey = KeyChain.spkiPublicKey(rawBase64: start.key) ?? start.key
        // The joiner's advertised candidate must be a reachable IPv4 — the
        // inviter sends its WireGuard handshake reply to this address. 0.0.0.0
        // (the adapter's INADDR_ANY bind) is NOT routable by the remote
        // inviter, so the temp-link handshake dies and the single-use invite
        // is consumed by a doomed retry (node rejects it: "unauthorized").
        // Mirror the inviter's Go-parity rule (ReachableAddress.primaryIPv4).
        let candidate = InvitationBootstrapClient.Candidate(
          version: 1, candidateId: UUID().uuidString, sessionId: "pending",
          key: joinerServiceKey, kind: "host", transport: "udp",
          address: ReachableAddress.primaryIPv4() ?? "0.0.0.0", port: port, priority: 0,
          expiresAt: ISO8601DateFormatter.js.string(
            from: min(Date().addingTimeInterval(30),
                      ISO8601DateFormatter.js.date(from: start.expiresAt) ?? Date())
          )
        )
        self.nativeJoinStatuses[start.transactionId] = self.nativeJoinStatus(
          start, state: .rendezvous
        )
        let peer = try await client.rendezvous(
          invitationCode: start.invitationCode,
          tokenDigest: start.replayId,
          transactionId: start.transactionId,
          tunnelInstanceId: "",
          generation: 0,
          node: start.node,
          localKey: joinerServiceKey,
          localCandidate: candidate,
          expectedPeerKey: start.invitingKey,
          sendProbe: { endpoint, payload in
            try await self.wireGuardAdapter.sendObservationProbe(
              endpoint: endpoint, payload: payload
            )
          },
          timeout: min(30, max(0, ISO8601DateFormatter.js.date(from: start.expiresAt)?.timeIntervalSinceNow ?? 0))
        )
        Self.writeDiagnostics("rendezvous ok candidates=\(peer.candidates.count) observed=\(peer.observedEndpoint.address):\(peer.observedEndpoint.port)")
        // A declared candidate with an unspecified address (an inviter bound
        // to all interfaces) keeps its port on the node-observed host.
        let inviterEndpoint = peer.candidates.first.map { candidate in
          candidate.address == "0.0.0.0" || candidate.address == "::"
            ? Self.bootstrapEndpoint(InvitationBootstrapClient.ObservedEndpoint(
                version: peer.observedEndpoint.version, key: peer.observedEndpoint.key,
                transport: "udp", address: peer.observedEndpoint.address, port: candidate.port
              ))
            : Self.bootstrapEndpoint(candidate)
        } ?? Self.bootstrapEndpoint(peer.observedEndpoint)
        Self.writeDiagnostics("exchange target \(inviterEndpoint)")
        let serviceKey = try DirectBootstrapClient.joinerServiceKey(
          transactionId: start.transactionId,
          profilePublicKey: start.key
        )
        let request = try DirectBootstrapClient.signRequest(
          key: serviceKey,
          replayId: start.replayId,
          joinerServiceKey: joinerServiceKey,
          joinerWireGuardKey: start.wireGuardKey
        )
        let response = try await DirectBootstrapClient.exchange(
          endpoint: inviterEndpoint,
          request: request,
          expectedInviterServiceKey: start.invitingKey,
          timeout: min(20, max(5, ISO8601DateFormatter.js.date(from: start.expiresAt)?.timeIntervalSinceNow ?? 20))
        )
        Self.writeDiagnostics("bootstrap ok hubProHost=\(response.hubProHost) inviterV4=\(response.inviterAddress.ipv4) joinerV4=\(response.joinerAddress.ipv4) endpoint=\(response.endpoints.first.map(Self.directBootstrapEndpoint) ?? "none")")
        let wireGuardEndpoint = Self.wireGuardEndpoint(response, exchangeTarget: inviterEndpoint)
        try await self.installNativeJoinPeer(
          start,
          inviterWireGuardKey: response.inviterWireGuardKey,
          inviterAddresses: [
            response.inviterAddress.ipv4,
            response.inviterAddress.ipv6,
          ],
          hubProHost: response.hubProHost,
          endpoint: wireGuardEndpoint
        )
        try await self.wireGuardAdapter.configureBootstrapLink(
          assignmentId: start.transactionId,
          inviterWireGuardKey: response.inviterWireGuardKey,
          joinerAddresses: [
            response.joinerAddress.ipv4,
            response.joinerAddress.ipv6,
          ],
          inviterAddresses: [
            response.inviterAddress.ipv4,
            response.inviterAddress.ipv6,
          ],
          hubProHost: response.hubProHost,
          endpoint: wireGuardEndpoint
        )
        try await self.setTunnelNetworkSettings(
          Self.bootstrapNetworkSettings(
            joinerIPv4: response.joinerAddress.ipv4,
            joinerIPv6: response.joinerAddress.ipv6
          )
        )
        self.nativeJoinStatuses[start.transactionId] = self.nativeJoinStatus(
          start, state: .peerInstalled,
          hubProHost: response.hubProHost,
          bootstrapAddresses: [
            response.joinerAddress.ipv4,
            response.joinerAddress.ipv6,
          ]
        )
        self.nativeJoinStatuses[start.transactionId] = self.nativeJoinStatus(
          start, state: .readyToEnroll,
          hubProHost: response.hubProHost,
          bootstrapAddresses: [
            response.joinerAddress.ipv4,
            response.joinerAddress.ipv6,
          ],
          admission: response,
          hubPeerEndpoint: wireGuardEndpoint
        )
      } catch is CancellationError {
        await self.removeBootstrapPeer(start.transactionId)
      } catch {
        Self.writeDiagnostics("rendezvous failed: \(error)")
        await self.removeBootstrapPeer(start.transactionId)
        self.nativeJoinStatuses[start.transactionId] = self.nativeJoinStatus(
          start, state: .failed,
          error: NetworkError(
            code: "native_join_bootstrap_failed",
            message: String(describing: error), retryable: true
          )
        )
      }
      self.nativeJoinTasks.removeValue(forKey: start.transactionId)
      self.nativeJoinClients.removeValue(forKey: start.transactionId)?.close()
    }
  }

  private func installNativeJoinPeer(
    _ start: ExtensionNativeJoinStart,
    inviterWireGuardKey: String,
    inviterAddresses: [String],
    hubProHost: String,
    endpoint: String
  ) async throws {
    // Bootstrap host-route validation requires prefix notation ("100.96.0.3/32",
    // "fd48::1/128"); the response carries bare addresses. The inviter's
    // overlay IPv4 is also the hub-pro host, so drop the hub-pro entry when it
    // duplicates an inviter route (duplicates are rejected).
    let inviterRoutes = inviterAddresses.map { $0.contains(":") ? "\($0)/128" : "\($0)/32" }
    let hubProRoute = hubProHost.contains(":") ? "\(hubProHost)/128" : "\(hubProHost)/32"
    let hubProBootstrapAddresses = inviterRoutes.contains(hubProRoute) ? [] : [hubProRoute]
    try await wireGuardAdapter.installBootstrapPeer(
      assignmentId: start.transactionId,
      publicKeyBase64: inviterWireGuardKey,
      overlayAddresses: inviterRoutes,
      hubProBootstrapAddresses: hubProBootstrapAddresses,
      endpoint: endpoint
    )
  }

  private func teardownNativeJoin(_ transactionId: String) {
    finishNativeJoinTransientState(transactionId)
  }

  private func handleBootstrapMessage(_ message: ExtensionBootstrapMessage) async -> Data? {
    Self.writeDiagnostics("bootstrap message received: \(message.command.rawValue) hubNetwork=\(activeBootstrapProfile?.hubNetworkID.prefix(8) ?? "none")")
    guard message.version == 1 else {
      Self.writeDiagnostics("bootstrap message bad version: \(message.version)")
      return nil
    }
    let identity = bootstrapIdentity
    if message.command != .readiness &&
      (message.tunnelInstanceId != identity.tunnelInstanceId ||
       message.generation != identity.generation) {
      Self.writeDiagnostics("bootstrap identity mismatch")
      return nil
    }

    var readiness: ExtensionReadinessAssertion?
    switch message.command {
    case .readiness:
      guard let profile = activeBootstrapProfile else {
        Self.writeDiagnostics("readiness: no active bootstrap profile")
        return nil
      }
      do {
        readiness = try ExtensionReadinessAssertion.signed(
          profile: profile,
          tunnelInstanceId: identity.tunnelInstanceId,
          generation: identity.generation
        )
      } catch {
        Self.writeDiagnostics("readiness signing failed: \(error)")
        return nil
      }
    case .health:
      break
    }

    let now = Date()
    let health: ExtensionBootstrapHealth?
    if message.command == .health,
       let profile = activeBootstrapProfile,
       let wireGuardKey = profile.wireGuardPublicKey {
      health = ExtensionBootstrapHealth(
        state: .ready,
        activeAssignmentIds: [],
        checkedAt: ISO8601DateFormatter.js.string(from: now),
        hubNetworkId: profile.hubNetworkID,
        key: profile.profilePublicKey,
        wireGuardKey: wireGuardKey,
        tunnelInstanceId: identity.tunnelInstanceId,
        capabilities: ["invitation-bootstrap-v1"],
        expiresAt: ISO8601DateFormatter.js.string(from: now.addingTimeInterval(30))
      )
    } else {
      health = nil
    }
    return try? JSONEncoder().encode(
      ExtensionBootstrapResponse(
        version: 1,
        command: message.command,
        tunnelInstanceId: identity.tunnelInstanceId,
        generation: identity.generation,
        readiness: readiness,
        health: health
      )
    )
  }

  private func removeBootstrapPeer(_ assignmentId: String) async {
    try? await wireGuardAdapter.removeBootstrapPeer(assignmentId: assignmentId)
  }

  static func networkSettings(for profile: Profile, dnsServer: Address? = nil) throws -> NEPacketTunnelNetworkSettings {
    try profile.validate()
    let ipv4 = try Address(overlay: profile.overlayIPv4Address)
    let ipv6 = try Address(overlay: profile.overlayIPv6Address)

    // NetworkExtension rejects loopback values here even though
    // `tunnelRemoteAddress` is only descriptive for a peerless membership.
    // Use TEST-NET-1 when no real WireGuard peer endpoint exists.
    let remoteAddress = profile.peerEndpoint.flatMap(Self.endpointHost) ?? "192.0.2.1"
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
    let ipv4Settings = NEIPv4Settings(
      addresses: [ipv4.string],
      subnetMasks: ["255.255.255.255"]
    )
    ipv4Settings.includedRoutes = profile.gatewayGrant?.ipv4 == true
      ? [NEIPv4Route.default()]
      : [NEIPv4Route(destinationAddress: "100.96.0.0", subnetMask: "255.224.0.0")]
    ipv4Settings.excludedRoutes = (profile.controlPlaneIPv4Hosts ?? []).map {
      NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255")
    }
    settings.ipv4Settings = ipv4Settings

    let ipv6Settings = NEIPv6Settings(
      addresses: [ipv6.string],
      networkPrefixLengths: [NSNumber(value: ipv6.prefix)]
    )
    ipv6Settings.includedRoutes = profile.gatewayGrant?.ipv6 == true
      ? [NEIPv6Route.default()]
      : [
        NEIPv6Route(
          destinationAddress: "fd48:5542:4e45::",
          networkPrefixLength: 48
        )
      ]
    ipv6Settings.excludedRoutes = (profile.controlPlaneIPv6Hosts ?? []).map {
      NEIPv6Route(destinationAddress: $0, networkPrefixLength: 128)
    }
    settings.ipv6Settings = ipv6Settings

    let dnsSettings = NEDNSSettings(servers: [(dnsServer ?? ipv4).string])
    dnsSettings.matchDomains = profile.usesGateway ? [""] : [profile.dnsSuffix]
    dnsSettings.matchDomainsNoSearch = true
    settings.dnsSettings = dnsSettings

    settings.mtu = 1280
    return settings
  }

  /// Network settings for the temporary direct bootstrap link. The joiner's
  /// assigned point-to-point addresses are the tunnel addresses; overlay
  /// routes keep hub-pro (reachable through the inviter) inside the tunnel.
  static func bootstrapNetworkSettings(
    joinerIPv4: String,
    joinerIPv6: String
  ) throws -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")
    let ipv4Settings = NEIPv4Settings(
      addresses: [joinerIPv4],
      subnetMasks: ["255.255.255.255"]
    )
    ipv4Settings.includedRoutes = [
      NEIPv4Route(destinationAddress: "100.96.0.0", subnetMask: "255.224.0.0")
    ]
    settings.ipv4Settings = ipv4Settings

    let ipv6Settings = NEIPv6Settings(
      addresses: [joinerIPv6],
      networkPrefixLengths: [128]
    )
    ipv6Settings.includedRoutes = [
      NEIPv6Route(
        destinationAddress: "fd48:5542:4e45::",
        networkPrefixLength: 48
      )
    ]
    settings.ipv6Settings = ipv6Settings
    settings.mtu = 1280
    return settings
  }

  static func killSwitchSettings(for profile: Profile) throws -> NEPacketTunnelNetworkSettings {
    guard profile.usesGateway else { throw Profile.Error.incompletePeerConfiguration}
    return try networkSettings(for: profile, dnsServer: profile.dnsServerAddress?.address())
  }

  private func scheduleGatewayHealth(_ profile: Profile) {
    gatewayExpiryTask?.cancel()
    guard let expiryValue = profile.gatewayGrant?.expiresAt,
          let expiry = ISO8601DateFormatter.js.date(from: expiryValue) else {
      exitState = .blocking
      return
    }
    gatewayExpiryTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self else { return }
        guard await wireGuardAdapter.hasRecentHandshake() else { return }
        guard expiry > Date() else {
          self.exitState = .blocking
          await self.wireGuardAdapter.stop()
          self.setTunnelNetworkSettings(
            try? Self.killSwitchSettings(for: profile)
          ) { _ in }
          return
        }
      }
    }
  }


  private static func endpointHost(_ endpoint: String) -> String? {
    if endpoint.hasPrefix("["),
       let closingBracket = endpoint.firstIndex(of: "]")
    {
      return String(endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket])
    }
    guard let separator = endpoint.lastIndex(of: ":") else { return nil }
    return String(endpoint[..<separator])
  }

  private static func bootstrapEndpoint(
    _ endpoint: InvitationBootstrapClient.ObservedEndpoint
  ) -> String {
    endpoint.address.contains(":")
      ? "[\(endpoint.address)]:\(endpoint.port)"
      : "\(endpoint.address):\(endpoint.port)"
  }

  private static func bootstrapEndpoint(
    _ candidate: InvitationBootstrapClient.Candidate
  ) -> String {
    candidate.address.contains(":")
      ? "[\(candidate.address)]:\(candidate.port)"
      : "\(candidate.address):\(candidate.port)"
  }

  private static func directBootstrapEndpoint(
    _ endpoint: BootstrapEndpoint
  ) -> String {
    endpoint.address.contains(":")
      ? "[\(endpoint.address)]:\(endpoint.port)"
      : "\(endpoint.address):\(endpoint.port)"
  }

  /// The inviter's WireGuard endpoint. An inviter that could not find a
  /// reachable address advertises an unspecified one; then use the host the
  /// exchange reached (node-observed) with the advertised WireGuard port, as
  /// the Go joiner does.
  private static func wireGuardEndpoint(
    _ response: DirectBootstrapResponse,
    exchangeTarget: String
  ) -> String {
    guard let endpoint = response.endpoints.first else { return exchangeTarget }
    guard endpoint.address == "0.0.0.0" || endpoint.address == "::" else {
      return directBootstrapEndpoint(endpoint)
    }
    let host: Substring
    if exchangeTarget.hasPrefix("["), let closing = exchangeTarget.firstIndex(of: "]") {
      host = exchangeTarget[exchangeTarget.index(after: exchangeTarget.startIndex)..<closing]
    } else if let colon = exchangeTarget.lastIndex(of: ":") {
      host = exchangeTarget[..<colon]
    } else {
      return exchangeTarget
    }
    return directBootstrapEndpoint(BootstrapEndpoint(address: String(host), port: endpoint.port, transport: "udp"))
  }
  
  private struct StateResponse<State: Encodable>: Encodable {
    let state: State
  }
  private enum ExitState: String, Encodable {
    case disabled, connected, blocking
  }
  private enum GatewayServingState: String, Encodable {
    case disabled, enabling, available, disabling, unavailable
  }
  
  private struct GatewayProviderMessage: Decodable {
    let command: String
  }

  #if DEBUG
  private struct KeychainProof: Encodable {
    let publicKey: String
    let signature: String
  }
  #endif
}
