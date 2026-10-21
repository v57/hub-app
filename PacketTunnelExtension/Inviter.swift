import Foundation
import HubService
import Network
import OSLog

/// Errors surfaced by the inviter bootstrap handler. The listener maps these
/// to wire error frames.
enum InviterError: Error, Equatable {
  case invalidRequest(String)
  case replay
  case capacity
  case internalError(String)
}

/// Inviter-side direct bootstrap coordinator.
///
/// Mirrors the Go `hub-net/agent/invitation` `Inviter`: it verifies a signed
/// joiner `DirectBootstrapRequest` (via `DirectBootstrapRequestVerifier`),
/// allocates collision-free temporary point-to-point addresses, installs a
/// temporary WireGuard peer for the joiner, and answers with a
/// `DirectBootstrapResponse` signed by the invitation service key (the same
/// key that signed the compact invitation).
///
/// Repeating the identical request returns the same response (transport
/// retries); a different request for the same invitation replay id is rejected
/// (`bootstrap_replay`). Temporary peers are removed when their response
/// expires (sweep) or on explicit close.
final class Inviter {
  private static let bootstrapIPv4Base = "100.127.254."
  private static let bootstrapIPv4Pool = 2...254
  private static let bootstrapIPv6Base = "fd48:5542:4e45:fffe::"
  private static let maximumAddresses = 253  // 100.127.254.2..254

  private let identity: KeyChain
  private let wireGuardPublicKey: String
  private let installPeer: (String, [String], String) async throws -> Void
  private let removePeer: (String) async throws -> Void
  private let hubProHost: () -> String?
  private let endpoints: () async -> [BootstrapEndpoint]
  private let lifetime: TimeInterval
  private let now: () -> Date

  private struct ActivePeer {
    let replayId: String
    let joinerService: String
    let joinerWireGuardKey: String
    let request: DirectBootstrapRequest
    let response: DirectBootstrapResponse
    let joinerV4: String
    let joinerV6: String
    let expiresAt: Date
  }

  private let lock = NSLock()
  private var active: [String: ActivePeer] = [:]
  private var used: Set<String> = []
  /// Signals received from the node (`inviter.bootstrap`) before the joiner's
  /// UDP request arrives: replayId -> joiner service key. Seeded by the node
  /// client's bootstrap handler so `handle` can bind a request to the
  /// invitation the node paired us with.
  private var pendingSignals: [String: String] = [:]

  init(
    identity: KeyChain,
    wireGuardPublicKey: String,
    installPeer: @escaping (String, [String], String) async throws -> Void,
    removePeer: @escaping (String) async throws -> Void,
    hubProHost: @escaping () -> String?,
    endpoints: @escaping () async -> [BootstrapEndpoint],
    lifetime: TimeInterval = 10 * 60,
    now: @escaping () -> Date = Date.init
  ) {
    self.identity = identity
    self.wireGuardPublicKey = wireGuardPublicKey
    self.installPeer = installPeer
    self.removePeer = removePeer
    self.hubProHost = hubProHost
    self.endpoints = endpoints
    self.lifetime = lifetime
    self.now = now
  }

  var activeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return active.count
  }

  /// Records that the node signaled a joiner opening one of our invitations.
  /// The node client's `inviter.bootstrap` handler calls this so `handle` can
  /// bind the joiner's UDP request to the invitation replay id.
  func expectBootstrap(replayId: String, joinerServiceKey: String) {
    lock.lock()
    pendingSignals[replayId] = joinerServiceKey
    lock.unlock()
  }

  /// Verifies one joiner request, installs the temporary peer, and returns the
  /// signed response. Identical retries return the same response.
  ///
  /// The request must bind to an invitation the node signaled us with:
  /// `pendingSignals[replayId]` must hold the joiner's service key. This
  /// prevents the inviter from answering a request for an invitation it was
  /// never paired with.
  func handle(_ request: DirectBootstrapRequest) async throws -> DirectBootstrapResponse {
    let now = now()
    // The node's `inviter.bootstrap` push and the joiner's HUBB request race:
    // the push normally lands within milliseconds, but the joiner's request
    // can arrive first (its exchange starts as soon as the candidate list
    // arrives). Wait briefly for the signal before rejecting.
    var expectedJoiner: String?
    for _ in 0..<50 {
      lock.lock()
      expectedJoiner = pendingSignals[request.replayId]
      lock.unlock()
      if expectedJoiner != nil { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    // The node signals the joiner's session key: an Apple joiner names its
    // service key, a Go joiner its WireGuard key.
    guard let expectedJoiner,
          expectedJoiner == request.joinerServiceKey || expectedJoiner == request.joinerWireGuardKey else {
      throw InviterError.invalidRequest("no bootstrap signal for invitation")
    }
    try DirectBootstrapRequestVerifier.verify(
      request,
      expectedReplayId: request.replayId,
      expectedJoinerServiceKey: request.joinerServiceKey,
      now: now
    )

    lock.lock()
    let existing = active[request.replayId]
    // A fresh, verified admission of a joiner that bootstrapped before (a rejoin with a new WireGuard key, or an
    // earlier attempt that never finished) replaces its old peer, as hub-server replaces a member's WireGuard key
    let superseded = active.values.filter {
      $0.replayId != request.replayId
        && ($0.joinerService == request.joinerServiceKey || $0.joinerWireGuardKey == request.joinerWireGuardKey)
    }
    for peer in superseded {
      active.removeValue(forKey: peer.replayId)
    }
    lock.unlock()
    for peer in superseded {
      await removeActivePeer(peer)
    }
    if let existing {
      guard existing.expiresAt > now else {
        await removeActivePeer(existing)
        lock.lock()
        active.removeValue(forKey: request.replayId)
        lock.unlock()
        return try await allocateAndInstall(request, now: now)
      }
      if existing.joinerService == request.joinerServiceKey,
         existing.request.nonce == request.nonce {
        return existing.response
      }
      throw InviterError.replay
    }
    return try await allocateAndInstall(request, now: now)
  }

  /// Closes every temporary peer whose response has expired.
  func sweep() async {
    let now = now()
    // Never hold the lock across an await: the continuation can resume on
    // another thread, and NSLock must be unlocked on the thread that locked.
    lock.lock()
    let expired = active.filter { !$0.value.expiresAt.isAfter(now) }
    for replayId in expired.keys {
      active.removeValue(forKey: replayId)
    }
    lock.unlock()
    for peer in expired.values {
      await removeActivePeer(peer)
    }
  }

  /// Removes every temporary peer. Called on tunnel stop.
  func closeAll() async {
    lock.lock()
    let peers = active.values
    active.removeAll()
    lock.unlock()
    for peer in peers {
      await removeActivePeer(peer)
    }
  }

  func closeJoiner(replayId: String) async {
    lock.lock()
    guard let peer = active.removeValue(forKey: replayId) else {
      lock.unlock()
      return
    }
    lock.unlock()
    await removeActivePeer(peer)
  }

  private func allocateAndInstall(
    _ request: DirectBootstrapRequest,
    now: Date
  ) async throws -> DirectBootstrapResponse {
    guard let hubProHost = hubProHost(), !hubProHost.isEmpty else {
      throw InviterError.internalError("hubProHost unavailable")
    }
    let joinerV4: String
    let joinerV6: String
    do {
      (joinerV4, joinerV6) = try allocate()
    } catch {
      throw InviterError.capacity
    }

    let expiresAt = now.addingTimeInterval(lifetime)
    let response = DirectBootstrapResponse(
      replayId: request.replayId,
      inviterServiceKey: identity.publicKey(),
      joinerServiceKey: request.joinerServiceKey,
      joinerWireGuardKey: request.joinerWireGuardKey,
      inviterWireGuardKey: wireGuardPublicKey,
      endpoints: await endpoints(),
      joinerAddress: BootstrapAddress(ipv4: joinerV4, ipv6: joinerV6),
      inviterAddress: BootstrapAddress(ipv4: inviterV4, ipv6: inviterV6),
      hubProHost: hubProHost,
      issuedAt: ISO8601DateFormatter.hubNetworkDateString(now),
      expiresAt: ISO8601DateFormatter.hubNetworkDateString(expiresAt),
      signature: ""
    )
    let signedResponse: DirectBootstrapResponse
    do {
      let signature = try signResponse(response)
      signedResponse = DirectBootstrapResponse(
        replayId: response.replayId,
        inviterServiceKey: response.inviterServiceKey,
        joinerServiceKey: response.joinerServiceKey,
        joinerWireGuardKey: response.joinerWireGuardKey,
        inviterWireGuardKey: response.inviterWireGuardKey,
        endpoints: response.endpoints,
        joinerAddress: response.joinerAddress,
        inviterAddress: response.inviterAddress,
        hubProHost: response.hubProHost,
        issuedAt: response.issuedAt,
        expiresAt: response.expiresAt,
        signature: signature
      )
    } catch {
      release(joinerV4, joinerV6)
      throw InviterError.internalError(String(describing: error))
    }

    // The joiner's permanent overlay addresses are assigned by the hub only
    // after `hub/net/bind`; the app adds them as member peers once it sees
    // them. Until then the temporary bootstrap addresses alone would make the
    // inviter drop the joiner's post-commit traffic (source = assigned overlay
    // address), so the peer also scopes the frozen overlay prefixes. The
    // newest joiner keeps those when several bootstrap at once
    // (BootstrapRouteClaims); each keeps its own bootstrap addresses.
    let allowedIPs = ["\(joinerV4)/32", "\(joinerV6)/128", "100.96.0.0/11", "fd48:5542:4e45::/48"]
    do {
      try await installPeer(request.joinerWireGuardKey, allowedIPs, request.joinerServiceKey)
    } catch {
      release(joinerV4, joinerV6)
      throw InviterError.internalError(String(describing: error))
    }

    let peer = ActivePeer(
      replayId: request.replayId,
      joinerService: request.joinerServiceKey,
      joinerWireGuardKey: request.joinerWireGuardKey,
      request: request,
      response: signedResponse,
      joinerV4: joinerV4,
      joinerV6: joinerV6,
      expiresAt: expiresAt
    )
    active[request.replayId] = peer
    return signedResponse
  }

  private var inviterV4: String { "100.127.254.1" }
  private var inviterV6: String { "fd48:5542:4e45:fffe::1" }

  private func allocate() throws -> (String, String) {
    lock.lock()
    defer { lock.unlock() }
    for index in Self.bootstrapIPv4Pool {
      let v4 = "\(Self.bootstrapIPv4Base)\(index)"
      let v6 = "\(Self.bootstrapIPv6Base)\(String(index, radix: 16))"
      guard !used.contains(v4), !used.contains(v6) else { continue }
      used.insert(v4)
      used.insert(v6)
      return (v4, v6)
    }
    throw InviterError.capacity
  }

  private func release(_ joinerV4: String, _ joinerV6: String) {
    lock.lock()
    used.remove(joinerV4)
    used.remove(joinerV6)
    lock.unlock()
  }

  private func signResponse(_ response: DirectBootstrapResponse) throws -> String {
    let input = try HubNetworkSignedEnvelope.signatureInput(
      for: response,
      domain: HubNetworkDirectBootstrapDomain.response
    )
    return try identity.signature(for: input).base64EncodedString()
  }

  private func removeActivePeer(_ peer: ActivePeer) async {
    try? await removePeer(peer.joinerWireGuardKey)
    release(peer.joinerV4, peer.joinerV6)
  }
}

private extension Date {
  func isAfter(_ other: Date) -> Bool {
    self > other
  }
}
