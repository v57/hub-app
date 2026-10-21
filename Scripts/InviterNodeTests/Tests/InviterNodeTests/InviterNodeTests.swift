import CryptoKit
import Foundation
import XCTest

@testable import InviterNode

/// One inviter registration serves invite after invite across several leases. The node runs with a short lease and
/// idle limit so renewals have to happen for the test to pass.
final class InviterNodeTests: XCTestCase {
  static let lease: TimeInterval = 3
  var node: Process!
  var port: UInt16 = 0
  var logURL: URL!

  override func setUp() async throws {
    guard let binary = ProcessInfo.processInfo.environment["HUB_NET_NODE"] else {
      throw XCTSkip("set HUB_NET_NODE to a hub-net-node binary (run.sh does)")
    }
    port = UInt16.random(in: 21000..<29000)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inviter-node-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    logURL = directory.appendingPathComponent("node.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    node = Process()
    node.executableURL = URL(fileURLWithPath: binary)
    node.arguments = [
      "-node-id", "test-1", "-listen", "127.0.0.1:\(port)", "-state-dir", directory.path, "-log-json=false",
      "-registration-lease", "\(Int(Self.lease))s", "-session-lifetime", "5s",
    ]
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

  func testSequentialInvitesWithOneInviter() async throws {
    let inviter = Inviter(port: port)
    inviter.client.start()
    defer { inviter.client.stop() }
    try await inviter.waitRegistered(true)
    let started = Date()
    for round in 1...5 {
      try await invite(inviter, round: round)
      // Spaced so the invites span several leases
      try await Task.sleep(nanoseconds: 1_500_000_000)
    }
    XCTAssertGreaterThan(Date().timeIntervalSince(started), 3 * Self.lease)
    XCTAssertTrue(inviter.client.registered)
    XCTAssertGreaterThan(inviter.client.registrations, 3, "renewals ahead of the lease")
    XCTAssertEqual(inviter.statusChanges, [true], "the registration never dropped")
  }

  func testConcurrentInvitesShareTheRegistration() async throws {
    let inviter = Inviter(port: port)
    inviter.client.start()
    defer { inviter.client.stop() }
    try await inviter.waitRegistered(true)
    async let first: Void = invite(inviter, round: 1)
    async let second: Void = invite(inviter, round: 2)
    async let third: Void = invite(inviter, round: 3)
    _ = try await (first, second, third)
    try await Task.sleep(nanoseconds: UInt64(Self.lease * 1.5 * 1_000_000_000))
    try await invite(inviter, round: 4)
    XCTAssertEqual(inviter.statusChanges, [true])
  }

  func testRegistersAgainAtOnceWhenTheConnectionCloses() async throws {
    let inviter = Inviter(port: port)
    inviter.client.start()
    defer { inviter.client.stop() }
    try await inviter.waitRegistered(true)
    try await invite(inviter, round: 1)
    await inviter.client.dropConnection()
    try await inviter.waitRegistered(false)
    let dropped = Date()
    try await inviter.waitRegistered(true)
    XCTAssertLessThan(Date().timeIntervalSince(dropped), 1.5)
    try await invite(inviter, round: 2)
  }

  // MARK: Joiner

  /// The joiner side of one invitation: probe, open, offer, then the inviter's handler sees the bootstrap
  func invite(_ inviter: Inviter, round: Int) async throws {
    do {
      try await join(inviter, round: round)
    } catch {
      XCTFail("round \(round): \(error)")
      throw error
    }
  }

  private func join(_ inviter: Inviter, round: Int) async throws {
    let (code, digest) = inviter.invitation()
    let joinerKey = "joiner-\(round)-\(UUID().uuidString.prefix(6))"
    let transaction = "transaction-\(UUID().uuidString)"
    let probe = try JSONSerialization.data(withJSONObject: [
      "version": 1, "invitationCode": code, "key": joinerKey, "tokenDigest": digest, "transactionId": transaction,
      "tunnelInstanceId": "tunnel", "generation": 1,
    ])
    for _ in 0..<3 {
      try sendUDP(probe, port: port)
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let joiner = InviterNodeLink(
      socket: session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/rendezvous")!), log: { _ in })
    await joiner.start()
    defer { Task { await joiner.close() } }
    let opened = try await joiner.request(InviterNodeClient.Envelope(
      majorVersion: 1, minorVersion: 0, type: "session.open", requestId: "open-\(round)", invitationCode: code,
      key: joinerKey, tokenDigest: digest, transactionId: transaction, tunnelInstanceId: "tunnel", generation: 1
    ), timeout: 5)
    let sessionId = try XCTUnwrap(opened.sessionId, "round \(round): \(opened.type) \(opened.error?.message ?? "")")
    try await joiner.send(InviterNodeClient.Envelope(
      majorVersion: 1, minorVersion: 0, type: "candidate.offer", sessionId: sessionId,
      candidate: InviterNodeClient.Candidate(
        version: 1, candidateId: UUID().uuidString, sessionId: sessionId, key: joinerKey, kind: "host", transport: "udp",
        address: "192.0.2.\(round)", port: 40000, priority: 100,
        expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(30)))
    ))
    let event = try await inviter.bootstrap(digest: digest, timeout: 10)
    XCTAssertEqual(event.joinerKey, joinerKey)
    XCTAssertEqual(event.transactionId, transaction)
    XCTAssertTrue(event.candidates.contains { $0.address == "192.0.2.\(round)" }, "round \(round): \(event.candidates)")
    try? await joiner.send(InviterNodeClient.Envelope(majorVersion: 1, minorVersion: 0, type: "session.close", sessionId: sessionId))
  }
}

/// An inviter with its own key, driving the client under test
final class Inviter: @unchecked Sendable {
  let key = Curve25519.Signing.PrivateKey()
  private(set) var client: InviterNodeClient!
  private let lock = NSLock()
  private var events: [InviterNodeClient.BootstrapEvent] = []
  private var changes: [Bool] = []

  init(port: UInt16) {
    let key = self.key
    let serviceKey = (Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
      + key.publicKey.rawRepresentation).base64EncodedString()
    client = InviterNodeClient(
      nodeEndpoint: "ws://127.0.0.1:\(port)",
      serviceKey: serviceKey,
      sign: { nonce in
        // Domain, zero byte, 4-byte big-endian payload length, payload (Go network.SignBytes)
        var input = Data(InviterNodeClient.registrationDomain.utf8)
        input.append(0)
        withUnsafeBytes(of: UInt32(nonce.count).bigEndian) { input.append(contentsOf: $0) }
        input.append(nonce)
        return try key.signature(for: input).base64EncodedString()
      },
      probe: { endpoint, payload in
        let port = UInt16(endpoint.split(separator: ":").last ?? "") ?? 0
        try sendUDP(payload, port: port)
      },
      candidates: {
        InviterNodeClient.Candidate(
          version: 1, candidateId: UUID().uuidString, sessionId: "", key: serviceKey, kind: "host", transport: "udp",
          address: "198.51.100.1", port: 41000, priority: 100,
          expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(30)))
      },
      onBootstrap: { [weak self] event in self?.lock.withLock { self?.events.append(event) } },
      onStatusChange: { [weak self] registered in self?.lock.withLock { self?.changes.append(registered) } },
      log: { print("[inviter] \($0)") }
    )
    client.replyTimeout = 3
    client.candidateTimeout = 5
  }

  var statusChanges: [Bool] { lock.withLock { changes } }

  /// A fresh invitation signed with the inviter's key: `payload/signature`, and the payload's digest
  func invitation() -> (code: String, digest: String) {
    var expires = UInt32(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970).bigEndian
    let payload = [
      key.publicKey.rawRepresentation, Data(bytes: &expires, count: 4),
      Data((0..<4).map { _ in UInt8.random(in: 0...255) }),
    ].map(base64URL).joined(separator: ".")
    let signature = try! key.signature(for: Data(payload.utf8))
    return (payload + "/" + base64URL(signature), base64URL(Data(SHA256.hash(data: Data(payload.utf8)))))
  }

  func waitRegistered(_ value: Bool, timeout: TimeInterval = 5) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while client.registered != value {
      guard Date() < deadline else { throw TestFailure("registered never became \(value)") }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  func bootstrap(digest: String, timeout: TimeInterval) async throws -> InviterNodeClient.BootstrapEvent {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let event = lock.withLock({ events.first { $0.tokenDigest == digest } }) { return event }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw TestFailure("no bootstrap for \(digest.prefix(8))")
  }
}

struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

func base64URL(_ data: Data) -> String {
  data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

func sendUDP(_ data: Data, port: UInt16) throws {
  let fd = socket(AF_INET, SOCK_DGRAM, 0)
  guard fd >= 0 else { throw POSIXError(.EIO) }
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = port.bigEndian
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let sent = data.withUnsafeBytes { bytes in
    withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(fd, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  }
  guard sent == data.count else { throw POSIXError(.EIO) }
}

func canConnect(port: UInt16) -> Bool {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = port.bigEndian
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  return withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  } == 0
}
