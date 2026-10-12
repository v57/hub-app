import Foundation
import Channel
import HubService
import Network

/// Direct-only client for hub-net-node's bounded invitation rendezvous
/// protocol. This transport accepts coordination envelopes only; it exposes no
/// byte-forwarding API and therefore cannot become an enrollment relay.
final class InvitationBootstrapClient: NSObject, URLSessionWebSocketDelegate {
  struct Peer: Equatable {
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
  }

  private struct NodeError: Codable {
    let code: String
    let message: String
  }

  private struct UDPProbe: Encodable {
    let version: Int
    let invitationCode: String
    let key: String
    let tokenDigest: String
    let transactionId: String
    let tunnelInstanceId: String
    let generation: UInt64
  }

  private var session: URLSession?
  private var socket: URLSessionWebSocketTask?

  func rendezvous(
    invitationCode: String,
    tokenDigest: String,
    transactionId: String,
    tunnelInstanceId: String,
    generation: UInt64,
    node: String,
    localKey: String,
    localCandidate: Candidate,
    expectedPeerKey: String? = nil,
    sendProbe: @escaping (String, Data) async throws -> Void,
    timeout: TimeInterval = 30
  ) async throws -> Peer {
    let expectedPeerKey = expectedPeerKey
    let url = try Self.rendezvousURL(node)
    let udpEndpoint = try Self.udpEndpoint(node)
    guard !invitationCode.isEmpty, !tokenDigest.isEmpty, !transactionId.isEmpty,
          localCandidate.key == localKey,
          localCandidate.transport == "udp",
          localCandidate.port != 0 else {
      throw InvitationBootstrapError.invalidCandidate
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    let socket = session.webSocketTask(with: url)
    self.session = session
    self.socket = socket
    socket.resume()

    let probe = try JSONEncoder().encode(UDPProbe(
      version: 1, invitationCode: invitationCode,
      key: localKey,
      tokenDigest: tokenDigest, transactionId: transactionId,
      tunnelInstanceId: tunnelInstanceId, generation: generation
    ))
    for _ in 0..<3 {
      try Task.checkCancellation()
      try await sendProbe(udpEndpoint, probe)
      try await Task.sleep(for: .milliseconds(50))
    }

    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Peer.self) { group in
        group.addTask { [weak self] in
          guard let self else { throw CancellationError() }
          return try await self.exchange(
            invitationCode: invitationCode,
            tokenDigest: tokenDigest,
            transactionId: transactionId,
            tunnelInstanceId: tunnelInstanceId,
            generation: generation,
            localKey: localKey,
            localCandidate: localCandidate,
            expectedPeerKey: (expectedPeerKey?.isEmpty == false) ? expectedPeerKey : nil
          )
        }
        group.addTask {
          try await Task.sleep(for: .seconds(timeout))
          throw InvitationBootstrapError.timeout
        }
        guard let peer = try await group.next() else {
          throw InvitationBootstrapError.closed
        }
        group.cancelAll()
        close()
        return peer
      }
    } onCancel: { [weak self] in
      self?.close()
    }
  }

  func close() {
    socket?.cancel(with: .goingAway, reason: nil)
    session?.invalidateAndCancel()
    socket = nil
    session = nil
  }

  private func exchange(
    invitationCode: String,
    tokenDigest: String,
    transactionId: String,
    tunnelInstanceId: String,
    generation: UInt64,
    localKey: String,
    localCandidate: Candidate,
    expectedPeerKey: String?
  ) async throws -> Peer {
    try await send(Envelope(
      majorVersion: 1, minorVersion: 0, type: "session.open",
      requestId: transactionId,
      invitationCode: invitationCode,
      key: localKey,
      
      tokenDigest: tokenDigest,
      transactionId: transactionId,
      tunnelInstanceId: tunnelInstanceId,
      generation: generation
    ))
    let opened = try await receive(expected: "session.opened")
    guard let sessionId = opened.sessionId, !sessionId.isEmpty else {
      throw InvitationBootstrapError.invalidResponse
    }
    let candidate = Candidate(
      version: localCandidate.version, candidateId: localCandidate.candidateId,
      sessionId: sessionId, key: localCandidate.key,
      kind: localCandidate.kind,
      transport: localCandidate.transport, address: localCandidate.address,
      port: localCandidate.port, priority: localCandidate.priority,
      expiresAt: localCandidate.expiresAt
    )
    try await send(Envelope(
      majorVersion: 1, minorVersion: 0, type: "candidate.offer",
      sessionId: sessionId, candidate: candidate
    ))
    while true {
      let response = try await receive()
      guard response.type == "candidate.list" else { continue }
      guard response.sessionId == sessionId,
            let observed = response.observedEndpoint,
            observed.key != localKey,
            (expectedPeerKey == nil || observed.key == expectedPeerKey),
            observed.transport == "udp", observed.port != 0 else {
        throw InvitationBootstrapError.invalidResponse
      }
      let candidates = response.candidates ?? []
      guard candidates.allSatisfy({
        $0.sessionId == sessionId &&
        $0.key == observed.key &&
        $0.transport == "udp" && $0.port != 0
      }) else { throw InvitationBootstrapError.invalidResponse }
      // The node may deliver an empty candidate list before the peer's
      // candidate.offer lands (the inviter offers ~1ms after the joiner's
      // open). Wait for the peer's actual candidates instead of falling
      // back to the observed endpoint — the rendezvous's outer timeout
      // bounds this wait.
      guard !candidates.isEmpty else { continue }
      return Peer(sessionId: sessionId, candidates: candidates, observedEndpoint: observed)
    }
  }

  private func send(_ envelope: Envelope) async throws {
    guard let socket else { throw InvitationBootstrapError.closed }
    let data = try JSONEncoder().encode(envelope)
    guard let text = String(data: data, encoding: .utf8) else {
      throw InvitationBootstrapError.invalidResponse
    }
    // hub-net-node deliberately accepts text-only, unfragmented JSON frames.
    try await socket.send(.string(text))
  }

  private func receive(expected: String? = nil) async throws -> Envelope {
    guard let socket else { throw InvitationBootstrapError.closed }
    let message = try await socket.receive()
    let data: Data
    switch message {
    case .data(let value): data = value
    case .string(let value): data = Data(value.utf8)
    @unknown default: throw InvitationBootstrapError.invalidResponse
    }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.majorVersion == 1, envelope.minorVersion <= 0 else {
      throw InvitationBootstrapError.invalidResponse
    }
    if envelope.type == "error" {
      throw InvitationBootstrapError.node(envelope.error?.code ?? "unknown")
    }
    if let expected, envelope.type != expected {
      throw InvitationBootstrapError.invalidResponse
    }
    return envelope
  }

  private static func rendezvousURL(_ value: String) throws -> URL {
    guard var components = URLComponents(string: value),
          components.host != nil,
          components.scheme == "https" || components.scheme == "http" ||
          components.scheme == "wss" || components.scheme == "ws" else {
      throw InvitationBootstrapError.invalidNode
    }
    if components.scheme == "https" { components.scheme = "wss" }
    if components.scheme == "http" { components.scheme = "ws" }
    let basePath = components.path.hasSuffix("/")
      ? String(components.path.dropLast())
      : components.path
    components.path = basePath + "/rendezvous"
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw InvitationBootstrapError.invalidNode }
    return url
  }

  private static func udpEndpoint(_ value: String) throws -> String {
    guard let components = URLComponents(string: value), let host = components.host else {
      throw InvitationBootstrapError.invalidNode
    }
    let port = components.port ?? (components.scheme == "https" || components.scheme == "wss" ? 443 : 80)
    return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
  }

}

enum InvitationBootstrapError: Error, Equatable {
  case invalidNode
  case invalidCandidate
  case invalidResponse
  case timeout
  case closed
  case node(String)
}
