import HubService
import NetworkExtension
import OSLog
import WireGuardKit

/// Extension-local owner for WireGuardKit's userspace backend.
///
/// Hub app targets must not import this file or WireGuardKit. Configuration
/// construction stays separate so grant verification can happen before a peer
/// reaches the backend.
final class PacketTunnelWireGuardAdapter {
  private let adapter: WireGuardAdapter
  private let bootstrapQueue = DispatchQueue(label: "dev.v57.Hub.PacketTunnelExtension.bootstrap-peers")
  private var isStarted = false
  private var baseConfiguration: TunnelConfiguration?
  private var bootstrapPeers: [String: PeerConfiguration] = [:]

  init(provider: NEPacketTunnelProvider) {
    let logger = Logger(
      subsystem: "dev.v57.Hub.PacketTunnelExtension",
      category: "WireGuardBackend"
    )
    adapter = WireGuardAdapter(with: provider) { level, message in
      logger.log(
        level: level == .error ? .error : .debug,
        "[\(String(describing: level), privacy: .public)] \(message, privacy: .public)"
      )
    }
  }

  func start(configuration: TunnelConfiguration) async throws {
    do {
      try await adapter.start(tunnelConfiguration: configuration)
      isStarted = true
      baseConfiguration = configuration
      bootstrapPeers.removeAll()
    } catch {
      let logger = Logger(
        subsystem: "dev.v57.Hub.PacketTunnelExtension",
        category: "WireGuard"
      )
      switch error as? WireGuardAdapterError {
      case .cannotLocateTunnelFileDescriptor:
        logger.error("start failed: cannot locate tunnel file descriptor")
      case .invalidState:
        logger.error("start failed: invalid adapter state")
      case .dnsResolution(let errors):
        logger.error(
          "start failed: endpoint resolution: \(String(reflecting: errors), privacy: .public)"
        )
      case .setNetworkSettings(let underlying):
        logger.error(
          "start failed: network settings: \(String(reflecting: underlying), privacy: .public)"
        )
      case .startWireGuardBackend(let handle):
        logger.error("start failed: backend handle \(handle, privacy: .public)")
      case .sendBackendDatagram(let code):
        logger.error("probe failed: backend code \(code, privacy: .public)")
      case nil:
        logger.error("start failed: \(String(reflecting: error), privacy: .public)")
      }
      throw error
    }
  }

  func start(profile: Profile) async throws {
    try await start(configuration: Self.configuration(for: profile))
  }

  /// Replaces transaction-scoped bootstrap peers and base configuration in one
  /// backend update. State changes only after WireGuard accepts full committed
  /// membership configuration.
  func commitBootstrapMembership(
    assignmentId: String,
    profile: Profile
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      bootstrapQueue.async { [weak self] in
        guard let self,
            self.isStarted,
            let bootstrapPeer = self.bootstrapPeers[assignmentId],
            let base = try? Self.configuration(for: profile)
        else {
          continuation.resume(
            throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
          )
          return
        }
        // The committed membership keeps the inviter bootstrap peer so the
        // joiner can still reach hub-pro on the inviter's overlay host after
        // the temporary link is replaced (Go parity: LoadInviterPeers /
        // inviter.json). The peer's allowed IPs already cover the inviter
        // addresses plus the hub-pro host. Its endpoint stays the inviter's
        // WireGuard socket, which remains valid after the commit.
        let configuration = TunnelConfiguration(
          name: base.name,
          interface: base.interface,
          peers: [bootstrapPeer]
        )
        self.adapter.updateBackend(tunnelConfiguration: configuration) { error in
          self.bootstrapQueue.async {
            if let error {
              continuation.resume(throwing: error)
              return
            }
            self.baseConfiguration = configuration
            self.bootstrapPeers.removeAll()
            continuation.resume()
          }
        }
      }
    }
  }

  /// Replaces the base WireGuard configuration with the temporary
  /// point-to-point bootstrap link: the joiner's assigned addresses on the
  /// interface and the inviter peer covering the inviter's addresses plus
  /// hub-pro. Used after the direct bootstrap exchange, before ordinary
  /// `hub/net/bind` assigns permanent overlay addresses.
  func configureBootstrapLink(
    assignmentId: String,
    inviterWireGuardKey: String,
    joinerAddresses: [String],
    inviterAddresses: [String],
    hubProHost: String,
    endpoint: String
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      bootstrapQueue.async { [weak self] in
        guard let self,
              self.isStarted,
              self.bootstrapPeers[assignmentId] != nil,
              let base = self.baseConfiguration else {
          extensionDiagnostics("configureBootstrapLink guard: started=\(self?.isStarted ?? false) peer=\(self?.bootstrapPeers[assignmentId] != nil) base=\(self?.baseConfiguration != nil)")
          continuation.resume(
            throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
          )
          return
        }
        do {
          let interfaceAddresses = try Self.bootstrapHostRoutes(joinerAddresses)
          // The inviter's overlay IPv4 is also the hub-pro host, so the
          // combined list can contain duplicates — dedupe before the route
          // validation (which rejects repeated entries).
          let allowedRoutes = try Self.bootstrapHostRoutes(
            Array(Set(inviterAddresses + [hubProHost]))
          )
          let privateKey = base.interface.privateKey
          var interface = InterfaceConfiguration(privateKey: privateKey)
          interface.addresses = interfaceAddresses
          interface.mtu = base.interface.mtu

          guard let keyData = Data(base64Encoded: inviterWireGuardKey),
                let publicKey = PublicKey(rawValue: keyData),
                let parsedEndpoint = Endpoint(from: endpoint)
          else {
            continuation.resume(
              throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
            )
            return
          }
          var peer = PeerConfiguration(publicKey: publicKey)
          peer.allowedIPs = allowedRoutes
          peer.endpoint = parsedEndpoint
          peer.persistentKeepAlive = 25

          let configuration = TunnelConfiguration(
            name: base.name,
            interface: interface,
            peers: [peer]
          )
          let semaphore = DispatchSemaphore(value: 0)
          var result: Error?
          self.adapter.updateBackend(tunnelConfiguration: configuration) {
            result = $0
            semaphore.signal()
          }
          semaphore.wait()
          if let result {
            continuation.resume(throwing: result)
          } else {
            self.baseConfiguration = configuration
            continuation.resume()
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func bootstrapHostRoutes(
    _ values: [String]
  ) throws -> [IPAddressRange] {
    let routes = values.map { value -> IPAddressRange? in
      let raw: Data
      if let ipv4 = IPv4Address(value) {
        raw = ipv4.rawValue
      } else if let ipv6 = IPv6Address(value) {
        raw = ipv6.rawValue
      } else {
        return nil
      }
      guard isOverlayAddress(raw) else { return nil }
      return IPAddressRange(
        from: "\(value)/\(raw.count == 4 ? 32 : 128)"
      )
    }
    guard routes.allSatisfy({ $0 != nil }),
          Set(routes.map { $0!.stringRepresentation }).count == routes.count else {
      throw PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
    }
    return routes.compactMap { $0 }
  }

  struct KeychainError: Error {
    var status: OSStatus
  }
  
  private static func configuration(for profile: Profile) throws -> TunnelConfiguration {
    try profile.validate()
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.v57.Hub.network.wireguard.v1",
      kSecAttrAccount as String: "private-key",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
      throw KeychainError(status: status)
    }
    guard let privateKey = PrivateKey(rawValue: data),
          let ipv4 = IPAddressRange(from: profile.overlayIPv4Address),
          let ipv6 = IPAddressRange(from: profile.overlayIPv6Address)
    else {
      throw PacketTunnelWireGuardConfigurationError.invalidConfiguration
    }

    var interface = InterfaceConfiguration(privateKey: privateKey)
    interface.addresses = [ipv4, ipv6]
    interface.mtu = 1280
    if profile.usesGateway,
       let dnsAddress = profile.dnsServerAddress,
       let dnsServer = DNSServer(from: dnsAddress) {
      interface.dns = [dnsServer]
    }

    var peers = [PeerConfiguration]()
    if let grant = profile.connectionGrant,
       let endpointValue = profile.peerEndpoint,
       let endpoint = Endpoint(from: endpointValue),
       let peerKeyData = Data(base64Encoded: grant.targetWireGuardKey),
       let peerKey = PublicKey(rawValue: peerKeyData)
    {
      let destinationPrefix = grant.destinationAddress.contains(":") ? 128 : 32
      guard let destination = IPAddressRange(
        from: "\(grant.destinationAddress)/\(destinationPrefix)"
      ) else {
        throw PacketTunnelWireGuardConfigurationError.invalidConfiguration
      }
      var peer = PeerConfiguration(publicKey: peerKey)
      peer.endpoint = endpoint
      // Candidate endpoint is transport metadata only. Authorization and
      // routing come exclusively from signed grant destination.
      peer.allowedIPs = [destination]
      peer.persistentKeepAlive = 25
      peers = [peer]
    } else if let grant = profile.gatewayGrant,
              let endpointValue = profile.peerEndpoint,
              let endpoint = Endpoint(from: endpointValue),
              let peerKeyData = Data(base64Encoded: grant.gatewayWireGuardKey),
              let peerKey = PublicKey(rawValue: peerKeyData)
    {
      var peer = PeerConfiguration(publicKey: peerKey)
      peer.endpoint = endpoint
      var allowedIPs = [IPAddressRange]()
      if grant.ipv4, let route = IPAddressRange(from: "0.0.0.0/0") {
        allowedIPs.append(route)
      }
      if grant.ipv6, let route = IPAddressRange(from: "::/0") {
        allowedIPs.append(route)
      }
      guard !allowedIPs.isEmpty else {
        throw PacketTunnelWireGuardConfigurationError.invalidConfiguration
      }
      peer.allowedIPs = allowedIPs
      peer.persistentKeepAlive = 25
      peers = [peer]
    }

    return TunnelConfiguration(
      name: "Hub Network",
      interface: interface,
      peers: peers
    )
  }

  func stop() async {
    guard isStarted else { return }
    try? await adapter.stop()
    isStarted = false
    baseConfiguration = nil
    bootstrapPeers.removeAll()
  }

  /// Adds or replaces one transaction-scoped peer. Repeating an identical
  /// install is a no-op. Only host routes from the signed assignment are
  /// accepted; base membership/resource/gateway peers remain byte-for-byte.
  func installBootstrapPeer(
    assignmentId: String,
    publicKeyBase64: String,
    overlayAddresses: [String],
    hubProBootstrapAddresses: [String],
    endpoint: String
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      bootstrapQueue.async { [weak self] in
        guard let self else {
          continuation.resume(
            throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
          )
          return
        }
        guard !assignmentId.isEmpty,
            let keyData = Data(base64Encoded: publicKeyBase64),
            let publicKey = PublicKey(rawValue: keyData),
            let parsedEndpoint = Endpoint(from: endpoint)
        else {
          extensionDiagnostics(
            "installBootstrapPeer guard: id=\(assignmentId.isEmpty) keyData=\(Data(base64Encoded: publicKeyBase64) != nil) pub=\((try? PublicKey(rawValue: Data(base64Encoded: publicKeyBase64) ?? Data())) != nil) ep=\(Endpoint(from: endpoint) != nil) epRaw=\(endpoint)"
          )
          continuation.resume(throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer)
          return
        }
        let destinations = overlayAddresses + hubProBootstrapAddresses
        guard (try? BootstrapTransactionGuard.validateHostRoutes(
          overlayAddresses: overlayAddresses,
          hubProBootstrapAddresses: hubProBootstrapAddresses
        )) != nil else {
          extensionDiagnostics("installBootstrapPeer validateHostRoutes failed: overlay=\(overlayAddresses) hubPro=\(hubProBootstrapAddresses)")
          continuation.resume(throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer)
          return
        }
        let routes = destinations.compactMap(Self.bootstrapHostRoute)
        guard routes.count == destinations.count,
              Set(routes.map(Self.routeIdentity)).count == routes.count
        else {
          extensionDiagnostics("installBootstrapPeer routes invalid: destinations=\(destinations) routes=\(routes.map(\.stringRepresentation))")
          continuation.resume(throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer)
          return
        }
        var peer = PeerConfiguration(publicKey: publicKey)
        peer.allowedIPs = routes
        peer.endpoint = parsedEndpoint
        peer.persistentKeepAlive = 25
        if self.bootstrapPeers[assignmentId] == peer {
          continuation.resume()
          return
        }
        let previous = self.bootstrapPeers[assignmentId]
        self.bootstrapPeers[assignmentId] = peer
        if let error = self.applyBootstrapPeers() {
          self.bootstrapPeers[assignmentId] = previous
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /// Removes only peer owned by `assignmentId`. Missing peer is success.
  func removeBootstrapPeer(assignmentId: String) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      bootstrapQueue.async { [weak self] in
        guard let self else {
          continuation.resume(
            throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
          )
          return
        }
        guard let previous = self.bootstrapPeers.removeValue(forKey: assignmentId) else {
          continuation.resume()
          return
        }
        if let error = self.applyBootstrapPeers() {
          self.bootstrapPeers[assignmentId] = previous
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /// Installs a temporary joiner peer on the inviter side.
  ///
  /// Unlike `installBootstrapPeer`, the inviter's joiner peer needs no fixed
  /// endpoint — the joiner initiates the WireGuard handshake to the inviter's
  /// bootstrap listener address, and WireGuard learns the peer's endpoint from
  /// that handshake. Allowed IPs are the joiner's temporary point-to-point
  /// addresses, later extended with the joiner's permanent overlay addresses
  /// once it binds at hub-pro.
  func installInviterPeer(
    assignmentId: String,
    publicKeyBase64: String,
    allowedIPs: [String],
    endpoint: String? = nil
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      bootstrapQueue.async { [weak self] in
        guard let self else {
          continuation.resume(
            throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
          )
          return
        }
        guard !assignmentId.isEmpty,
              let keyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = PublicKey(rawValue: keyData),
              let routes = try? Self.inviterAllowedRoutes(allowedIPs) else {
          continuation.resume(
            throwing: PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
          )
          return
        }
        var peer = PeerConfiguration(publicKey: publicKey)
        peer.allowedIPs = routes
        if let endpoint, let parsedEndpoint = Endpoint(from: endpoint) {
          peer.endpoint = parsedEndpoint
        }
        peer.persistentKeepAlive = 25
        if self.bootstrapPeers[assignmentId] == peer {
          continuation.resume()
          return
        }
        let previous = self.bootstrapPeers[assignmentId]
        self.bootstrapPeers[assignmentId] = peer
        if let error = self.applyBootstrapPeers() {
          self.bootstrapPeers[assignmentId] = previous
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /// Parses allowed-IPs for an inviter-side joiner peer: host routes
  /// (`/32`, `/128`) inside the frozen overlay prefixes. Both the temporary
  /// bootstrap addresses (`100.127.254.x`) and the permanent overlay
  /// addresses (`100.96.x.y`) live inside `100.96.0.0/11`; the v6 pool
  /// `fd48:5542:4e45:fffe::/64` sits inside `fd48:5542:4e45::/48`.
  private static func inviterAllowedRoutes(_ values: [String]) throws -> [IPAddressRange] {
    guard !values.isEmpty, Set(values).count == values.count else {
      throw PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
    }
    let routes = values.compactMap { value -> IPAddressRange? in
      guard let route = IPAddressRange(from: value) else { return nil }
      let isHost = route.networkPrefixLength == (route.address.rawValue.count == 4 ? 32 : 128)
      if isHost {
        guard isOverlayAddress(route.address.rawValue) else { return nil }
        return route
      }
      // Or the frozen overlay prefixes themselves (100.96.0.0/11,
      // fd48:5542:4e45::/48): the inviter cannot know the joiner's
      // hub-pro-assigned address at install time, so the peer scopes the
      // whole overlay. Interim until per-address extension from
      // hub/net/list lands (Go parity: UpdateJoinerAllowedIPs).
      guard isOverlayPrefix(route) else { return nil }
      return route
    }
    guard routes.count == values.count,
          Set(routes.map(Self.routeIdentity)).count == routes.count else {
      throw PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
    }
    return routes
  }

  private func applyBootstrapPeers() -> Error? {
    guard isStarted, let baseConfiguration else {
      return PacketTunnelWireGuardConfigurationError.invalidBootstrapPeer
    }
    let baseKeys = Set(baseConfiguration.peers.map(\.publicKey))
    let baseRoutes = Set(
      baseConfiguration.peers.flatMap(\.allowedIPs).map(Self.routeIdentity)
    )
    let bootstrapRoutes = bootstrapPeers.values.flatMap(\.allowedIPs)
    guard bootstrapPeers.values.allSatisfy({ !baseKeys.contains($0.publicKey) }),
          Set(bootstrapPeers.values.map(\.publicKey)).count == bootstrapPeers.count,
          bootstrapRoutes.allSatisfy({ !baseRoutes.contains(Self.routeIdentity($0)) }),
          Set(bootstrapRoutes.map(Self.routeIdentity)).count == bootstrapRoutes.count
    else {
      return PacketTunnelWireGuardConfigurationError.peerConflict
    }
    let configuration = TunnelConfiguration(
      name: baseConfiguration.name,
      interface: baseConfiguration.interface,
      peers: baseConfiguration.peers + bootstrapPeers.keys.sorted().compactMap {
        bootstrapPeers[$0]
      }
    )
    let semaphore = DispatchSemaphore(value: 0)
    var result: Error?
    adapter.updateBackend(tunnelConfiguration: configuration) {
      result = $0
      semaphore.signal()
    }
    semaphore.wait()
    return result
  }

  private static func bootstrapHostRoute(_ value: String) -> IPAddressRange? {
    guard let route = IPAddressRange(from: value) else { return nil }
    let expectedPrefix: UInt8 = route.address.rawValue.count == 4 ? 32 : 128
    guard route.networkPrefixLength == expectedPrefix,
          isOverlayAddress(route.address.rawValue) else { return nil }
    return route
  }

  private static func isOverlayAddress(_ value: Data) -> Bool {
    let bytes = Array(value)
    if bytes.count == 4 { return bytes[0] == 100 && (bytes[1] & 0b1110_0000) == 96 }
    return bytes.count == 16 && bytes.starts(with: [0xfd, 0x48, 0x55, 0x42, 0x4e, 0x45])
  }

  /// The frozen overlay prefixes themselves: `100.96.0.0/11` and
  /// `fd48:5542:4e45::/48`. Only these exact prefixes are accepted as
  /// non-host scopes for an inviter-side joiner peer.
  private static func isOverlayPrefix(_ route: IPAddressRange) -> Bool {
    let bytes = Array(route.address.rawValue)
    if bytes.count == 4 {
      return route.networkPrefixLength == 11 && bytes == [100, 96, 0, 0]
    }
    return route.networkPrefixLength == 48
      && bytes.starts(with: [0xfd, 0x48, 0x55, 0x42, 0x4e, 0x45])
      && bytes[6..<16].allSatisfy { $0 == 0 }
  }

  private static func routeIdentity(_ route: IPAddressRange) -> String {
    "\(route.address)/\(route.networkPrefixLength)"
  }

  func hasRecentHandshake(maximumAge: TimeInterval = 30) async -> Bool {
    let configuration = await adapter.getRuntimeConfiguration()
    guard let configuration else { return false }
    let seconds = configuration
      .split(separator: "\n")
      .first(where: { $0.hasPrefix("last_handshake_time_sec=") })
      .flatMap { Int64($0.dropFirst("last_handshake_time_sec=".count)) }
    guard let seconds, seconds > 0 else { return false }
    return Date().timeIntervalSince1970 - TimeInterval(seconds) <= maximumAge
  }

  func sendObservationProbe(
    endpoint: String,
    payload: Data
  ) async throws {
    let resolved = Self.resolvedEndpoint(endpoint)
    if resolved != endpoint {
      extensionDiagnostics("probe endpoint resolved \(endpoint) -> \(resolved)")
    } else {
      extensionDiagnostics("probe endpoint unresolvable, using \(endpoint)")
    }
    try await adapter.sendBackendDatagram(
      endpoint: resolved, payload: payload
    )
  }

  /// The wg-go backend's `ParseEndpoint` uses the Go resolver, which does not
  /// handle mDNS (.local) names — a node endpoint like `mac.local:1964`
  /// fails with `-2`. Resolve the host to a numeric address first
  /// (getaddrinfo is mDNS-aware); falls back to the input when it is already
  /// numeric or unresolvable.
  ///
  /// mDNS may return several addresses for the host (one per interface). The
  /// FIRST is not necessarily routable: after a reboot the Mac can advertise
  /// a link-local en9 (169.254.x.x) ahead of the LAN IP, and the probe then
  /// targets an address the phone cannot reach. Iterate all results and
  /// prefer the first routable IPv4 (same rule as ReachableAddress).
  ///
  /// mDNS is UDP-multicast and LOSSY: getaddrinfo can transiently fail with
  /// EAI_NONAME (gai=8) even though the host resolved a moment ago. Retry a
  /// few times, and keep the last successful resolution so a transient
  /// failure reuses the known-good numeric endpoint instead of falling back
  /// to the raw `.local` hostname (which wg-go cannot parse → -2).
  private static var cachedResolution: String?

  private static func resolvedEndpoint(_ endpoint: String) -> String {
    var host = endpoint
    var port = ""
    if let colon = endpoint.lastIndex(of: ":") {
      host = String(endpoint[..<colon])
      port = String(endpoint[endpoint.index(after: colon)...])
    }
    guard !port.isEmpty, !host.isEmpty, !host.hasPrefix("["),
          host.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) == nil
    else { return endpoint }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    var result: UnsafeMutablePointer<addrinfo>?
    var gai: Int32 = EAI_NONAME
    for attempt in 0..<4 {
      result = nil
      gai = getaddrinfo(host, nil, &hints, &result)
      if gai == 0, result != nil { break }
      if attempt < 3 { usleep(150_000 * useconds_t(attempt + 1)) }
    }
    guard gai == 0, let first = result else {
      extensionDiagnostics("probe resolve failed for \(host) gai=\(gai)")
      if let cached = cachedResolution {
        extensionDiagnostics("probe resolve using cached \(host) -> \(cached)")
        return cached
      }
      return endpoint
    }
    defer { freeaddrinfo(result) }
    var fallback: String?
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let addr = cursor {
      var hostC = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let rc = getnameinfo(
        addr.pointee.ai_addr, addr.pointee.ai_addrlen,
        &hostC, socklen_t(hostC.count), nil, 0, NI_NUMERICHOST
      )
      if rc == 0 {
        let ip = String(cString: hostC)
        if fallback == nil { fallback = ip }
        if ReachableAddress.isRoutableIPv4(ip) {
          extensionDiagnostics("probe resolve \(host) -> \(ip):\(port) (routable)")
          cachedResolution = "\(ip):\(port)"
          return "\(ip):\(port)"
        }
        extensionDiagnostics("probe resolve \(host) -> \(ip):\(port) (skipped, unroutable)")
      }
      cursor = addr.pointee.ai_next
    }
    if let fallback {
      extensionDiagnostics("probe resolve \(host) -> no routable address, using \(fallback):\(port)")
      cachedResolution = "\(fallback):\(port)"
      return "\(fallback):\(port)"
    }
    return endpoint
  }

  func listenPort() async -> UInt16? {
    let configuration = await adapter.getRuntimeConfiguration()
    let port = configuration?
      .split(separator: "\n")
      .first(where: { $0.hasPrefix("listen_port=") })
      .flatMap { UInt16($0.dropFirst("listen_port=".count)) }
    return port
  }
}

extension WireGuardAdapter {
  func start(tunnelConfiguration: TunnelConfiguration) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      start(tunnelConfiguration: tunnelConfiguration) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func stop() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stop { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func update(tunnelConfiguration: TunnelConfiguration) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      update(tunnelConfiguration: tunnelConfiguration) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func updateBackend(tunnelConfiguration: TunnelConfiguration) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      updateBackend(tunnelConfiguration: tunnelConfiguration) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func sendBackendDatagram(endpoint: String, payload: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      sendBackendDatagram(endpoint: endpoint, payload: payload) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func getRuntimeConfiguration() async -> String? {
    await withCheckedContinuation { continuation in
      getRuntimeConfiguration {
        continuation.resume(returning: $0)
      }
    }
  }
}

enum PacketTunnelWireGuardConfigurationError: Error {
  case invalidConfiguration
  case invalidBootstrapPeer
  case peerConflict
}
