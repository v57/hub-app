#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import HubService

/// This Mac's Hub Network agent for the services on it: they publish network shares with an attestation that this
/// machine fronts them (hub-net's `ipc/attest.go`), and the hub's link to this machine opens their ports. The system
/// agent listens on `/var/run/hub-net/agent.sock`, which an app running as the user can't create, so the app answers
/// on `~/.hub-net/agent.sock`, where the SDKs look next (`HUB_NET_AGENT_SOCKET` overrides both).
///
/// `POST /challenge {serviceKey, shareName, protocol, target}` → `{nonce, key, …}`; the service signs the nonce with
/// its key; `POST /attest {…, signature}` → the `AgentAttestation`, signed by `identity` (the key this app binds as the
/// hub's machine agent). Only processes of this user connect, and targets are this machine's addresses.
final class LocalShareAgent: @unchecked Sendable {
  static let challengeLifetime: TimeInterval = 30
  static let attestationLifetime: TimeInterval = 2 * 60
  static var socketPath: String {
    ProcessInfo.processInfo.environment["HUB_NET_AGENT_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
      ?? (NSHomeDirectory() as NSString).appendingPathComponent(".hub-net/agent.sock")
  }

  private let identity: KeyChain
  private let path: String
  private let queue = DispatchQueue(label: "dev.v57.Hub.local-share-agent")
  private var listener: Int32 = -1
  private var source: DispatchSourceRead?
  private var pending: [String: Pending] = [:]

  private struct Pending {
    let nonce: String
    let expiresAt: Date
  }

  init(identity: KeyChain, path: String = LocalShareAgent.socketPath) {
    self.identity = identity
    self.path = path
  }

  deinit { stop() }

  /// Listens on the socket, replacing one a previous run left behind
  func start() throws {
    stop()
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(fd)
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
      let error = POSIXError(.init(rawValue: errno) ?? .EIO)
      close(fd)
      throw error
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    listener = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.accept() }
    source.resume()
    self.source = source
  }

  func stop() {
    source?.cancel()
    source = nil
    if listener >= 0 {
      close(listener)
      listener = -1
      unlink(path)
    }
  }

  // MARK: Connections

  private func accept() {
    while true {
      let fd = Darwin.accept(listener, nil, nil)
      guard fd >= 0 else { return }
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
        close(fd)
        continue
      }
      // A peer that stops sending doesn't hold the agent
      var timeout = timeval(tv_sec: 5, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      DispatchQueue.global().async { [weak self] in
        defer { close(fd) }
        guard let self, let request = Self.readRequest(fd) else { return }
        let (status, body) = self.queue.sync { self.respond(method: request.method, path: request.path, body: request.body) }
        Self.write(fd, status: status, body: body)
      }
    }
  }

  private static func readRequest(_ fd: Int32) -> (method: String, path: String, body: Data)? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while data.count < 1_048_576 {
      if let end = data.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n")
        let line = head.first?.split(separator: " ") ?? []
        guard line.count >= 2 else { return nil }
        let length = head.dropFirst().compactMap { field -> Int? in
          let parts = field.split(separator: ":", maxSplits: 1)
          guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
          return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let bodyStart = end.upperBound
        while data.count - bodyStart < length {
          let n = read(fd, &buffer, buffer.count)
          guard n > 0 else { return nil }
          data.append(buffer, count: n)
        }
        return (String(line[0]), String(line[1]), data[bodyStart..<bodyStart + length])
      }
      let n = read(fd, &buffer, buffer.count)
      guard n > 0 else { return nil }
      data.append(buffer, count: n)
    }
    return nil
  }

  private static func write(_ fd: Int32, status: Int, body: Data) {
    let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
    var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
    response.append(body)
    response.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        guard n > 0 else { return }
        offset += n
      }
    }
  }

  // MARK: Attestation

  private struct Request: Decodable {
    let serviceKey: String
    let shareName: String?
    let `protocol`: NetworkProtocol?
    let target: LocalTarget?
    let nonce: String?
    let signature: String?
  }

  /// Answers one request; runs on `queue`
  func respond(method: String, path: String, body: Data) -> (Int, Data) {
    guard path == "/challenge" || path == "/attest" else {
      return path == "/" || path == "/status" ? (200, json(["key": identity.publicKey(), "ready": true])) : failure(404, "not_found", "unknown path")
    }
    guard method == "POST" else { return failure(405, "method_not_allowed", "use POST") }
    guard let request = try? JSONDecoder().decode(Request.self, from: body) else { return failure(400, "invalid_request", "invalid JSON") }
    guard let serviceKey = KeyChain.rawPublicKey(spkiBase64: request.serviceKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }) else {
      return failure(400, "invalid_request", "serviceKey not a valid SPKI ed25519 key")
    }
    let now = Date()
    pending = pending.filter { $0.value.expiresAt > now }
    if path == "/challenge" {
      var bytes = [UInt8](repeating: 0, count: 24)
      _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      let nonce = Data(bytes).base64EncodedString()
      pending[Self.pendingKey(request)] = Pending(nonce: nonce, expiresAt: now.addingTimeInterval(Self.challengeLifetime))
      return (200, json(["version": hubNetworkWireVersion, "type": "attest.response", "nonce": nonce, "key": identity.publicKey(),
                         "issuedAt": Self.date(now), "expiresAt": Self.date(now.addingTimeInterval(Self.challengeLifetime))]))
    }
    guard let shareName = request.shareName, !shareName.isEmpty, let networkProtocol = request.protocol,
          let target = request.target, target.port != 0, let signature = request.signature.flatMap({ Data(base64Encoded: $0) }) else {
      return failure(400, "invalid_request", "missing attestation fields")
    }
    guard let challenge = pending.removeValue(forKey: Self.pendingKey(request)) else {
      return failure(403, "invalid_nonce", "nonce unknown or expired")
    }
    guard serviceKey.isValidSignature(signature, for: Data(challenge.nonce.utf8)) else {
      return failure(403, "invalid_signature", "signature does not verify under serviceKey")
    }
    guard Self.isLocal(target.host) else { return failure(403, "remote_target", "target is not a local address") }
    let unsigned = AgentAttestation(
      attestationId: UUID().uuidString.lowercased(), serviceKey: request.serviceKey, key: identity.publicKey(),
      shareName: shareName, protocol: networkProtocol, target: target, issuedAt: Self.date(now),
      expiresAt: Self.date(now.addingTimeInterval(Self.attestationLifetime)), signature: ""
    )
    do {
      let input = try HubNetworkSignedEnvelope.signatureInput(for: unsigned, domain: "hub-network/agent-attestation/v1")
      let attestation = AgentAttestation(
        attestationId: unsigned.attestationId, serviceKey: unsigned.serviceKey, key: unsigned.key, shareName: unsigned.shareName,
        protocol: unsigned.protocol, target: unsigned.target, issuedAt: unsigned.issuedAt, expiresAt: unsigned.expiresAt,
        signature: identity.sign(data: input)
      )
      return (200, try JSONEncoder().encode(attestation))
    } catch {
      return failure(500, "agent_unavailable", "\(error)")
    }
  }

  private static func pendingKey(_ request: Request) -> String {
    [request.serviceKey, request.shareName ?? "", request.protocol?.rawValue ?? "", request.target?.host ?? "",
     String(request.target?.port ?? 0)].joined(separator: "\u{0}")
  }

  /// Loopback or one of this machine's addresses
  static func isLocal(_ host: String) -> Bool {
    if host == "localhost" { return true }
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0 else { return false }
    defer { freeifaddrs(addresses) }
    let wanted = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    var next = addresses
    while let entry = next?.pointee {
      defer { next = entry.ifa_next }
      guard let address = entry.ifa_addr, [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
      var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
      let numeric = String(cString: name).split(separator: "%").first.map(String.init) ?? ""
      if numeric == wanted { return true }
    }
    return false
  }

  private static func date(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
  }

  private func failure(_ status: Int, _ code: String, _ message: String) -> (Int, Data) {
    (status, json(["error": code, "message": message]))
  }
}
#endif
