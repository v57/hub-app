import CryptoKit
import Foundation
import XCTest

@testable import InviterNode

/// Peer links through a real hub-net-node: a member links to the hub's machine with a hub-signed grant, and the machine
/// turns away a grant signed by any other hub even though the node passes it on.
final class LinkTests: XCTestCase {
  var node: Process!
  var port: UInt16 = 0
  var logURL: URL!

  override func setUp() async throws {
    guard let binary = ProcessInfo.processInfo.environment["HUB_NET_NODE"] else {
      throw XCTSkip("set HUB_NET_NODE to a hub-net-node binary (run.sh does)")
    }
    port = UInt16.random(in: 21000..<29000)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-node-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    logURL = directory.appendingPathComponent("node.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    node = Process()
    node.executableURL = URL(fileURLWithPath: binary)
    node.arguments = ["-node-id", "test-1", "-listen", "127.0.0.1:\(port)", "-state-dir", directory.path, "-log-json=false"]
    let log = try FileHandle(forWritingTo: logURL)
    node.standardOutput = log
    node.standardError = log
    try node.run()
    for _ in 0..<100 {
      if canConnect(port: port) { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("node did not start")
  }

  override func tearDown() async throws {
    node?.terminate()
    node?.waitUntilExit()
    if let logURL, (testRun?.failureCount ?? 0) > 0, let text = try? String(contentsOf: logURL, encoding: .utf8) {
      print("--- node log ---\n\(text)")
    }
  }

  func testAMemberLinksToTheHubsMachine() async throws {
    let hub = Curve25519.Signing.PrivateKey()
    let member = LinkDevice(port: port, trusting: hub, name: "member")
    let machine = LinkDevice(port: port, trusting: hub, name: "machine")
    machine.start()
    member.start()
    defer {
      member.client.stop()
      machine.client.stop()
    }
    try await member.waitPresent()
    try await machine.waitPresent()

    let grant = signedGrant(hub: hub, member: member, machine: machine)
    await member.manager.update(grants: [grant])

    let onMachine = try await machine.waitLinked(to: member)
    let onMember = try await member.waitLinked(to: machine)
    // The machine routes back only the member's addresses and lets it open only the hub's port
    XCTAssertEqual(onMachine.wireGuardKey, member.wireGuardKey)
    XCTAssertEqual(onMachine.routes, ["100.96.0.2/32", "fd48:5542:4e45::2/128"])
    XCTAssertEqual(onMachine.sources, onMachine.routes)
    XCTAssertEqual(onMachine.ports, [PeerLinkGrant.Port(protocol: "tcp", port: 1997)])
    // The member offered its candidate first, so the machine tried it first
    XCTAssertEqual(onMachine.endpoint, "198.51.100.2:41000")
    XCTAssertEqual(onMember.routes, ["100.96.0.1/32", "fd48:5542:4e45::1/128"])
    XCTAssertEqual(onMember.ports, [])
    XCTAssertNotNil(onMember.endpoint)
  }

  /// A share the hub's machine fronts after the link came up: the member's new grant opens the link again, and the
  /// machine lets the member reach the share's port too, over the same path
  func testANewGrantReachesTheMachineOverALiveLink() async throws {
    let hub = Curve25519.Signing.PrivateKey()
    let member = LinkDevice(port: port, trusting: hub, name: "member")
    let machine = LinkDevice(port: port, trusting: hub, name: "machine")
    machine.start()
    member.start()
    defer {
      member.client.stop()
      machine.client.stop()
    }
    try await member.waitPresent()
    try await machine.waitPresent()
    await member.manager.update(grants: [signedGrant(hub: hub, member: member, machine: machine)])
    let before = try await machine.waitLinked(to: member)
    XCTAssertEqual(before.ports, [PeerLinkGrant.Port(protocol: "tcp", port: 1997)])

    let ports: [PeerLinkGrant.Port] = [.init(protocol: "tcp", port: 1997), .init(protocol: "tcp", port: 8642)]
    await member.manager.update(grants: [signedGrant(hub: hub, member: member, machine: machine, ports: ports)])
    try await member.waitLog("renewed with")
    let after = try XCTUnwrap(machine.appliedPeers.first { $0.key == member.serviceKey })
    XCTAssertEqual(after.ports, ports)
    XCTAssertEqual(after.endpoint, before.endpoint, "the live path stays")
    // The same grant again doesn't open another link
    let opened = member.count("opened to")
    await member.manager.tick()
    XCTAssertEqual(member.count("opened to"), opened)
  }

  func testTheMachineRejectsAGrantFromAnotherHub() async throws {
    let hub = Curve25519.Signing.PrivateKey()
    let attacker = Curve25519.Signing.PrivateKey()
    let machine = LinkDevice(port: port, trusting: hub, name: "machine")
    // The intruder trusts its own hub, so it opens the link; the node checks only that the signature matches the
    // grant's own hub key and passes it on
    let intruder = LinkDevice(port: port, trusting: attacker, name: "intruder")
    machine.start()
    intruder.start()
    defer {
      machine.client.stop()
      intruder.client.stop()
    }
    try await machine.waitPresent()
    try await intruder.waitPresent()

    await intruder.manager.update(grants: [signedGrant(hub: attacker, member: intruder, machine: machine)])
    try await intruder.waitLog("closed: link_rejected")
    XCTAssertTrue(machine.logged("rejected: untrustedHub"))
    XCTAssertEqual(machine.appliedPeers, [], "nothing of the intruder reached WireGuard")
    // Its own copy of the forged grant gets the member nowhere either
    let member = LinkDevice(port: port, trusting: hub, name: "member")
    await member.manager.update(grants: [signedGrant(hub: attacker, member: member, machine: machine)])
    XCTAssertTrue(member.logged("rejected: untrustedHub"))
    XCTAssertEqual(member.appliedPeers, [])
  }

  /// A grant HubServer signed (Core/HubServer, `network/links`) verifies here: both sides canonicalize alike
  func testAGrantSignedByHubServerVerifies() throws {
    let json = #"{"version":1,"grantId":"01a1734b-765a-7c5b-a953-c0317cc2c0e7","hubKey":"MCowBQYDK2VwAyEAMP8jW0u1gofE2VH0F2AHtLur35DN2hrWCUSUararuQI=","hubNetworkId":"01a1734b-7657-7bb6-9627-f59ed64392f6","purpose":"hub","a":{"key":"MCowBQYDK2VwAyEAs93y5mJl2I30WqQ6ol+d+28gInimBOEMTaSS7rxhJNk=","wireGuardKey":"wg-phone","member":"MCowBQYDK2VwAyEAs93y5mJl2I30WqQ6ol+d+28gInimBOEMTaSS7rxhJNk=","addresses":["100.96.0.2","fd48:5542:4e45::2"]},"b":{"key":"MCowBQYDK2VwAyEADfjkkhvj/f7n0NWhB4Uo5Y/9pScGajXfHyv+RmRrlDw=","wireGuardKey":"wg-machine","member":"MCowBQYDK2VwAyEADfjkkhvj/f7n0NWhB4Uo5Y/9pScGajXfHyv+RmRrlDw=","addresses":["100.96.0.1","fd48:5542:4e45::1"]},"aViaB":["100.96.0.1/32","fd48:5542:4e45::1/128"],"bViaA":["100.96.0.2/32","fd48:5542:4e45::2/128"],"aToB":[{"protocol":"tcp","port":1997}],"bToA":[],"issuedAt":"2026-10-25T13:41:27.771Z","expiresAt":"2026-11-24T13:41:27.771Z","signature":"ecU3t7DBxir0e1v6qYkLew4a1Y7OoVwgDqarVjNYUdsQdVzYjypWKYIbWS1kgwjcVCMYw+mdB/n2UiYOD4X6AA=="}"#
    let grant = try JSONDecoder().decode(PeerLinkGrant.self, from: Data(json.utf8))
    let now = CoordinatorClient.parseRFC3339("2026-10-26T00:00:00Z")!
    let link = try grant.verified(trustedHubKey: grant.hubKey, ownKey: grant.a.key, now: now)
    XCTAssertTrue(link.opens)
    XCTAssertEqual(link.routes, ["100.96.0.1/32", "fd48:5542:4e45::1/128"])
    let machine = try grant.verified(trustedHubKey: grant.hubKey, ownKey: grant.b.key, now: now)
    XCTAssertEqual(machine.exposed, [PeerLinkGrant.Port(protocol: "tcp", port: 1997)])
    // Anything changed after signing fails
    var tampered = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    tampered["aViaB"] = ["0.0.0.0/0"]
    let changed = try JSONDecoder().decode(PeerLinkGrant.self, from: JSONSerialization.data(withJSONObject: tampered))
    XCTAssertThrowsError(try changed.verified(trustedHubKey: grant.hubKey, ownKey: grant.a.key, now: now))
    XCTAssertThrowsError(try grant.verified(trustedHubKey: grant.hubKey, ownKey: grant.a.key,
      now: now.addingTimeInterval(40 * 24 * 3600))) { XCTAssertEqual($0 as? PeerLinkGrantError, .expired) }
  }

  private func signedGrant(
    hub: Curve25519.Signing.PrivateKey, member: LinkDevice, machine: LinkDevice,
    ports: [PeerLinkGrant.Port] = [.init(protocol: "tcp", port: 1997)]
  ) -> PeerLinkGrant {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let unsigned = PeerLinkGrant(
      version: 1, grantId: UUID().uuidString, hubKey: spki(hub.publicKey), hubNetworkId: "network-1", purpose: "hub",
      a: .init(key: member.serviceKey, wireGuardKey: member.wireGuardKey, member: "device:a", addresses: ["100.96.0.2", "fd48:5542:4e45::2"]),
      b: .init(key: machine.serviceKey, wireGuardKey: machine.wireGuardKey, member: "device:b", addresses: ["100.96.0.1", "fd48:5542:4e45::1"]),
      aViaB: ["100.96.0.1/32", "fd48:5542:4e45::1/128"], bViaA: ["100.96.0.2/32", "fd48:5542:4e45::2/128"],
      aToB: ports, bToA: [],
      issuedAt: formatter.string(from: Date().addingTimeInterval(-1)),
      expiresAt: formatter.string(from: Date().addingTimeInterval(3600)), signature: ""
    )
    var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(unsigned)) as! [String: Any]
    object.removeValue(forKey: "signature")
    let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    var input = Data(PeerLinkGrant.domain.utf8)
    input.append(0)
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { input.append(contentsOf: $0) }
    input.append(payload)
    object["signature"] = try! hub.signature(for: input).base64EncodedString()
    return try! JSONDecoder().decode(PeerLinkGrant.self, from: JSONSerialization.data(withJSONObject: object))
  }
}

func spki(_ key: Curve25519.Signing.PublicKey) -> String {
  (Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]) + key.rawRepresentation)
    .base64EncodedString()
}

/// A device with its own key, coordinator client and link manager. WireGuard is faked: a peer counts as handshaken
/// once it has an endpoint.
final class LinkDevice: @unchecked Sendable {
  let key = Curve25519.Signing.PrivateKey()
  let serviceKey: String
  let wireGuardKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
  let name: String
  private(set) var client: CoordinatorClient!
  private(set) var manager: LinkManager!
  private let lock = NSLock()
  private var peers: [LinkManager.Peer] = []
  private var lines: [String] = []

  init(port: UInt16, trusting hub: Curve25519.Signing.PrivateKey, name: String) {
    self.name = name
    let key = self.key
    serviceKey = spki(key.publicKey)
    client = CoordinatorClient(
      nodeEndpoint: "ws://127.0.0.1:\(port)",
      serviceKey: serviceKey,
      sign: { nonce in
        var input = Data(CoordinatorClient.registrationDomain.utf8)
        input.append(0)
        withUnsafeBytes(of: UInt32(nonce.count).bigEndian) { input.append(contentsOf: $0) }
        input.append(nonce)
        return try key.signature(for: input).base64EncodedString()
      },
      probe: { _, _ in },
      candidates: { nil },
      onLink: { [weak self] envelope in await self?.manager.handle(envelope) },
      onStatusChange: { [weak self] present in
        guard let manager = self?.manager else { return }
        Task { await manager.presenceChanged(present) }
      },
      log: { [weak self] in self?.log($0) }
    )
    let client = client!
    let candidate = name == "member" ? "198.51.100.2" : "198.51.100.1"
    manager = LinkManager(ownKey: serviceKey, trustedHubKey: spki(hub.publicKey), dependencies: .init(
      open: { try await client.openLink($0) },
      send: { try await client.sendLink($0, linkId: $1, endpoints: $2) },
      probe: { try sendUDP($0, port: port) },
      apply: { [weak self] peers in self?.lock.withLock { self?.peers = peers } },
      lastHandshake: { [weak self] wireGuardKey in
        self?.lock.withLock { self?.peers.first { $0.wireGuardKey == wireGuardKey }?.endpoint != nil } == true ? Date() : nil
      },
      candidates: { [LinkEndpoint(address: candidate, port: 41000)] },
      log: { [weak self] in self?.log($0) }
    ))
  }

  func start() { client.start() }

  var appliedPeers: [LinkManager.Peer] { lock.withLock { peers } }

  func log(_ line: String) {
    lock.withLock { lines.append(line) }
    print("[\(name)] \(line)")
  }

  func logged(_ text: String) -> Bool { lock.withLock { lines.contains { $0.contains(text) } } }

  func count(_ text: String) -> Int { lock.withLock { lines.filter { $0.contains(text) }.count } }

  func waitPresent(timeout: TimeInterval = 5) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !client.registered {
      guard Date() < deadline else { throw CoordinatorError.timeout }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  func waitLog(_ text: String, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !logged(text) {
      guard Date() < deadline else { throw CoordinatorError.timeout }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  /// The peer for `other` once the link came up
  func waitLinked(to other: LinkDevice, timeout: TimeInterval = 15) async throws -> LinkManager.Peer {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if await manager.linkUps > 0, let peer = appliedPeers.first(where: { $0.key == other.serviceKey }), peer.endpoint != nil {
        return peer
      }
      guard Date() < deadline else { throw CoordinatorError.timeout }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }
}
