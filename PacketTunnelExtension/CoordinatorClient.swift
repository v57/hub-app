import Foundation

/// The device's client for the coordinator (hub-net-node, PROTOCOL.md).
///
/// It holds one persistent WebSocket to the node's `/rendezvous` and keeps the device present with the signed
/// challenge handshake:
///
///     presence.register (service key only) -> presence.challenge
///     -> presence.register (nonce + signature) -> presence.registered
///
/// The node keeps a registration for its lease (2 minutes) and drops it, with every link of the device, when the
/// connection closes. So the client renews at half the remaining lease on its own task, registers again at once on a
/// new connection when the socket closes, and reads the socket on a dedicated reader, so no wait for a reply can
/// block a renewal.
///
/// While present it carries two kinds of traffic:
/// - Peer links (`link.*`): `openLink` asks the node to introduce this device to the other side of a hub-signed grant;
///   `link.incoming`, `link.ready` and `link.closed` pushes go to `onLink` (`LinkManager` decides on them).
/// - Invitations: `inviter.bootstrap` pushes arrive when a joiner opens a session with one of this device's
///   invitations; the client then probes, opens its own side of the paired session (on this connection: the node
///   requires it), offers the inviter's candidate, and reports the joiner's candidates + observed endpoint to a
///   handler. Bootstrap sessions run one at a time and close as soon as the joiner's candidates arrive.
///
/// Depends only on Foundation (signing is a closure), so it is tested against the real node outside the extension
/// (`Scripts/InviterNodeTests`).
final class CoordinatorClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  struct BootstrapEvent {
    let invitationCode: String
    let tokenDigest: String
    let transactionId: String
    let tunnelInstanceId: String
    let generation: UInt64
    let joinerKey: String
    let sessionId: String
    let candidates: [Candidate]
    let observedEndpoint: ObservedEndpoint
  }

  struct Candidate: Codable, Equatable {
    let version: Int
    let candidateId: String
    let sessionId: String
    let key: String
    let kind: String
    let transport: String
    let address: String
    let port: UInt16
    let priority: Int
    let expiresAt: String
  }

  struct ObservedEndpoint: Codable, Equatable {
    let version: Int
    let key: String
    let transport: String
    let address: String
    let port: UInt16
  }

  struct Envelope: Codable {
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
    var grant: PeerLinkGrant? = nil
    var linkId: String? = nil
    var probeToken: String? = nil
    var peerKey: String? = nil
    var endpoints: [LinkEndpoint]? = nil
    var punchAt: String? = nil
  }

  /// A `link.opened` reply: the link's id, this side's probe token and the other side
  struct OpenedLink: Equatable, Sendable {
    let linkId: String
    let probeToken: String
    let peerKey: String
  }

  struct NodeError: Codable {
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

  /// Signing domain for the presence challenge, matching hub-net-node's `PurposePresence`
  static let registrationDomain = "hub-network/presence/v1"
  /// How long a request waits for its reply
  var replyTimeout: TimeInterval = 15
  /// How long a bootstrap session waits for the joiner's candidates
  var candidateTimeout: TimeInterval = 30

  private let nodeEndpoint: String
  private let serviceKey: String
  /// Signs the challenge nonce under `registrationDomain`, standard base64
  private let sign: (Data) throws -> String
  private let probe: (String, Data) async throws -> Void
  private let candidates: () -> Candidate?
  private let onBootstrap: (BootstrapEvent) async -> Void
  private let onLink: (Envelope) async -> Void
  private let onStatusChange: (Bool) -> Void
  private let log: (String) -> Void

  private let lock = NSLock()
  private var link: CoordinatorLink?
  private var isRegistered = false
  private var runTask: Task<Void, Never>?
  /// Registrations completed, renewals included (for tests)
  private(set) var registrations = 0

  init(
    nodeEndpoint: String,
    serviceKey: String,
    sign: @escaping (Data) throws -> String,
    probe: @escaping (String, Data) async throws -> Void,
    candidates: @escaping () -> Candidate?,
    onBootstrap: @escaping (BootstrapEvent) async -> Void = { _ in },
    onLink: @escaping (Envelope) async -> Void = { _ in },
    onStatusChange: @escaping (Bool) -> Void,
    log: @escaping (String) -> Void = { _ in }
  ) {
    self.nodeEndpoint = nodeEndpoint
    self.serviceKey = serviceKey
    self.sign = sign
    self.probe = probe
    self.candidates = candidates
    self.onBootstrap = onBootstrap
    self.onLink = onLink
    self.onStatusChange = onStatusChange
    self.log = log
  }

  var registered: Bool { lock.withLock { isRegistered } }

  /// The coordinator this client registers at, as configured
  var nodeEndpointValue: String { nodeEndpoint }

  /// The node's UDP endpoint, where link probes go
  var udpEndpoint: String { Self.nodeUDPEndpoint(nodeEndpoint) }

  /// Asks the node to introduce this device to the other side of `grant` (`link.open`)
  func openLink(_ grant: PeerLinkGrant) async throws -> OpenedLink {
    guard let link = lock.withLock({ isRegistered ? self.link : nil }) else { throw CoordinatorError.closed }
    let opened = try await link.exclusive {
      try await link.request(Envelope(
        majorVersion: 1, minorVersion: 0, type: "link.open", requestId: UUID().uuidString, grant: grant
      ), timeout: self.replyTimeout)
    }
    guard opened.type == "link.opened", let linkId = opened.linkId, let probeToken = opened.probeToken,
      let peerKey = opened.peerKey
    else { throw CoordinatorError.invalidResponse }
    return OpenedLink(linkId: linkId, probeToken: probeToken, peerKey: peerKey)
  }

  /// Sends a link message that has no reply: `link.accept`, `link.reject`, `link.offer` or `link.close`
  func sendLink(_ type: String, linkId: String, endpoints: [LinkEndpoint]? = nil) async throws {
    guard let link = lock.withLock({ self.link }) else { throw CoordinatorError.closed }
    try await link.send(Envelope(majorVersion: 1, minorVersion: 0, type: type, linkId: linkId, endpoints: endpoints))
  }

  func start() {
    lock.withLock {
      guard runTask == nil else { return }
      runTask = Task { [weak self] in await self?.run() }
    }
  }

  func stop() {
    let (task, link) = lock.withLock { () -> (Task<Void, Never>?, CoordinatorLink?) in
      defer {
        runTask = nil
        self.link = nil
      }
      return (runTask, self.link)
    }
    task?.cancel()
    if let link { Task { await link.close() } }
    setRegistered(false)
  }

  /// Closes the current connection as if the network dropped it (for tests): the client registers again at once
  func dropConnection() async {
    await lock.withLock { link }?.close()
  }

  // MARK: Run loop

  private func run() async {
    var failures = 0
    while !Task.isCancelled {
      var wasLive = false
      do {
        wasLive = try await connectAndServe()
      } catch is CancellationError {
        return
      } catch {
        log("coordinator: registration failed: \(error)")
      }
      setRegistered(false)
      guard !Task.isCancelled else { return }
      // A connection that was registered closed: register again at once. Failures back off up to 30 s.
      let delay: TimeInterval
      if wasLive {
        failures = 0
        delay = 0.2
      } else {
        failures += 1
        delay = min(pow(2, Double(failures - 1)), 30)
      }
      log("coordinator: connecting again in \(delay)s")
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
  }

  /// One connection: registers, renews ahead of expiry and serves bootstrap pushes until the socket closes. Returns
  /// whether it was registered.
  private func connectAndServe() async throws -> Bool {
    guard let url = Self.rendezvousURL(nodeEndpoint) else { throw CoordinatorError.invalidNode }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 300
    configuration.timeoutIntervalForResource = 7 * 24 * 3600
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    let link = CoordinatorLink(socket: session.webSocketTask(with: url), log: log)
    lock.withLock { self.link = link }
    defer {
      session.invalidateAndCancel()
      lock.withLock { if self.link === link { self.link = nil } }
    }
    await link.start()

    var expiresAt = try await link.exclusive { try await self.register(link) }
    setRegistered(true)
    log("coordinator: present, lease until \(expiresAt)")

    let renewal = Task { [weak self] in
      while !Task.isCancelled {
        // Half of the remaining lease, so a bootstrap holding the connection can't outlast it
        let wait = max(1, expiresAt.timeIntervalSinceNow / 2)
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        guard !Task.isCancelled, let self else { return }
        do {
          expiresAt = try await link.exclusive { try await self.register(link) }
          self.log("coordinator: renewed, lease until \(expiresAt)")
        } catch {
          self.log("coordinator: renewal failed: \(error); reconnecting")
          await link.close()
          return
        }
      }
    }
    defer { renewal.cancel() }

    // Links are handled apart from invitations, so a bootstrap session holding the connection never delays them
    let links = Task { [weak self] in
      for await push in link.links {
        await self?.onLink(push)
      }
    }
    defer { links.cancel() }

    for await push in await link.bootstraps {
      await handleBootstrap(link, push)
    }
    log("coordinator: connection closed\(await link.closeReason.map { ": \($0)" } ?? "")")
    return true
  }

  // MARK: Registration handshake

  /// Runs the challenge handshake. Call inside `link.exclusive`.
  private func register(_ link: CoordinatorLink) async throws -> Date {
    let challenge = try await link.request(Envelope(
      majorVersion: 1, minorVersion: 0, type: "presence.register", requestId: UUID().uuidString, serviceKey: serviceKey
    ), timeout: replyTimeout)
    guard challenge.type == "presence.challenge", let nonce = challenge.challengeNonce, !nonce.isEmpty else {
      throw CoordinatorError.invalidResponse
    }
    guard let nonceData = Self.base64URLDecode(nonce) ?? Data(base64Encoded: nonce), !nonceData.isEmpty else {
      throw CoordinatorError.invalidNonce
    }
    let registered = try await link.request(Envelope(
      majorVersion: 1, minorVersion: 0, type: "presence.register", requestId: UUID().uuidString,
      serviceKey: serviceKey, challengeNonce: nonce, challengeSignature: try sign(nonceData)
    ), timeout: replyTimeout)
    guard registered.type == "presence.registered", let raw = registered.registrationExpiresAt,
      let expiresAt = Self.parseRFC3339(raw)
    else { throw CoordinatorError.invalidResponse }
    lock.withLock { registrations += 1 }
    return expiresAt
  }

  // MARK: Bootstrap exchange

  private func handleBootstrap(_ link: CoordinatorLink, _ pending: Envelope) async {
    log("inviter.bootstrap rx replay=\(pending.tokenDigest?.prefix(8) ?? "?")")
    guard let invitationCode = pending.invitationCode, let tokenDigest = pending.tokenDigest,
      let transactionId = pending.transactionId, let joinerKey = pending.key,
      !invitationCode.isEmpty, !tokenDigest.isEmpty, !transactionId.isEmpty
    else {
      log("inviter.bootstrap incomplete signal")
      return
    }
    do {
      // The session holds the connection until it closes, so a renewal never runs inside it on older nodes
      let event = try await link.exclusive { () -> BootstrapEvent? in
        let sessionId = try await self.openSessionAfterProbe(link, pending: pending)
        do {
          let event = try await self.exchangeCandidates(link, pending: pending, sessionId: sessionId,
            invitationCode: invitationCode, tokenDigest: tokenDigest, transactionId: transactionId, joinerKey: joinerKey)
          try? await link.send(Envelope(majorVersion: 1, minorVersion: 0, type: "session.close", sessionId: sessionId))
          return event
        } catch {
          try? await link.send(Envelope(majorVersion: 1, minorVersion: 0, type: "session.close", sessionId: sessionId))
          throw error
        }
      }
      if let event { await onBootstrap(event) }
    } catch {
      log("inviter bootstrap exchange failed: \(error)")
    }
  }

  private func exchangeCandidates(
    _ link: CoordinatorLink, pending: Envelope, sessionId: String,
    invitationCode: String, tokenDigest: String, transactionId: String, joinerKey: String
  ) async throws -> BootstrapEvent? {
    if let candidate = candidates() {
      try await link.send(Envelope(
        majorVersion: 1, minorVersion: 0, type: "candidate.offer", sessionId: sessionId,
        candidate: Candidate(version: 1, candidateId: candidate.candidateId, sessionId: sessionId, key: serviceKey,
          kind: candidate.kind, transport: "udp", address: candidate.address, port: candidate.port,
          priority: candidate.priority, expiresAt: candidate.expiresAt)
      ))
    }
    var event: BootstrapEvent?
    let deadline = Date().addingTimeInterval(candidateTimeout)
    while Date() < deadline {
      let list: Envelope
      do {
        list = try await link.candidates(sessionId: sessionId, timeout: deadline.timeIntervalSinceNow)
      } catch CoordinatorError.timeout where event != nil {
        break
      }
      event = BootstrapEvent(
        invitationCode: invitationCode, tokenDigest: tokenDigest, transactionId: transactionId,
        tunnelInstanceId: pending.tunnelInstanceId ?? "", generation: pending.generation ?? 0,
        joinerKey: joinerKey, sessionId: sessionId, candidates: list.candidates ?? [],
        observedEndpoint: list.observedEndpoint ?? ObservedEndpoint(version: 1, key: joinerKey, transport: "udp", address: "", port: 0)
      )
      if !(list.candidates ?? []).isEmpty { break }
    }
    return event
  }

  private func sendProbe(_ pending: Envelope) async throws {
    let data = try JSONEncoder().encode(InvitationProbe(
      version: 1, invitationCode: pending.invitationCode ?? "", key: serviceKey, tokenDigest: pending.tokenDigest ?? "",
      transactionId: pending.transactionId ?? "", tunnelInstanceId: "", generation: 0
    ))
    let endpoint = Self.nodeUDPEndpoint(nodeEndpoint)
    guard !endpoint.isEmpty else { throw CoordinatorError.invalidNode }
    try await probe(endpoint, data)
  }

  /// The node records the UDP probe asynchronously and refuses `session.open` with the retryable
  /// `udp_observation_required` until it has: probe like the joiner does (three datagrams 50 ms apart), then
  /// re-probe and retry the open a few times instead of failing the bootstrap on the first refusal.
  private func openSessionAfterProbe(_ link: CoordinatorLink, pending: Envelope) async throws -> String {
    var attempt = 0
    while true {
      for _ in 0..<3 {
        try await sendProbe(pending)
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      do {
        let opened = try await link.request(Envelope(
          majorVersion: 1, minorVersion: 0, type: "session.open", requestId: UUID().uuidString,
          invitationCode: pending.invitationCode, key: serviceKey, tokenDigest: pending.tokenDigest,
          transactionId: pending.transactionId, tunnelInstanceId: pending.tunnelInstanceId, generation: pending.generation
        ), timeout: replyTimeout)
        guard opened.type == "session.opened", let sessionId = opened.sessionId, !sessionId.isEmpty else {
          throw CoordinatorError.invalidResponse
        }
        return sessionId
      } catch CoordinatorError.node("udp_observation_required") where attempt < 5 {
        attempt += 1
        log("inviter.bootstrap udp observation pending, retry \(attempt)")
        try await Task.sleep(nanoseconds: UInt64(200_000_000 * attempt))
      }
    }
  }

  // MARK: Helpers

  private func setRegistered(_ value: Bool) {
    let changed = lock.withLock { () -> Bool in
      guard isRegistered != value else { return false }
      isRegistered = value
      return true
    }
    if changed { onStatusChange(value) }
  }

  static func parseRFC3339(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) { return date }
    // Go writes up to nanoseconds; keep milliseconds
    guard let dot = value.firstIndex(of: "."), let zone = value[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
      return nil
    }
    let fraction = value[value.index(after: dot)..<zone].prefix(3)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: String(value[..<dot]) + "." + fraction + String(value[zone...]))
  }

  static func base64URLDecode(_ text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    return Data(base64Encoded: base64)
  }

  /// The node's `/rendezvous` URL. The stored endpoint may be a bare `host:port`; the node listens on :1964 for plain
  /// WebSocket + UDP. Defaults the scheme and port like the Go nodeclient's normalizeEndpoint.
  static func rendezvousURL(_ value: String) -> URL? {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalized.contains("://") { normalized = "ws://" + normalized }
    guard var components = URLComponents(string: normalized), components.host != nil,
      ["https", "http", "wss", "ws"].contains(components.scheme ?? "")
    else { return nil }
    if components.scheme == "https" { components.scheme = "wss" }
    if components.scheme == "http" { components.scheme = "ws" }
    if components.port == nil && components.scheme == "ws" { components.port = 1964 }
    let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    components.path = basePath + "/rendezvous"
    components.query = nil
    components.fragment = nil
    return components.url
  }

  static func nodeUDPEndpoint(_ nodeEndpoint: String) -> String {
    var normalized = nodeEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalized.contains("://") { normalized = "ws://" + normalized }
    guard let components = URLComponents(string: normalized), let host = components.host else { return "" }
    let port = components.port ?? (components.scheme == "https" || components.scheme == "wss" ? 443 : 1964)
    return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
  }
}

/// One WebSocket to the node. A reader task delivers every message: replies to the one request in flight, error
/// replies (the node sends them without a request id) to that request, `inviter.bootstrap` pushes to `bootstraps`,
/// link pushes (and errors about a link nobody waits on) to `links`, and `candidate.list` to the session waiting for
/// it. Timeouts never cancel the socket read, so nothing blocks.
actor CoordinatorLink {
  typealias Envelope = CoordinatorClient.Envelope

  private let socket: URLSessionWebSocketTask
  private let log: (String) -> Void
  private var reply: (id: Int, requestId: String?, continuation: CheckedContinuation<Envelope, Error>)?
  private var candidateWaiter: (id: Int, sessionId: String, continuation: CheckedContinuation<Envelope, Error>)?
  private var candidateLists: [String: [Envelope]] = [:]
  private var nextWaiter = 0
  private var pushes: AsyncStream<Envelope>.Continuation!
  let bootstraps: AsyncStream<Envelope>
  private var linkPushes: AsyncStream<Envelope>.Continuation!
  let links: AsyncStream<Envelope>
  private(set) var closeReason: String?
  private var isClosed = false
  /// One holder at a time: registrations, link openings and whole bootstrap sessions
  private var busy = false
  private var queue: [CheckedContinuation<Void, Never>] = []

  init(socket: URLSessionWebSocketTask, log: @escaping (String) -> Void) {
    self.socket = socket
    self.log = log
    var continuation: AsyncStream<Envelope>.Continuation!
    bootstraps = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    pushes = continuation
    var linkContinuation: AsyncStream<Envelope>.Continuation!
    links = AsyncStream(bufferingPolicy: .unbounded) { linkContinuation = $0 }
    linkPushes = linkContinuation
  }

  func start() {
    socket.resume()
    Task { await self.read() }
  }

  private func read() async {
    while !isClosed {
      let message: URLSessionWebSocketTask.Message
      do {
        message = try await socket.receive()
      } catch {
        finish("\(error.localizedDescription)")
        return
      }
      let data: Data
      switch message {
      case .data(let value): data = value
      case .string(let value): data = Data(value.utf8)
      @unknown default: continue
      }
      guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.majorVersion == 1 else {
        log("coordinator: unreadable message")
        continue
      }
      deliver(envelope)
    }
  }

  private func deliver(_ envelope: Envelope) {
    if envelope.type == "inviter.bootstrap" {
      pushes.yield(envelope)
    } else if ["link.incoming", "link.ready", "link.closed"].contains(envelope.type) {
      linkPushes.yield(envelope)
    } else if envelope.type == "error" {
      let error = CoordinatorError.node(envelope.error?.code ?? "unknown")
      // An error about a link carries its id and no request id unless it answers one
      if let reply, envelope.requestId == reply.requestId || (envelope.requestId == nil && envelope.linkId == nil) {
        self.reply = nil
        reply.continuation.resume(throwing: error)
      } else if envelope.linkId != nil {
        linkPushes.yield(envelope)
      } else {
        log("coordinator: error \(envelope.error?.code ?? "?") \(envelope.error?.message ?? "")")
      }
    } else if envelope.type == "candidate.list", let sessionId = envelope.sessionId {
      if let waiter = candidateWaiter, waiter.sessionId == sessionId {
        candidateWaiter = nil
        waiter.continuation.resume(returning: envelope)
      } else {
        candidateLists[sessionId, default: []].append(envelope)
      }
    } else if let reply, envelope.requestId == nil || envelope.requestId == reply.requestId {
      self.reply = nil
      reply.continuation.resume(returning: envelope)
    }
  }

  private func finish(_ reason: String) {
    guard !isClosed else { return }
    isClosed = true
    closeReason = reason
    pushes.finish()
    linkPushes.finish()
    if let reply {
      self.reply = nil
      reply.continuation.resume(throwing: CoordinatorError.closed)
    }
    if let waiter = candidateWaiter {
      candidateWaiter = nil
      waiter.continuation.resume(throwing: CoordinatorError.closed)
    }
  }

  func close() {
    socket.cancel(with: .goingAway, reason: nil)
    finish("closed by the client")
  }

  func send(_ envelope: Envelope) async throws {
    guard !isClosed else { throw CoordinatorError.closed }
    let data = try JSONEncoder().encode(envelope)
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }

  /// Sends a request and waits for its reply (or an error reply) up to `timeout`. Call inside `exclusive`.
  func request(_ envelope: Envelope, timeout: TimeInterval) async throws -> Envelope {
    guard !isClosed else { throw CoordinatorError.closed }
    nextWaiter += 1
    let id = nextWaiter
    return try await withCheckedThrowingContinuation { continuation in
      reply = (id, envelope.requestId, continuation)
      Task {
        do {
          try await self.send(envelope)
        } catch {
          self.failReply(id, error)
        }
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
        self.failReply(id, CoordinatorError.timeout)
      }
    }
  }

  private func failReply(_ id: Int, _ error: Error) {
    guard let reply, reply.id == id else { return }
    self.reply = nil
    reply.continuation.resume(throwing: error)
  }

  /// The next `candidate.list` of the session, up to `timeout`
  func candidates(sessionId: String, timeout: TimeInterval) async throws -> Envelope {
    if var lists = candidateLists[sessionId], !lists.isEmpty {
      let first = lists.removeFirst()
      candidateLists[sessionId] = lists.isEmpty ? nil : lists
      return first
    }
    guard !isClosed else { throw CoordinatorError.closed }
    nextWaiter += 1
    let id = nextWaiter
    return try await withCheckedThrowingContinuation { continuation in
      candidateWaiter = (id, sessionId, continuation)
      Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
        self.failCandidates(id)
      }
    }
  }

  private func failCandidates(_ id: Int) {
    guard let waiter = candidateWaiter, waiter.id == id else { return }
    candidateWaiter = nil
    waiter.continuation.resume(throwing: CoordinatorError.timeout)
  }

  /// Runs `body` while no other registration, link opening or bootstrap session uses the connection
  func exclusive<T>(_ body: @Sendable () async throws -> T) async throws -> T {
    if busy {
      await withCheckedContinuation { queue.append($0) }
    }
    busy = true
    defer {
      if queue.isEmpty {
        busy = false
      } else {
        queue.removeFirst().resume()
      }
    }
    return try await body()
  }
}

enum CoordinatorError: Error, Equatable {
  case invalidNode
  case invalidResponse
  case invalidNonce
  case timeout
  case closed
  case node(String)
}
