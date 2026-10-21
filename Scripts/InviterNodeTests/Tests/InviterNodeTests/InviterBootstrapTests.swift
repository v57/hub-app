import CryptoKit
import Foundation
import HubService
import XCTest

@testable import InviterBootstrap
@testable import InviterNode

/// The inviter's direct bootstrap admissions, one after another, with peers kept like the extension's WireGuard
/// adapter keeps them (one per WireGuard key, shared routes to the newest)
final class InviterBootstrapTests: XCTestCase {
  func testRejoinWithANewWireGuardKeyReplacesTheOldPeer() async throws {
    let peers = Peers()
    let inviter = try makeInviter(peers)
    let joiner = try KeyChain(rawRepresentation: Curve25519.Signing.PrivateKey().rawRepresentation)
    let firstKey = wireGuardKey()
    let first = try await admit(joiner, wireGuardKey: firstKey, to: inviter)
    // The first join stopped after the bootstrap; the device comes back with a fresh invitation and WireGuard key
    let secondKey = wireGuardKey()
    let second = try await admit(joiner, wireGuardKey: secondKey, to: inviter)
    XCTAssertEqual(second.joinerWireGuardKey, secondKey)
    XCTAssertEqual(peers.removed, [firstKey])
    XCTAssertEqual(Set(peers.routes.keys), [secondKey])
    XCTAssertEqual(inviter.activeCount, 1)
    XCTAssertEqual(second.joinerAddress, first.joinerAddress, "the old peer's bootstrap addresses are free again")
  }

  func testSequentialJoinersEachGetAPeer() async throws {
    let peers = Peers()
    let inviter = try makeInviter(peers)
    var responses: [DirectBootstrapResponse] = []
    for _ in 0..<3 {
      let joiner = try KeyChain(rawRepresentation: Curve25519.Signing.PrivateKey().rawRepresentation)
      responses.append(try await admit(joiner, wireGuardKey: wireGuardKey(), to: inviter))
    }
    XCTAssertEqual(peers.removed, [])
    XCTAssertEqual(inviter.activeCount, 3)
    XCTAssertEqual(Set(responses.map(\.joinerAddress.ipv4)).count, 3)
    // Every address goes to one peer: the newest joiner keeps the overlay prefixes, each keeps its own addresses
    let routes = peers.resolved
    let all = routes.values.flatMap { $0 }
    XCTAssertEqual(Set(all).count, all.count)
    XCTAssertEqual(routes[responses[2].joinerWireGuardKey].map(Set.init), [
      "\(responses[2].joinerAddress.ipv4)/32", "\(responses[2].joinerAddress.ipv6)/128",
      "100.96.0.0/11", "fd48:5542:4e45::/48",
    ])
    XCTAssertEqual(routes[responses[0].joinerWireGuardKey].map(Set.init), [
      "\(responses[0].joinerAddress.ipv4)/32", "\(responses[0].joinerAddress.ipv6)/128",
    ])
  }

  func testARetriedRequestGetsTheSameResponse() async throws {
    let peers = Peers()
    let inviter = try makeInviter(peers)
    let joiner = try KeyChain(rawRepresentation: Curve25519.Signing.PrivateKey().rawRepresentation)
    let replayId = replayIdentifier()
    let request = try signedRequest(joiner, wireGuardKey: wireGuardKey(), replayId: replayId)
    inviter.expectBootstrap(replayId: replayId, joinerServiceKey: joiner.publicKey())
    let first = try await inviter.handle(request)
    let again = try await inviter.handle(request)
    XCTAssertEqual(first, again)
    XCTAssertEqual(peers.installs, 1)
  }

  func testRouteClaimsGoToTheNewestPeer() {
    let resolved = BootstrapRouteClaims.resolve([
      "old": (order: 1, routes: ["a/32", "wide/11"]),
      "new": (order: 3, routes: ["b/32", "wide/11"]),
      "middle": (order: 2, routes: ["c/32", "wide/11", "b/32"]),
    ], identity: { $0 })
    XCTAssertEqual(resolved["new"], ["b/32", "wide/11"])
    XCTAssertEqual(resolved["middle"], ["c/32"])
    XCTAssertEqual(resolved["old"], ["a/32"])
  }

  // MARK: Helpers

  private func makeInviter(_ peers: Peers) throws -> Inviter {
    Inviter(
      identity: try KeyChain(rawRepresentation: Curve25519.Signing.PrivateKey().rawRepresentation),
      wireGuardPublicKey: wireGuardKey(),
      installPeer: { key, allowedIPs, _ in peers.install(key, allowedIPs) },
      removePeer: { key in peers.remove(key) },
      hubProHost: { "100.96.0.1" },
      endpoints: { [BootstrapEndpoint(address: "192.0.2.1", port: 51820, transport: "udp")] }
    )
  }

  private func admit(_ joiner: KeyChain, wireGuardKey: String, to inviter: Inviter) async throws -> DirectBootstrapResponse {
    let replayId = replayIdentifier()
    inviter.expectBootstrap(replayId: replayId, joinerServiceKey: joiner.publicKey())
    return try await inviter.handle(signedRequest(joiner, wireGuardKey: wireGuardKey, replayId: replayId))
  }

  private func signedRequest(_ joiner: KeyChain, wireGuardKey: String, replayId: String) throws -> DirectBootstrapRequest {
    let unsigned = DirectBootstrapRequest(
      replayId: replayId, joinerServiceKey: joiner.publicKey(), joinerWireGuardKey: wireGuardKey,
      nonce: UUID().uuidString, issuedAt: ISO8601DateFormatter.hubNetworkDateString(Date()), signature: ""
    )
    let input = try HubNetworkSignedEnvelope.signatureInput(for: unsigned, domain: HubNetworkDirectBootstrapDomain.request)
    return DirectBootstrapRequest(
      replayId: replayId, joinerServiceKey: unsigned.joinerServiceKey, joinerWireGuardKey: wireGuardKey,
      nonce: unsigned.nonce, issuedAt: unsigned.issuedAt, signature: joiner.sign(data: input)
    )
  }

  private func wireGuardKey() -> String {
    Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
  }

  private func replayIdentifier() -> String {
    base64URL(Data(SHA256.hash(data: Data(UUID().uuidString.utf8))))
  }
}

/// The extension adapter's bootstrap peers: one per WireGuard key, newest install order wins shared routes
final class Peers: @unchecked Sendable {
  private let lock = NSLock()
  private var order = 0
  private var peers: [String: (order: Int, routes: [String])] = [:]
  private(set) var removed: [String] = []
  private(set) var installs = 0

  func install(_ key: String, _ routes: [String]) {
    lock.withLock {
      order += 1
      installs += 1
      peers[key] = (order, routes)
    }
  }

  func remove(_ key: String) {
    lock.withLock {
      removed.append(key)
      peers[key] = nil
    }
  }

  var routes: [String: [String]] { lock.withLock { peers.mapValues(\.routes) } }
  var resolved: [String: [String]] { lock.withLock { BootstrapRouteClaims.resolve(peers, identity: { $0 }) } }
}
