import Foundation
import HubService
import Network
import OSLog

/// Online-inviter registration client for hub-net-node.
///
/// Mirrors the Go `hub-net/agent/nodeclient`: it holds one persistent
/// WebSocket to the node's `/rendezvous` and runs the signed challenge
/// handshake:
///
///     inviter.register (service key only) -> inviter.challenge
///     -> inviter.register (nonce + signature) -> inviter.registered
///
/// The lease is 2 minutes; the client re-runs the handshake before expiry and
/// reconnects with bounded backoff on failure. While registered, `inviter.bootstrap`
/// pushes arrive when a joiner opens a session with one of this inviter's
/// invitations; the client then probes, opens its own side of the paired
/// session, offers the inviter's declared candidates, and reports the joiner's
/// candidates + observed endpoint to a handler.
final class InviterNodeClient: NSObject, URLSessionWebSocketDelegate {
  struct BootstrapEvent {
    let invitationCode: String
    let tokenDigest: String
    let transactionId: String
    let tunnelInstanceId: String
    let generation: UInt64
    let joinerKey: String
    let sessionId: String
    let candidates: [InvitationBootstrapClient.Candidate]
    let observedEndpoint: InvitationBootstrapClient.ObservedEndpoint
  }

  typealias Candidate = InvitationBootstrapClient.Candidate
  typealias ObservedEndpoint = InvitationBootstrapClient.ObservedEndpoint

  private struct Envelope: Codable {
    let majorVersion: Int
    let minorVersion: Int
    let type: String
    var requestId: String? = nil
    var sessionId: String? = nil
    var candidate: Candidate? = nil
    var candidates: [Candidate]? = nil
    var observedEndpoint: ObservedEndpoint? = nil
    var error: NodeError? = nil
    var invitationCode: String? = nil
    var key: String? = nil
    var tokenDigest: String? = nil
    var transactionId: String? = nil
    var tunnelInstanceId: String? = nil
    var generation: UInt64? = nil
    var serviceKey: String? = nil
    var challengeNonce: String? = nil
    var challengeSignature: String? = nil
    var registrationExpiresAt: String? = nil
  }

  private struct NodeError: Codable {
    let code: String
    let message: String
  }

  private struct InvitationProbe: Encodable {
    let version: Int
    let invitationCode: String
    let key: String
    let tokenDigest: String
    let transactionId: String
    let tunnelInstanceId: String
    let generation: UInt64
  }

  /// Signing domain for the online-inviter registration challenge, matching
  /// `hub-service-go/protocol` `PurposeInviterRegistration`.
  static let registrationDomain = "hub-network/inviter-registration/v1"
  private static let leaseRefreshLeeway: TimeInterval = 30
  private static let handshakeTimeout: TimeInterval = 15
  private static let bootstrapTimeout: TimeInterval = 45

  private let nodeEndpoint: String
  private let identity: KeyChain
  private let probe: (String, Data) async throws -> Void
  private let candidates: () -> Candidate?
  private let onBootstrap: (BootstrapEvent) async -> Void
  private let onStatusChange: (Bool) -> Void
  private let logger: Logger

  private var session: URLSession?
  private var socket: URLSessionWebSocketTask?
  private var isRegistered = false
  private var runTask: Task<Void, Never>?
  /// `inviter.bootstrap` pushes that arrived while a registration handshake
  /// receive loop was awaiting its own reply. The handshake loops must not
  /// discard non-matching envelopes (they would silently eat a push and the
  /// one-shot signal would be lost); buffer them here and drain in the main
  /// receive loop. Accessed only from the run task (sequential awaits).
  private var pendingBootstraps: [Envelope] = []

  init(
    nodeEndpoint: String,
    identity: KeyChain,
    probe: @escaping (String, Data) async throws -> Void,
    candidates: @escaping () -> Candidate?,
    onBootstrap: @escaping (BootstrapEvent) async -> Void,
    onStatusChange: @escaping (Bool) -> Void
  ) {
    self.nodeEndpoint = nodeEndpoint
    self.identity = identity
    self.probe = probe
    self.candidates = candidates
    self.onBootstrap = onBootstrap
    self.onStatusChange = onStatusChange
    self.logger = Logger(
      subsystem: "dev.v57.Hub.PacketTunnelExtension",
      category: "InviterNodeClient"
    )
  }

  var registered: Bool { isRegistered }

  func start() {
    guard runTask == nil else { return }
    runTask = Task { [weak self] in
      await self?.run()
    }
  }

  func stop() {
    runTask?.cancel()
    runTask = nil
    socket?.cancel(with: .goingAway, reason: nil)
    session?.invalidateAndCancel()
    socket = nil
    session = nil
    setRegistered(false)
  }

  private func run() async {
    var backoff: TimeInterval = 1
    while !Task.isCancelled {
      do {
        try await connectAndRegister()
        backoff = 1
      } catch is CancellationError {
        return
      } catch {
        logger.warning("node registration failed: \(String(describing: error), privacy: .public); retry in \(backoff)s")
      }
      setRegistered(false)
      try? await Task.sleep(for: .seconds(backoff))
      backoff = min(backoff * 2, 30)
    }
  }

  private func connectAndRegister() async throws {
    guard let url = try? rendezvousURL(nodeEndpoint) else {
      throw InviterNodeError.invalidNode
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Self.handshakeTimeout
    // The registration connection is long-lived (lease + bootstrap sessions
    // multiplex on it); a short RESOURCE timeout kills the WS ~15s after
    // connect — exactly when a bootstrap exchange is in flight — and the
    // inviter's node connection churns every ~16s. Bound the total duration
    // generously; per-read timeouts drive the lease refresh instead.
    configuration.timeoutIntervalForResource = 3600
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    let socket = session.webSocketTask(with: url)
    self.session = session
    self.socket = socket
    socket.resume()

    var expiresAt = try await register(socket: socket)
    setRegistered(true)
    logger.info("node registration live, expires \(expiresAt)")

    while !Task.isCancelled {
      // A bootstrap push that arrived during a registration handshake was
      // buffered; process it before the next receive so the one-shot signal
      // is never lost to the handshake's requestId filtering.
      if let pending = pendingBootstraps.first {
        pendingBootstraps.removeFirst()
        await handleBootstrap(socket: socket, pending: pending)
        continue
      }
      do {
        let refreshIn = max(1, expiresAt.timeIntervalSinceNow - Self.leaseRefreshLeeway)
        let reply = try await receive(socket: socket, timeout: refreshIn)
        switch reply.type {
        case "inviter.bootstrap":
          await handleBootstrap(socket: socket, pending: reply)
        case "error":
          if let error = reply.error {
            logger.warning("node error: \(error.code) \(error.message, privacy: .public)")
          }
        default:
          break
        }
      } catch InviterNodeError.timeout {
        // Lease refresh: re-run the challenge on the same connection.
        let refreshed = try await register(socket: socket)
        expiresAt = refreshed
        logger.info("node registration refreshed, expires \(refreshed)")
      } catch {
        throw error
      }
    }
  }

  // MARK: Registration handshake

  private func register(socket: URLSessionWebSocketTask) async throws -> Date {
    let challengeRequestID = UUID().uuidString
    try await send(socket: socket, Envelope(
      majorVersion: 1, minorVersion: 0, type: "inviter.register",
      requestId: challengeRequestID,
      serviceKey: identity.publicKey()
    ))

    var nonce: String?
    var challengeExpires = Date().addingTimeInterval(Self.handshakeTimeout)
    while Date() < challengeExpires {
      let reply = try await receive(socket: socket, timeout: Self.handshakeTimeout)
      if reply.type == "error" {
        throw InviterNodeError.node(reply.error?.code ?? "unknown")
      }
      guard reply.requestId == challengeRequestID else {
        bufferBootstrapIfNeeded(reply)
        continue
      }
      guard reply.type == "inviter.challenge", let value = reply.challengeNonce, !value.isEmpty else {
        throw InviterNodeError.invalidResponse
      }
      nonce = value
      break
    }
    guard let nonce else { throw InviterNodeError.invalidResponse }

    let nonceData: Data
    if let decoded = HubNetworkCrypto.base64URLDecode(nonce), !decoded.isEmpty {
      nonceData = decoded
    } else if let padded = Data(base64Encoded: nonce), !padded.isEmpty {
      nonceData = padded
    } else {
      throw InviterNodeError.invalidNonce
    }
    let signature = try HubNetworkCrypto.signBytes(
      nonceData, domain: Self.registrationDomain, key: identity
    )

    let answerRequestID = UUID().uuidString
    try await send(socket: socket, Envelope(
      majorVersion: 1, minorVersion: 0, type: "inviter.register",
      requestId: answerRequestID,
      serviceKey: identity.publicKey(),
      challengeNonce: nonce,
      challengeSignature: signature
    ))

    var expiresAt: Date?
    var answerExpires = Date().addingTimeInterval(Self.handshakeTimeout)
    while Date() < answerExpires {
      let reply = try await receive(socket: socket, timeout: Self.handshakeTimeout)
      if reply.type == "error" {
        throw InviterNodeError.node(reply.error?.code ?? "unknown")
      }
      guard reply.requestId == answerRequestID else {
        bufferBootstrapIfNeeded(reply)
        continue
      }
      guard reply.type == "inviter.registered",
            let raw = reply.registrationExpiresAt,
            let parsed = Self.parseRFC3339(raw) else {
        throw InviterNodeError.invalidResponse
      }
      expiresAt = parsed
      break
    }
    guard let expiresAt else { throw InviterNodeError.invalidResponse }
    return expiresAt
  }

  private static func parseRFC3339(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  /// Buffers a push envelope received while a registration handshake loop
  /// was filtering for its own requestId. Only `inviter.bootstrap` signals
  /// are retained; other stray envelopes are dropped as before.
  private func bufferBootstrapIfNeeded(_ reply: Envelope) {
    guard reply.type == "inviter.bootstrap" else { return }
    extensionDiagnostics(
      "inviter.bootstrap buffered during handshake replay=\(reply.tokenDigest?.prefix(8) ?? "?")"
    )
    pendingBootstraps.append(reply)
  }

  // MARK: Bootstrap exchange

  private func handleBootstrap(socket: URLSessionWebSocketTask, pending: Envelope) async {
    extensionDiagnostics("inviter.bootstrap rx replay=\(pending.tokenDigest?.prefix(8) ?? "?")")
    guard let invitationCode = pending.invitationCode,
          let tokenDigest = pending.tokenDigest,
          let transactionId = pending.transactionId,
          let joinerKey = pending.key,
          !invitationCode.isEmpty, !tokenDigest.isEmpty, !transactionId.isEmpty else {
      logger.warning("incomplete inviter.bootstrap signal")
      extensionDiagnostics("inviter.bootstrap incomplete signal")
      return
    }
    do {
      let sessionId = try await openBootstrapSessionAfterProbe(
        socket: socket, pending: pending,
        tokenDigest: tokenDigest, transactionId: transactionId, invitationCode: invitationCode)
      defer {
        Task { try? await closeBootstrapSession(socket: socket, sessionId: sessionId) }
      }
      if let candidate = candidates() {
        try await send(socket: socket, Envelope(
          majorVersion: 1, minorVersion: 0, type: "candidate.offer",
          sessionId: sessionId,
          candidate: Candidate(
            version: 1, candidateId: candidate.candidateId,
            sessionId: sessionId, key: identity.publicKey(),
            kind: candidate.kind, transport: "udp",
            address: candidate.address, port: candidate.port,
            priority: candidate.priority, expiresAt: candidate.expiresAt
          )
        ))
      }
      var event: BootstrapEvent?
      var deadline = Date().addingTimeInterval(Self.bootstrapTimeout)
      while Date() < deadline {
        let reply: Envelope
        do {
          reply = try await receive(socket: socket, timeout: Self.bootstrapTimeout)
        } catch {
          if event != nil { break }
          throw error
        }
        guard reply.type == "candidate.list", reply.sessionId == sessionId else { continue }
        let observed = reply.observedEndpoint
        event = BootstrapEvent(
          invitationCode: invitationCode,
          tokenDigest: tokenDigest,
          transactionId: transactionId,
          tunnelInstanceId: pending.tunnelInstanceId ?? "",
          generation: pending.generation ?? 0,
          joinerKey: joinerKey,
          sessionId: sessionId,
          candidates: reply.candidates ?? [],
          observedEndpoint: observed ?? ObservedEndpoint(
            version: 1, key: joinerKey, transport: "udp", address: "", port: 0
          )
        )
        if !(reply.candidates ?? []).isEmpty { break }
      }
      if let event {
        await onBootstrap(event)
      }
    } catch {
      logger.warning("inviter bootstrap exchange failed: \(String(describing: error), privacy: .public)")
    }
  }

  private func sendProbe(tokenDigest: String, transactionId: String, invitationCode: String) async throws {
    let invitationProbe = InvitationProbe(
      version: 1, invitationCode: invitationCode,
      key: identity.publicKey(),
      tokenDigest: tokenDigest, transactionId: transactionId,
      tunnelInstanceId: "", generation: 0
    )
    let data = try JSONEncoder().encode(invitationProbe)
    let endpoint = nodeUDPEndpoint()
    guard !endpoint.isEmpty else { throw InviterNodeError.invalidNode }
    try await probe(endpoint, data)
  }

  /// The node records the UDP probe asynchronously and refuses `session.open` with the retryable
  /// `udp_observation_required` until it has: probe like the joiner does (three datagrams 50 ms apart), then
  /// re-probe and retry the open a few times instead of failing the bootstrap on the first refusal.
  private func openBootstrapSessionAfterProbe(
    socket: URLSessionWebSocketTask, pending: Envelope,
    tokenDigest: String, transactionId: String, invitationCode: String
  ) async throws -> String {
    var attempt = 0
    while true {
      for _ in 0..<3 {
        try await sendProbe(tokenDigest: tokenDigest, transactionId: transactionId, invitationCode: invitationCode)
        try await Task.sleep(for: .milliseconds(50))
      }
      do {
        return try await openBootstrapSession(socket: socket, pending: pending)
      } catch InviterNodeError.node("udp_observation_required") where attempt < 5 {
        attempt += 1
        extensionDiagnostics("inviter.bootstrap udp observation pending, retry \(attempt)")
        try await Task.sleep(for: .milliseconds(200 * attempt))
      }
    }
  }

  private func openBootstrapSession(socket: URLSessionWebSocketTask, pending: Envelope) async throws -> String {
    guard let invitationCode = pending.invitationCode,
          let tokenDigest = pending.tokenDigest,
          let transactionId = pending.transactionId else {
      throw InviterNodeError.invalidResponse
    }
    let requestID = UUID().uuidString
    try await send(socket: socket, Envelope(
      majorVersion: 1, minorVersion: 0, type: "session.open",
      requestId: requestID,
      invitationCode: invitationCode,
      key: identity.publicKey(),
      tokenDigest: tokenDigest,
      transactionId: transactionId,
      tunnelInstanceId: pending.tunnelInstanceId,
      generation: pending.generation
    ))
    var deadline = Date().addingTimeInterval(Self.handshakeTimeout)
    while Date() < deadline {
      let reply = try await receive(socket: socket, timeout: Self.handshakeTimeout)
      if reply.type == "error" {
        throw InviterNodeError.node(reply.error?.code ?? "unknown")
      }
      guard reply.requestId == requestID else { continue }
      guard reply.type == "session.opened", let sessionId = reply.sessionId, !sessionId.isEmpty else {
        throw InviterNodeError.invalidResponse
      }
      return sessionId
    }
    throw InviterNodeError.timeout
  }

  private func closeBootstrapSession(socket: URLSessionWebSocketTask, sessionId: String) async throws {
    try await send(socket: socket, Envelope(
      majorVersion: 1, minorVersion: 0, type: "session.close",
      sessionId: sessionId
    ))
  }

  // MARK: Transport

  private func send(socket: URLSessionWebSocketTask, _ envelope: Envelope) async throws {
    let data = try JSONEncoder().encode(envelope)
    guard let text = String(data: data, encoding: .utf8) else {
      throw InviterNodeError.invalidResponse
    }
    try await socket.send(.string(text))
  }

  private func receive(socket: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> Envelope {
    do {
      return try await withThrowingTaskGroup(of: Envelope.self) { group in
        group.addTask {
          let message: URLSessionWebSocketTask.Message
          do {
            message = try await socket.receive()
          } catch {
            throw InviterNodeError.closed
          }
          let data: Data
          switch message {
          case .data(let value): data = value
          case .string(let value): data = Data(value.utf8)
          @unknown default: throw InviterNodeError.invalidResponse
          }
          let envelope = try JSONDecoder().decode(Envelope.self, from: data)
          guard envelope.majorVersion == 1, envelope.minorVersion <= 0 else {
            throw InviterNodeError.invalidResponse
          }
          return envelope
        }
        group.addTask {
          try await Task.sleep(for: .seconds(max(0.1, timeout)))
          throw InviterNodeError.timeout
        }
        guard let envelope = try await group.next() else {
          group.cancelAll()
          throw InviterNodeError.closed
        }
        group.cancelAll()
        return envelope
      }
    }
  }

  private func rendezvousURL(_ value: String) throws -> URL {
    // The stored node endpoint may be a bare host:port (no scheme); the node
    // listens on :1964 for plain WebSocket + UDP. Default the scheme and port
    // like the Go nodeclient's normalizeEndpoint.
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalized.contains("://") {
      normalized = "ws://" + normalized
    }
    guard var components = URLComponents(string: normalized),
          components.host != nil,
          components.scheme == "https" || components.scheme == "http" ||
          components.scheme == "wss" || components.scheme == "ws" else {
      throw InviterNodeError.invalidNode
    }
    if components.scheme == "https" { components.scheme = "wss" }
    if components.scheme == "http" { components.scheme = "ws" }
    if components.port == nil && components.scheme == "ws" {
      components.port = 1964
    }
    let basePath = components.path.hasSuffix("/")
      ? String(components.path.dropLast())
      : components.path
    components.path = basePath + "/rendezvous"
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw InviterNodeError.invalidNode }
    return url
  }

  private func nodeUDPEndpoint() -> String {
    var normalized = nodeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalized.contains("://") {
      normalized = "ws://" + normalized
    }
    guard let components = URLComponents(string: normalized),
          let host = components.host else { return "" }
    let port = components.port ?? (components.scheme == "https" || components.scheme == "wss" ? 443 : 1964)
    return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
  }

  private func setRegistered(_ value: Bool) {
    if isRegistered != value {
      isRegistered = value
      onStatusChange(value)
    }
  }
}

enum InviterNodeError: Error, Equatable {
  case invalidNode
  case invalidResponse
  case invalidNonce
  case timeout
  case closed
  case node(String)
}
