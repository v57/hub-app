//
//  PacketTunnelProvider.swift
//  PacketTunnelExtension
//
//  Created by Dmitry on 27.07.26.
//

import Network
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
  /// Watches whether the gateway answers, for a profile that falls back to this device's own network
  private var gatewayPathTask: Task<Void, Never>?
  /// Whether this device's traffic goes through the gateway or, falling back, through its own network
  private var routesThroughGateway = true
  private var gatewayDNSServer: Address?
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
  /// Keeps this device present at the coordinator, for links and invitations
  private var coordinatorClient: CoordinatorClient?
  private var linkManager: LinkManager?
  private var linkTicker: Task<Void, Never>?
  private var inviter: Inviter?
  private var inviterSweepTask: Task<Void, Never>?
  private var inviterRegistered = false

  override func startTunnel(options: [String: NSObject]?) async throws {
    bootstrapIdentity = (UUID().uuidString, bootstrapIdentity.generation + 1)
    reset()
    do {
      let profile = try Profile.decode()
      Self.writeDiagnostics("startTunnel: profile decoded, peer endpoint \(profile.peerEndpoint ?? "-")")
      gatewayServingState = profile.servesGateway ? .enabling : .disabled
      if profile.fallsBack {
        // Its own network until the gateway answers
        exitState = .fallback
        routesThroughGateway = false
        try await setTunnelNetworkSettings(Self.networkSettings(for: profile, throughGateway: false))
      } else if profile.usesGateway {
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
      if profile.servesGateway {
        // Members' internet flows end here and leave from this device's sockets; DNS to its overlay addresses too
        let addresses = [profile.overlayIPv4Address, profile.overlayIPv6Address].compactMap {
          $0.split(separator: "/").first.map(String.init)
        }
        try await wireGuardAdapter.setGateway(addresses: addresses)
        Self.writeDiagnostics("gateway serving, DNS on \(addresses.joined(separator: ", "))")
      }
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
      gatewayDNSServer = dnsServer
      routesThroughGateway = !profile.fallsBack
      try await setTunnelNetworkSettings(
        Self.networkSettings(for: profile, dnsServer: dnsServer, throughGateway: routesThroughGateway)
      )
      Self.writeDiagnostics("network settings applied")
      gatewayServingState = profile.servesGateway ? .available : .disabled
      exitState = profile.usesGateway ? (routesThroughGateway ? .connected : .fallback) : .disabled
      activeBootstrapProfile = profile
      if profile.usesGateway {
        scheduleGatewayHealth(profile)
        watchGatewayPath(profile)
      }
      if profile.inviterEnabled {
        startInviter(profile: profile)
      } else {
        extensionDiagnostics("inviter off in this profile")
      }
      startCoordinator(profile: profile)
    } catch {
      gatewayServingState = profile.servesGateway ? .unavailable : .disabled
      await wireGuardAdapter.stop()
      if profile.fallsBack {
        exitState = .fallback
        routesThroughGateway = false
        try? await setTunnelNetworkSettings(Self.networkSettings(for: profile, throughGateway: false))
        Self.writeDiagnostics("startValidatedTunnel failed, using this device's network: \(error)")
      } else if profile.usesGateway {
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
    // The system says why it stops the tunnel only here; the diagnostics file keeps it for NetTest
    Self.writeDiagnostics("stopTunnel: \(reason.name) (\(reason.rawValue))")
    gatewayServingState = .disabled
    gatewayExpiryTask?.cancel()
    gatewayExpiryTask = nil
    gatewayPathTask?.cancel()
    gatewayPathTask = nil
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
    stopCoordinator()
  }

  // MARK: Inviter

  private func startInviter(profile: Profile) {
    guard inviter == nil else { return }
    let identity: KeyChain
    do {
      identity = try KeyChain.hubIdentity()
    } catch {
      extensionDiagnostics("inviter not started: no hub identity in the keychain: \(error)")
      return
    }
    guard let overlayIPv4 = profile.overlayIPv4Address.split(separator: "/").first.map(String.init) else {
      extensionDiagnostics("inviter not started: no overlay IPv4 in \(profile.overlayIPv4Address)")
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
      extensionDiagnostics("inviter not started: bootstrap listener failed: \(error)")
      return
    }
    inviterListener = listener
    let listenerEndpoint = listener.start()
    // Joiners send their request to WireGuard's socket, the one this inviter offers and probes from; the listener's
    // own socket still answers a joiner that dials it
    let adapter = wireGuardAdapter
    adapter.bootstrapDatagrams.setRequestHandler { [weak listener] source, datagram in
      listener?.serve(datagram, from: source) { frame in
        Task { try? await adapter.sendBootstrapDatagram(to: source, frame) }
      }
    }

    inviterSweepTask?.cancel()
    inviterSweepTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        await self?.inviter?.sweep()
      }
    }
    extensionDiagnostics("inviter started on \(listenerEndpoint), advertising \(advertiseAddress ?? "none")")
  }

  private func stopInviter() {
    inviterSweepTask?.cancel()
    inviterSweepTask = nil
    wireGuardAdapter.bootstrapDatagrams.setRequestHandler(nil)
    inviterListener?.stop()
    inviterListener = nil
    Task { await inviter?.closeAll() }
    inviter = nil
    inviterRegistered = false
  }

  // MARK: Coordinator and links

  /// Registers presence at the coordinator the hub named (`network/links`, else the profile's node) and runs this
  /// device's links. Invitation bootstraps arrive on the same connection.
  private func startCoordinator(profile: Profile) {
    guard coordinatorClient == nil else { return }
    let identity: KeyChain
    do {
      identity = try KeyChain.hubIdentity()
    } catch {
      extensionDiagnostics("coordinator not started: no hub identity in the keychain: \(error)")
      return
    }
    guard let trustedHubKey = profile.trustedHubKey, !trustedHubKey.isEmpty else {
      extensionDiagnostics("coordinator not started: the profile pins no hub key")
      return
    }
    let stored = Self.storedLinks().flatMap { $0.hubKey == trustedHubKey ? $0 : nil }
    guard let nodeEndpoint = stored?.coordinator ?? profile.nodeEndpoint, !nodeEndpoint.isEmpty else {
      extensionDiagnostics("coordinator not started: no coordinator known")
      return
    }
    let advertiseAddress = ReachableAddress.primaryIPv4()
    let client = CoordinatorClient(
      nodeEndpoint: nodeEndpoint,
      identity: identity,
      // The inviter probes and offers WireGuard's socket, like the joiner: the node then shows the joiner the NAT
      // mapping the exchange and the temporary link both use (`BootstrapDatagrams`)
      probe: { [weak self] endpoint, payload in
        guard let self, self.inviterListener != nil else {
          throw CoordinatorError.closed
        }
        try await self.wireGuardAdapter.sendObservationProbe(endpoint: endpoint, payload: payload)
      },
      candidates: { [weak self] in
        guard let self, self.inviterListener != nil,
              let port = await self.wireGuardAdapter.listenPort() else { return nil }
        return CoordinatorClient.Candidate(
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
      onLink: { [weak self] envelope in
        await self?.linkManager?.handle(envelope)
      },
      onStatusChange: { [weak self] present in
        guard let self else { return }
        self.inviterRegistered = present
        extensionDiagnostics("coordinator presence \(present ? "registered" : "lost")")
        let manager = self.linkManager
        Task { await manager?.presenceChanged(present) }
      }
    )
    let adapter = wireGuardAdapter
    let udpEndpoint = client.udpEndpoint
    let manager = LinkManager(ownKey: identity.publicKey(), trustedHubKey: trustedHubKey, dependencies: .init(
      open: { try await client.openLink($0) },
      send: { try await client.sendLink($0, linkId: $1, endpoints: $2) },
      probe: { try await adapter.sendObservationProbe(endpoint: udpEndpoint, payload: $0) },
      apply: { try await adapter.setLinkPeers($0) },
      lastHandshake: { await adapter.lastHandshake(wireGuardKey: $0) },
      liveEndpoint: { await adapter.liveEndpoint(wireGuardKey: $0) },
      candidates: {
        guard let address = ReachableAddress.primaryIPv4(), let port = await adapter.listenPort() else { return [] }
        return [LinkEndpoint(address: address, port: port)]
      },
      log: { extensionDiagnostics($0) }
    ))
    coordinatorClient = client
    linkManager = manager
    linkTicker = Task {
      if let stored { await manager.update(grants: stored.grants) }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        await manager.tick()
      }
    }
    client.start()
    extensionDiagnostics("coordinator \(nodeEndpoint), \(stored?.grants.count ?? 0) stored link grants")
  }

  private func stopCoordinator() {
    linkTicker?.cancel()
    linkTicker = nil
    coordinatorClient?.stop()
    coordinatorClient = nil
    linkManager = nil
    inviterRegistered = false
  }

  /// The app forwarded `network/links`: keep it for restarts away from the hub, follow its coordinator and hand the
  /// grants to the link manager (which checks each one itself)
  private func receiveLinks(_ links: PeerLinksState) async {
    Self.storeLinks(links)
    guard let profile = activeBootstrapProfile else { return }
    if coordinatorClient == nil || coordinatorClient?.nodeEndpointValue != links.coordinator {
      stopCoordinator()
      startCoordinator(profile: profile)
      return
    }
    await linkManager?.update(grants: links.grants)
  }

  private static var linksURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("peer-links.json")
  }

  private static func storedLinks() -> PeerLinksState? {
    guard let url = linksURL, let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(PeerLinksState.self, from: data)
  }

  private static func storeLinks(_ links: PeerLinksState) {
    guard let url = linksURL, let data = try? JSONEncoder().encode(links) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }

  private struct LinksMessage: Decodable {
    let command: String
    let links: PeerLinksState
  }

  private struct LinkStatus: Encodable {
    struct Peer: Encodable {
      let key: String
      let wireGuardKey: String
      let opens: Bool
      let attempting: Bool
      let endpoint: String?
      let routes: [String]
      let ports: [String]
      let lastHandshake: Date?
    }
    let present: Bool
    let coordinator: String
    let linkUps: Int
    let peers: [Peer]
    let wireGuard: [PacketTunnelWireGuardAdapter.RuntimePeer]
  }

  private func linkStatus() async -> LinkStatus {
    var peers: [LinkStatus.Peer] = []
    for entry in await linkManager?.status ?? [] {
      peers.append(LinkStatus.Peer(
        key: entry.peer.key, wireGuardKey: entry.peer.wireGuardKey, opens: entry.opens, attempting: entry.attempting,
        endpoint: entry.peer.endpoint, routes: entry.peer.routes, ports: entry.peer.ports.map { "\($0.protocol)/\($0.port)" },
        lastHandshake: await wireGuardAdapter.lastHandshake(wireGuardKey: entry.peer.wireGuardKey)
      ))
    }
    return LinkStatus(
      present: coordinatorClient?.registered ?? false, coordinator: coordinatorClient?.nodeEndpointValue ?? "",
      linkUps: await linkManager?.linkUps ?? 0, peers: peers, wireGuard: await wireGuardAdapter.runtimePeers()
    )
  }

  private func handleInviterBootstrap(_ event: CoordinatorClient.BootstrapEvent) async {
    guard let inviter else { return }
    extensionDiagnostics("inviter push replayId=\(event.tokenDigest.prefix(8)) joiner=\(event.joinerKey.prefix(8))")
    inviter.expectBootstrap(
      replayId: event.tokenDigest,
      joinerServiceKey: event.joinerKey
    )
    // Opens this side's NAT for the joiner's request: a few datagrams from WireGuard's socket to where the node saw the
    // joiner's (and its declared addresses), while the joiner sends its request here
    func endpoint(_ address: String, _ port: UInt16) -> String {
      address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
    var joiner = event.candidates.map { endpoint($0.address, $0.port) }
    if !event.observedEndpoint.address.isEmpty, event.observedEndpoint.port != 0 {
      joiner.insert(endpoint(event.observedEndpoint.address, event.observedEndpoint.port), at: 0)
    }
    let targets = joiner.filter { !$0.hasPrefix("0.0.0.0:") && !$0.hasPrefix("[::]:") }
    extensionDiagnostics("inviter punch \(targets)")
    let adapter = wireGuardAdapter
    Task {
      for _ in 0..<8 {
        for target in targets { try? await adapter.sendBootstrapDatagram(to: target, BootstrapDatagrams.punch) }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
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
    if let message = try? JSONDecoder().decode(LinksMessage.self, from: messageData), message.command == "links" {
      await receiveLinks(message.links)
      return try? JSONEncoder().encode(MemberPeersResponse(ok: true))
    }
    if let message = try? JSONDecoder().decode(ExtensionNativeJoinMessage.self, from: messageData) {
      return await handleNativeJoinMessage(message)
    } else if let message = try? JSONDecoder().decode(ExtensionBootstrapMessage.self, from: messageData) {
      return await handleBootstrapMessage(message)
    } else {
      do {
        let message = try JSONDecoder().decode(GatewayProviderMessage.self, from: messageData)
        guard ["gatewayStatus", "gatewayStats", "gatewayRenewed", "exitStatus", "keychainProof", "inviterStatus", "memberPeers", "linkStatus"].contains(message.command) else { return nil }
        switch message.command {
        case "gatewayStatus":
          return try JSONEncoder().encode(StateResponse(state: gatewayServingState))
        case "gatewayStats":
          return await wireGuardAdapter.gatewayStats().map { Data($0.utf8) }
        case "gatewayRenewed":
          // The app saved a newer grant for the same gateway: only the expiry moves, the tunnel keeps its flows
          let renewed = try Profile.load()
          guard let active = activeBootstrapProfile, let grant = renewed.gatewayGrant, let current = active.gatewayGrant,
                grant.gatewayWireGuardKey == current.gatewayWireGuardKey, grant.ipv4 == current.ipv4,
                grant.ipv6 == current.ipv6, renewed.overlayIPv4Address == active.overlayIPv4Address else { return nil }
          activeBootstrapProfile = renewed
          exitState = routesThroughGateway ? .connected : .fallback
          scheduleGatewayHealth(renewed)
          watchGatewayPath(renewed)
          Self.writeDiagnostics("gateway grant renewed until \(grant.expiresAt), fallback \(renewed.fallsBack ? "on" : "off")")
          return try JSONEncoder().encode(MemberPeersResponse(ok: true))
        case "exitStatus":
          return try JSONEncoder().encode(StateResponse(state: exitState))
        #if DEBUG
        case "keychainProof":
          let key = try KeyChain.hubIdentity()
          let signature = key.sign(text: "hub-network/readiness-keychain-proof/v1")
          let encoded = try JSONEncoder().encode(
            KeychainProof(publicKey: key.publicKey(), signature: signature)
          )
          return encoded
        #endif
        case "inviterStatus":
          let key = try? KeyChain.hubIdentity()
          let status = InviterStatus(
            registered: inviterRegistered,
            serviceKey: key?.publicKey() ?? "",
            listenerEndpoint: inviterListener.map { "\(inviterAdvertiseAddress ?? "0.0.0.0"):\($0.port ?? 0)" } ?? ""
          )
          return try JSONEncoder().encode(status)
        case "linkStatus":
          let encoder = JSONEncoder()
          encoder.dateEncodingStrategy = .iso8601
          return try encoder.encode(await linkStatus())
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
        // The inviter's candidates reach it on its own network, the address the node saw it at reaches it across NAT:
        // try them all at once. A declared candidate with an unspecified address (an inviter bound to all interfaces)
        // keeps its port on the node-observed host.
        let declared = peer.candidates.map(Self.bootstrapEndpoint)
        var targets: [String] = []
        for candidate in peer.candidates {
          targets.append(candidate.address == "0.0.0.0" || candidate.address == "::"
            ? Self.bootstrapEndpoint(InvitationBootstrapClient.ObservedEndpoint(
                version: peer.observedEndpoint.version, key: peer.observedEndpoint.key,
                transport: "udp", address: peer.observedEndpoint.address, port: candidate.port
              ))
            : Self.bootstrapEndpoint(candidate))
        }
        if !peer.observedEndpoint.address.isEmpty, peer.observedEndpoint.port != 0 {
          targets.append(Self.bootstrapEndpoint(peer.observedEndpoint))
        }
        targets = targets.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        Self.writeDiagnostics("exchange targets \(targets)")
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
        let adapter = wireGuardAdapter
        let (response, answered) = try await DirectBootstrapClient.exchange(
          targets: targets,
          request: request,
          expectedInviterServiceKey: start.invitingKey,
          timeout: min(20, max(5, ISO8601DateFormatter.js.date(from: start.expiresAt)?.timeIntervalSinceNow ?? 20)),
          datagrams: adapter.bootstrapDatagrams,
          send: { target, frame in try await adapter.sendBootstrapDatagram(to: target, frame) }
        )
        Self.writeDiagnostics("bootstrap ok from \(answered) hubProHost=\(response.hubProHost) inviterV4=\(response.inviterAddress.ipv4) joinerV4=\(response.joinerAddress.ipv4) endpoint=\(response.endpoints.first.map(Self.directBootstrapEndpoint) ?? "none")")
        let wireGuardEndpoint = Self.wireGuardEndpoint(response, answered: answered, declared: declared)
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
    // overlay IPv4 is also the hub-server host, so drop the hub-server entry when it
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

  /// `throughGateway` false sends only the overlay through the tunnel, while a gateway the profile falls back from
  /// can't be reached
  static func networkSettings(
    for profile: Profile, dnsServer: Address? = nil, throughGateway: Bool = true
  ) throws -> NEPacketTunnelNetworkSettings {
    try profile.validate()
    let ipv4 = try Address(overlay: profile.overlayIPv4Address)
    let ipv6 = try Address(overlay: profile.overlayIPv6Address)

    // NetworkExtension rejects loopback values here even though
    // `tunnelRemoteAddress` is only descriptive for a peerless membership.
    // Use TEST-NET-1 when no real WireGuard peer endpoint exists.
    // It must be an IP address: a named endpoint (`mac.local:51820`) gets the placeholder, WireGuard resolves the name.
    let remoteAddress = profile.peerEndpoint.flatMap(Self.endpointHost)
      .flatMap { IPv4Address($0) != nil || IPv6Address($0) != nil ? $0 : nil } ?? "192.0.2.1"
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
    let ipv4Settings = NEIPv4Settings(
      addresses: [ipv4.string],
      subnetMasks: ["255.255.255.255"]
    )
    ipv4Settings.includedRoutes = throughGateway && profile.gatewayGrant?.ipv4 == true
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
    ipv6Settings.includedRoutes = throughGateway && profile.gatewayGrant?.ipv6 == true
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
    dnsSettings.matchDomains = throughGateway && profile.usesGateway ? [""] : [profile.dnsSuffix]
    dnsSettings.matchDomainsNoSearch = true
    settings.dnsSettings = dnsSettings

    settings.mtu = 1280
    return settings
  }

  /// Network settings for the temporary direct bootstrap link. The joiner's
  /// assigned point-to-point addresses are the tunnel addresses; overlay
  /// routes keep hub-server (reachable through the inviter) inside the tunnel.
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
          if profile.fallsBack {
            // This device's own network from now on; the overlay stays
            self.gatewayPathTask?.cancel()
            await self.routeThroughGateway(false, profile)
            return
          }
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


  /// For a profile that falls back: this device's traffic goes through the gateway while it answers, and through
  /// this device's own network until it does and while it doesn't. Without fallback the gateway always takes it.
  private func watchGatewayPath(_ profile: Profile) {
    // A renewal is for the same gateway: the watch goes on, as a new one would take the bytes so far for an answer
    if profile.fallsBack, gatewayPathTask != nil { return }
    gatewayPathTask?.cancel()
    guard profile.fallsBack, let gatewayKey = profile.gatewayGrant?.gatewayWireGuardKey else {
      gatewayPathTask = nil
      if !routesThroughGateway {
        Task { await routeThroughGateway(true, profile) }
      }
      return
    }
    let current = routesThroughGateway
    gatewayPathTask = Task { [weak self] in
      var path = GatewayPath(reachable: current)
      while !Task.isCancelled {
        guard let self else { return }
        let received = await self.wireGuardAdapter.runtimePeers().first { $0.wireGuardKey == gatewayKey }?.rxBytes ?? 0
        if let reachable = path.update(receivedBytes: received, now: Date()), reachable != self.routesThroughGateway {
          await self.routeThroughGateway(reachable, profile)
        }
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  private func routeThroughGateway(_ through: Bool, _ profile: Profile) async {
    do {
      try await setTunnelNetworkSettings(
        Self.networkSettings(for: profile, dnsServer: gatewayDNSServer, throughGateway: through)
      )
      routesThroughGateway = through
      exitState = through ? .connected : .fallback
      Self.writeDiagnostics(through ? "gateway answers: internet goes through it" : "gateway doesn't answer: internet goes through this device's network")
    } catch {
      Self.writeDiagnostics("gateway routes not switched: \(error)")
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
  /// The inviter's WireGuard endpoint for the temporary link. An inviter that serves the exchange on its WireGuard
  /// socket declares that socket as its candidate and endpoint: the address that answered is then WireGuard's, with
  /// the NAT hole the exchange just opened. An inviter with a separate listener (the Go agent, older apps) gets its
  /// declared WireGuard port on the host that answered when it declares no address.
  private static func wireGuardEndpoint(
    _ response: DirectBootstrapResponse,
    answered: String,
    declared: [String]
  ) -> String {
    if let endpoint = response.endpoints.first, declared.contains(directBootstrapEndpoint(endpoint)) {
      return answered
    }
    let exchangeTarget = answered
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
    /// `fallback`: the gateway doesn't answer and this device's own network carries its traffic
    case disabled, connected, blocking, fallback
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

extension NEProviderStopReason {
  /// The reason's case name, for diagnostics
  var name: String {
    switch self {
    case .none: "none"
    case .userInitiated: "userInitiated"
    case .providerFailed: "providerFailed"
    case .noNetworkAvailable: "noNetworkAvailable"
    case .unrecoverableNetworkChange: "unrecoverableNetworkChange"
    case .providerDisabled: "providerDisabled"
    case .authenticationCanceled: "authenticationCanceled"
    case .configurationFailed: "configurationFailed"
    case .idleTimeout: "idleTimeout"
    case .configurationDisabled: "configurationDisabled"
    case .configurationRemoved: "configurationRemoved"
    case .superceded: "superceded"
    case .userLogout: "userLogout"
    case .userSwitch: "userSwitch"
    case .connectionFailed: "connectionFailed"
    case .sleep: "sleep"
    case .appUpdate: "appUpdate"
    case .internalError: "internalError"
    @unknown default: "unknown"
    }
  }
}
