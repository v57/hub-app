import CryptoKit
import Foundation
import Network

/// A host candidate a device declares for a link, or the endpoint the node observed
struct LinkEndpoint: Codable, Hashable, Sendable {
  let address: String
  let port: UInt16

  /// `host:port`, IPv6 in brackets, as WireGuard takes it
  var endpoint: String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }
}

/// A hub-signed link between two devices of one hub (hub-net-node's PROTOCOL.md, "Peer links"). `hub` links a member
/// (`a`) and the hub's machine (`b`): the member routes `aViaB` through the machine and may open `aToB` on it.
struct PeerLinkGrant: Codable, Equatable, Sendable {
  struct Side: Codable, Equatable, Sendable {
    let key: String
    let wireGuardKey: String
    let member: String
    let addresses: [String]
  }

  struct Port: Codable, Hashable, Sendable {
    let `protocol`: String
    let port: UInt16
  }

  let version: Int
  let grantId: String
  let hubKey: String
  let hubNetworkId: String
  let purpose: String
  let a: Side
  let b: Side
  let aViaB: [String]
  let bViaA: [String]
  let aToB: [Port]
  let bToA: [Port]
  let issuedAt: String
  let expiresAt: String
  let signature: String

  static let domain = "hub-network/peer-link/v1"
  static let maximumLifetime: TimeInterval = 31 * 24 * 3600
  static let maximumClockSkew: TimeInterval = 30
}

/// `network/links`, as the app forwards it: the grants the hub issued this device and the coordinator to meet the
/// other sides at
struct PeerLinksState: Codable, Equatable, Sendable {
  let version: Int
  let hubKey: String
  let hubNetworkId: String
  let coordinator: String
  let hubHost: Bool
  let grants: [PeerLinkGrant]
}

enum PeerLinkGrantError: Error, Equatable {
  case malformed
  case untrustedHub
  case notASide
  case expired
  case invalidSignature
  case invalidRoutes
}

/// A grant this device checked against the hub key it pinned, seen from this device
struct VerifiedLink: Equatable, Sendable {
  let grant: PeerLinkGrant
  let own: PeerLinkGrant.Side
  let other: PeerLinkGrant.Side
  /// This device is `a`, the side that opens the link
  let opens: Bool
  /// What this device sends through the other
  let routes: [String]
  /// What the other may open on this device
  let exposed: [PeerLinkGrant.Port]
  let expiresAt: Date
}

extension PeerLinkGrant {
  /// Checks everything this device can know on its own: the hub key it pinned, that it is a side, the lifetime, the
  /// signature over the canonical JSON, and that the routes are the other side's own addresses. The coordinator's say
  /// counts for nothing here.
  func verified(trustedHubKey: String, ownKey: String, now: Date = Date()) throws -> VerifiedLink {
    guard version == 1, !grantId.isEmpty, purpose == "hub", a.key != b.key, a.wireGuardKey != b.wireGuardKey,
      !a.addresses.isEmpty, !b.addresses.isEmpty,
      aToB.allSatisfy({ ["tcp", "udp"].contains($0.protocol) }), bToA.allSatisfy({ ["tcp", "udp"].contains($0.protocol) })
    else { throw PeerLinkGrantError.malformed }
    guard hubKey == trustedHubKey else { throw PeerLinkGrantError.untrustedHub }
    let opens: Bool
    switch ownKey {
    case a.key: opens = true
    case b.key: opens = false
    default: throw PeerLinkGrantError.notASide
    }
    guard let issued = CoordinatorClient.parseRFC3339(issuedAt), let expires = CoordinatorClient.parseRFC3339(expiresAt)
    else { throw PeerLinkGrantError.malformed }
    guard issued <= now.addingTimeInterval(Self.maximumClockSkew), expires > now,
      expires.timeIntervalSince(issued) <= Self.maximumLifetime
    else { throw PeerLinkGrantError.expired }
    guard try verifySignature() else { throw PeerLinkGrantError.invalidSignature }
    let own = opens ? a : b
    let other = opens ? b : a
    let routes = opens ? aViaB : bViaA
    // A hub link carries the other device's own addresses and nothing more
    guard Set(routes) == Set(other.addresses.map(Self.hostRoute)), routes.count == other.addresses.count else {
      throw PeerLinkGrantError.invalidRoutes
    }
    return VerifiedLink(
      grant: self, own: own, other: other, opens: opens, routes: routes, exposed: opens ? bToA : aToB,
      expiresAt: expires
    )
  }

  /// Ed25519 by `hubKey` over `domain || 0x00 || uint32BE(len) || canonicalJSON(grant without signature)`
  func verifySignature() throws -> Bool {
    guard let signature = Data(base64Encoded: signature), let raw = Self.rawEd25519Key(spki: hubKey),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { return false }
    guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else {
      throw PeerLinkGrantError.malformed
    }
    object.removeValue(forKey: "signature")
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    var input = Data(Self.domain.utf8)
    input.append(0)
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { input.append(contentsOf: $0) }
    input.append(payload)
    return key.isValidSignature(signature, for: input)
  }

  /// `100.96.0.2` → `100.96.0.2/32`, an IPv6 address → `/128`
  static func hostRoute(_ address: String) -> String {
    address.contains(":") ? "\(address)/128" : "\(address)/32"
  }

  /// The 32-byte key of a base64 Ed25519 SubjectPublicKeyInfo
  static func rawEd25519Key(spki: String) -> Data? {
    let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    guard let der = Data(base64Encoded: spki), der.count == 44, der.prefix(12) == prefix else { return nil }
    return der.suffix(32)
  }
}

/// Runs this device's peer links. Each grant the hub issued this device, and each one another device brings in
/// `link.incoming`, is checked here against the pinned hub key before anything is installed; WireGuard keys come
/// only from those grants. The opening side (`a`) asks the coordinator for the link whenever it has no live path;
/// the other side accepts only what it verified. Both probe the coordinator from WireGuard's own socket, and once
/// `link.ready` arrives they set each other as WireGuard peers and try the other's candidates and observed endpoint
/// in turn, so the handshakes from both ends open the NAT mappings.
actor LinkManager {
  /// One linked device as WireGuard and the inbound filter see it
  struct Peer: Equatable, Sendable {
    let key: String
    let wireGuardKey: String
    /// What this device sends through the peer
    let routes: [String]
    /// The peer's own addresses: packets from them reach only `ports`
    let sources: [String]
    let ports: [PeerLinkGrant.Port]
    var endpoint: String?
  }

  struct Dependencies: Sendable {
    var open: @Sendable (PeerLinkGrant) async throws -> CoordinatorClient.OpenedLink
    var send: @Sendable (_ type: String, _ linkId: String, _ endpoints: [LinkEndpoint]?) async throws -> Void
    /// Sends a datagram to the coordinator from WireGuard's socket
    var probe: @Sendable (Data) async throws -> Void
    var apply: @Sendable ([Peer]) async throws -> Void
    /// The last handshake with the peer of this WireGuard key
    var lastHandshake: @Sendable (String) async -> Date?
    var candidates: @Sendable () async -> [LinkEndpoint]
    var log: @Sendable (String) -> Void
    var now: @Sendable () -> Date = { Date() }
  }

  private struct Attempt {
    let link: VerifiedLink
    let probeToken: String
    let startedAt: Date
    var probing: Task<Void, Never>?
    var punching: Task<Void, Never>?
  }

  /// A path counts as live while handshakes keep coming (WireGuard renews its session every two minutes)
  static let liveHandshakeAge: TimeInterval = 150
  /// How long one endpoint gets to complete a handshake before the next is tried
  var endpointTrial: TimeInterval = 5
  /// How long a link has to come up once ready
  var punchWindow: TimeInterval = 60
  var probeInterval: TimeInterval = 1

  private let ownKey: String
  private let dependencies: Dependencies
  private var trustedHubKey: String
  private var own: [VerifiedLink] = []
  /// Devices that brought a grant this device verified, by their key
  private var admitted: [String: VerifiedLink] = [:]
  private var peers: [String: Peer] = [:]
  private var attempts: [String: Attempt] = [:]
  private var opening: Set<String> = []
  /// The grant each linked device last took, by its key: a new grant (other ports) opens the link again even while
  /// the path is live, since the other side learns ports only from the grant a link brings
  private var delivered: [String: String] = [:]
  private var present = false
  private(set) var linkUps = 0

  init(ownKey: String, trustedHubKey: String, dependencies: Dependencies) {
    self.ownKey = ownKey
    self.trustedHubKey = trustedHubKey
    self.dependencies = dependencies
  }

  /// The grants the hub issued this device; the ones that don't verify are dropped
  func update(grants: [PeerLinkGrant]) async {
    var verified: [VerifiedLink] = []
    for grant in grants {
      do {
        verified.append(try grant.verified(trustedHubKey: trustedHubKey, ownKey: ownKey, now: dependencies.now()))
      } catch {
        dependencies.log("link grant \(grant.grantId.prefix(8)) rejected: \(error)")
      }
    }
    own = verified
    for link in verified {
      let current = peers[link.other.key]
      let endpoint = current?.wireGuardKey == link.other.wireGuardKey ? current?.endpoint : nil
      let peer = Self.peer(for: link, endpoint: endpoint)
      if current != peer { peers[link.other.key] = peer }
    }
    await removeStale()
    await openWhereNeeded()
  }

  /// Presence came (a fresh registration: the node knows no links of this device) or went
  func presenceChanged(_ isPresent: Bool) async {
    present = isPresent
    if !isPresent {
      for attempt in attempts.values {
        attempt.probing?.cancel()
        attempt.punching?.cancel()
      }
      attempts.removeAll()
      opening.removeAll()
      return
    }
    await openWhereNeeded()
  }

  /// Periodic upkeep: drops expired grants and opens links whose path went quiet
  func tick() async {
    await removeStale()
    await openWhereNeeded()
  }

  var status: [(peer: Peer, opens: Bool, attempting: Bool)] {
    peers.values.sorted { $0.key < $1.key }.map { peer in
      (peer, own.contains { $0.other.key == peer.key }, attempts.values.contains { $0.link.other.key == peer.key })
    }
  }

  // MARK: Coordinator messages

  func handle(_ envelope: CoordinatorClient.Envelope) async {
    switch envelope.type {
    case "link.incoming":
      await incoming(envelope)
    case "link.ready":
      guard let linkId = envelope.linkId, var attempt = attempts[linkId] else { return }
      attempt.probing?.cancel()
      attempt.probing = nil
      var endpoints = envelope.endpoints ?? []
      if let observed = envelope.observedEndpoint, observed.port != 0 {
        endpoints.append(LinkEndpoint(address: observed.address, port: observed.port))
      }
      let punchAt = envelope.punchAt.flatMap(CoordinatorClient.parseRFC3339) ?? dependencies.now()
      attempt.punching?.cancel()
      attempt.punching = Task { [weak self] in await self?.punch(linkId, endpoints: Self.unique(endpoints), at: punchAt) }
      attempts[linkId] = attempt
    case "link.closed", "error":
      guard let linkId = envelope.linkId, let attempt = attempts.removeValue(forKey: linkId) else { return }
      attempt.probing?.cancel()
      // A punch already running keeps going: the devices hold the path themselves
      if attempt.punching == nil {
        dependencies.log("link \(linkId.prefix(8)) closed: \(envelope.error?.code ?? "?")")
      }
    default:
      break
    }
  }

  private func incoming(_ envelope: CoordinatorClient.Envelope) async {
    guard let linkId = envelope.linkId, let grant = envelope.grant, let probeToken = envelope.probeToken,
      let peerKey = envelope.peerKey
    else { return }
    let link: VerifiedLink
    do {
      link = try grant.verified(trustedHubKey: trustedHubKey, ownKey: ownKey, now: dependencies.now())
      guard link.other.key == peerKey else { throw PeerLinkGrantError.notASide }
    } catch {
      dependencies.log("link.incoming \(linkId.prefix(8)) from \(peerKey.suffix(8)) rejected: \(error)")
      try? await dependencies.send("link.reject", linkId, nil)
      return
    }
    admitted[peerKey] = link
    let current = peers[peerKey]
    let peer = Self.peer(for: link, endpoint: current?.wireGuardKey == link.other.wireGuardKey ? current?.endpoint : nil)
    if current != peer {
      peers[peerKey] = peer
      await apply()
    }
    dependencies.log("link.incoming \(linkId.prefix(8)) from \(peerKey.suffix(8)) accepted")
    do {
      try await dependencies.send("link.accept", linkId, nil)
    } catch {
      dependencies.log("link.accept failed: \(error)")
      return
    }
    await begin(linkId: linkId, link: link, probeToken: probeToken)
  }

  // MARK: Opening

  private func openWhereNeeded() async {
    guard present else { return }
    for link in own where link.opens && !opening.contains(link.grant.grantId) {
      guard !attempts.values.contains(where: { $0.link.grant.grantId == link.grant.grantId }) else { continue }
      if delivered[link.other.key] == link.grant.grantId, await isLive(link) {
        continue
      }
      opening.insert(link.grant.grantId)
      defer { opening.remove(link.grant.grantId) }
      do {
        let opened = try await dependencies.open(link.grant)
        dependencies.log("link \(opened.linkId.prefix(8)) opened to \(opened.peerKey.suffix(8))")
        await begin(linkId: opened.linkId, link: link, probeToken: opened.probeToken)
      } catch {
        dependencies.log("link.open to \(link.other.key.suffix(8)) failed: \(error)")
      }
    }
  }

  /// Probes until the link is ready and offers this device's host candidates
  private func begin(linkId: String, link: VerifiedLink, probeToken: String) async {
    var attempt = Attempt(link: link, probeToken: probeToken, startedAt: dependencies.now())
    let payload = (try? JSONEncoder().encode(LinkUDPProbe(version: 1, linkId: linkId, probeToken: probeToken))) ?? Data()
    let interval = probeInterval
    let probe = dependencies.probe
    let log = dependencies.log
    attempt.probing = Task {
      // The node closes a link that isn't ready within a minute
      for round in 0..<60 {
        guard !Task.isCancelled else { return }
        do {
          try await probe(payload)
        } catch {
          if round == 0 { log("link probe failed: \(error)") }
        }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      }
    }
    attempts[linkId] = attempt
    let candidates = await dependencies.candidates()
    if !candidates.isEmpty {
      try? await dependencies.send("link.offer", linkId, candidates)
    }
  }

  // MARK: Punching

  /// Tries each endpoint until a handshake with the peer completes, from `punchAt` on, for up to `punchWindow`
  private func punch(_ linkId: String, endpoints offered: [LinkEndpoint], at punchAt: Date) async {
    let endpoints = Self.reachableFirst(offered, own: await dependencies.candidates())
    guard let attempt = attempts[linkId], !endpoints.isEmpty else { return }
    let link = attempt.link
    // A link opened again for a new grant over a path that still works keeps its endpoint. The other side must
    // still be there: after a network change its old mapping can look live for a while, and punching is needed
    if let current = peers[link.other.key]?.endpoint, endpoints.contains(where: { $0.endpoint == current }),
      await isLive(link)
    {
      delivered[link.other.key] = link.grant.grantId
      dependencies.log("link \(linkId.prefix(8)) renewed with \(link.other.key.suffix(8)) at \(current)")
      finish(linkId)
      return
    }
    let wait = punchAt.timeIntervalSince(dependencies.now())
    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(min(wait, 5) * 1_000_000_000)) }
    let started = dependencies.now()
    let deadline = started.addingTimeInterval(punchWindow)
    var index = 0
    while dependencies.now() < deadline, !Task.isCancelled {
      let endpoint = endpoints[index % endpoints.count]
      index += 1
      guard var peer = peers[link.other.key] else { return }
      if peer.endpoint != endpoint.endpoint {
        peer.endpoint = endpoint.endpoint
        peers[link.other.key] = peer
        await apply()
      }
      let trialEnd = min(deadline, dependencies.now().addingTimeInterval(endpointTrial))
      while dependencies.now() < trialEnd, !Task.isCancelled {
        if let last = await dependencies.lastHandshake(link.other.wireGuardKey), last >= started.addingTimeInterval(-1) {
          linkUps += 1
          delivered[link.other.key] = link.grant.grantId
          dependencies.log("link \(linkId.prefix(8)) up with \(link.other.key.suffix(8)) at \(endpoint.endpoint)")
          finish(linkId)
          return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    dependencies.log("link \(linkId.prefix(8)) to \(link.other.key.suffix(8)) found no path through \(endpoints.map(\.endpoint))")
    finish(linkId)
  }

  /// Whether handshakes with the link's peer still come
  private func isLive(_ link: VerifiedLink) async -> Bool {
    guard let last = await dependencies.lastHandshake(link.other.wireGuardKey) else { return false }
    return dependencies.now().timeIntervalSince(last) < Self.liveHandshakeAge
  }

  private func finish(_ linkId: String) {
    guard let attempt = attempts.removeValue(forKey: linkId) else { return }
    attempt.probing?.cancel()
  }

  // MARK: Peers

  private func removeStale() async {
    let now = dependencies.now()
    own.removeAll { $0.expiresAt <= now }
    admitted = admitted.filter { $0.value.expiresAt > now }
    let keep = Set(own.map(\.other.key)).union(admitted.keys)
    delivered = delivered.filter { keep.contains($0.key) }
    let before = peers.count
    peers = peers.filter { keep.contains($0.key) }
    await apply(force: peers.count != before)
  }

  private var applied: [Peer]?

  private func apply(force: Bool = false) async {
    let next = peers.values.sorted { $0.key < $1.key }
    guard force || next != applied else { return }
    do {
      try await dependencies.apply(next)
      applied = next
    } catch {
      dependencies.log("link peers not applied: \(error)")
    }
  }

  private static func peer(for link: VerifiedLink, endpoint: String?) -> Peer {
    Peer(
      key: link.other.key, wireGuardKey: link.other.wireGuardKey, routes: link.routes,
      sources: link.other.addresses.map(PeerLinkGrant.hostRoute), ports: link.exposed, endpoint: endpoint
    )
  }

  /// A private address of another network (the Mac's LAN seen from a phone on cellular) can't answer, and trying it
  /// first costs a trial while the other side tries the public mapping: it goes last. Both sides order alike, so they
  /// try the same path at the same time
  static func reachableFirst(_ endpoints: [LinkEndpoint], own: [LinkEndpoint]) -> [LinkEndpoint] {
    let foreign = endpoints.map { endpoint in
      guard let address = IPv4Address(endpoint.address) else { return false }
      return isPrivate(address) && !own.contains { IPv4Address($0.address).map { sameSubnet($0, address) } ?? false }
    }
    return zip(endpoints, foreign).filter { !$0.1 }.map(\.0) + zip(endpoints, foreign).filter { $0.1 }.map(\.0)
  }

  /// 10/8, 172.16/12, 192.168/16, 100.64/10 (carrier NAT) and 169.254/16
  private static func isPrivate(_ address: IPv4Address) -> Bool {
    let bytes = [UInt8](address.rawValue)
    switch (bytes[0], bytes[1]) {
    case (10, _), (192, 168), (169, 254): return true
    case (172, 16...31), (100, 64...127): return true
    default: return false
    }
  }

  /// Same /24, as home networks are
  private static func sameSubnet(_ a: IPv4Address, _ b: IPv4Address) -> Bool {
    a.rawValue.prefix(3) == b.rawValue.prefix(3)
  }

  private static func unique(_ endpoints: [LinkEndpoint]) -> [LinkEndpoint] {
    var seen = Set<LinkEndpoint>()
    return endpoints.filter { seen.insert($0).inserted }
  }
}

/// The datagram each side sends the coordinator from WireGuard's socket, so it can observe the mapping
struct LinkUDPProbe: Codable {
  let version: Int
  let linkId: String
  let probeToken: String
}
