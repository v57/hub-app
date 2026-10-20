import CryptoKit
import Foundation
import HubService
import Network

/// Joiner-side client for the direct bootstrap UDP transport.
///
/// The inviter runs one UDP listener (`HUBB` magic, version 1, request/response/
/// error frames) and answers a framed, signed `DirectBootstrapRequest` with a
/// framed `DirectBootstrapResponse` signed by the invitation service key. This
/// client signs the request with the joiner's service identity, exchanges over
/// one short-lived UDP socket, and verifies the response before returning it.
enum DirectBootstrapClient {
  static let frameMagic = Data("HUBB".utf8)
  static let frameVersion: UInt8 = 1
  static let frameHeaderLength = 26
  static let maximumFrameBytes = 64 * 1024
  static let requestIDLength = 16

  private enum FrameType: UInt8 {
    case request = 1
    case response = 2
    case error = 3
  }

  struct ExchangeError: Error, Equatable {
    let code: String
    let message: String
    let retryable: Bool
  }

  /// Sends one signed request to the inviter listener and returns the verified
  /// response. Identical retries are safe: the inviter handler is idempotent
  /// for the same replay id and nonce.
  static func exchange(
    endpoint: String,
    request: DirectBootstrapRequest,
    expectedInviterServiceKey: String,
    timeout: TimeInterval = 8,
    retries: Int = 3
  ) async throws -> DirectBootstrapResponse {
    let requestID = randomRequestID()
    let payload = try JSONEncoder().encode(request)
    let frame = try marshalFrame(type: .request, requestID: requestID, payload: payload)
    let host: String
    let port: UInt16
    do {
      let parsed = try parseEndpoint(endpoint)
      host = parsed.host
      port = parsed.port
    } catch {
      throw DirectBootstrapClientError.invalidEndpoint
    }

    var lastError: Error?
    let deadline = Date().addingTimeInterval(timeout)
    for attempt in 0...max(0, retries) {
      if attempt > 0 {
        try? await Task.sleep(for: .milliseconds(50 * attempt))
      }
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      do {
        return try await sendOnce(
          host: host,
          port: port,
          frame: frame,
          requestID: requestID,
          request: request,
          expectedInviterServiceKey: expectedInviterServiceKey,
          timeout: remaining
        )
      } catch {
        lastError = error
        // Only a retryable inviter error is worth another attempt; a timeout
        // already resent the request for the whole window.
        guard let exchange = error as? ExchangeError, exchange.retryable else {
          throw error
        }
      }
    }
    throw lastError ?? DirectBootstrapClientError.timedOut
  }

  /// One exchange on an unconnected UDP socket, resending the request every
  /// second until `timeout`. An inviter on a multi-homed host (VM bridges,
  /// VPNs, several interfaces) may answer from another of its addresses, which
  /// a connected socket would drop; the response is signed by the invitation
  /// key and verified, so its source address does not matter. Runs on its own
  /// thread so the blocking poll never holds a Swift concurrency thread.
  private static func sendOnce(
    host: String,
    port: UInt16,
    frame: Data,
    requestID: Data,
    request: DirectBootstrapRequest,
    expectedInviterServiceKey: String,
    timeout: TimeInterval
  ) async throws -> DirectBootstrapResponse {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result {
          try exchangeBlocking(
            host: host, port: port, frame: frame, requestID: requestID,
            request: request, expectedInviterServiceKey: expectedInviterServiceKey,
            timeout: timeout
          )
        })
      }
    }
  }

  private static func exchangeBlocking(
    host: String,
    port: UInt16,
    frame: Data,
    requestID: Data,
    request: DirectBootstrapRequest,
    expectedInviterServiceKey: String,
    timeout: TimeInterval
  ) throws -> DirectBootstrapResponse {
    var (target, targetLength) = try socketAddress(host: host, port: port)
    let fd = Darwin.socket(Int32(target.ss_family), SOCK_DGRAM, 0)
    guard fd >= 0 else { throw DirectBootstrapClientError.transport("socket: \(errno)") }
    defer { Darwin.close(fd) }

    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: maximumFrameBytes)
    while Date() < deadline {
      let sent = frame.withUnsafeBytes { bytes in
        withUnsafePointer(to: &target) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, targetLength)
          }
        }
      }
      guard sent == frame.count else {
        throw DirectBootstrapClientError.transport("sendto: \(errno)")
      }
      let resendAt = min(deadline, Date().addingTimeInterval(1))
      while Date() < resendAt {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let waitMilliseconds = Int32(max(1, resendAt.timeIntervalSinceNow * 1000))
        guard Darwin.poll(&descriptor, 1, waitMilliseconds) > 0 else { continue }
        var source = sockaddr_storage()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let received = buffer.withUnsafeMutableBytes { bytes in
          withUnsafeMutablePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              Darwin.recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &sourceLength)
            }
          }
        }
        guard received > 0,
              let reply = try? unmarshalFrame(Data(buffer[0..<received])),
              reply.requestID == requestID else { continue }
        switch reply.type {
        case .response:
          guard let response = try? JSONDecoder().decode(
            DirectBootstrapResponse.self,
            from: reply.payload
          ) else {
            throw DirectBootstrapClientError.invalidResponse
          }
          try DirectBootstrapVerifier.verify(
            response,
            request: request,
            expectedInviterServiceKey: expectedInviterServiceKey
          )
          return response
        case .error:
          // Error frames are unsigned: only the inviter's own address may end
          // the exchange with one.
          guard sameAddress(source, target),
                let networkError = try? JSONDecoder().decode(
                  NetworkError.self,
                  from: reply.payload
                ) else { continue }
          throw ExchangeError(
            code: networkError.code,
            message: networkError.message,
            retryable: networkError.retryable
          )
        case .request:
          continue
        }
      }
    }
    throw DirectBootstrapClientError.timedOut
  }

  /// The sockaddr for an IPv4 or IPv6 literal.
  private static func socketAddress(host: String, port: UInt16) throws -> (sockaddr_storage, socklen_t) {
    var storage = sockaddr_storage()
    var v4 = in_addr()
    if inet_pton(AF_INET, host, &v4) == 1 {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr = v4
      withUnsafeBytes(of: address) { source in
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: source) }
      }
      return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, host, &v6) == 1 {
      var address = sockaddr_in6()
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = port.bigEndian
      address.sin6_addr = v6
      withUnsafeBytes(of: address) { source in
        withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: source) }
      }
      return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
    }
    throw DirectBootstrapClientError.invalidEndpoint
  }

  /// Whether two socket addresses carry the same IP (ports ignored).
  private static func sameAddress(_ left: sockaddr_storage, _ right: sockaddr_storage) -> Bool {
    guard left.ss_family == right.ss_family else { return false }
    var left = left, right = right
    if Int32(left.ss_family) == AF_INET {
      return withUnsafeBytes(of: &left) { l in
        withUnsafeBytes(of: &right) { r in
          l.load(fromByteOffset: 4, as: UInt32.self) == r.load(fromByteOffset: 4, as: UInt32.self)
        }
      }
    }
    return withUnsafeBytes(of: &left) { l in
      withUnsafeBytes(of: &right) { r in
        l[8..<24].elementsEqual(r[8..<24])
      }
    }
  }

  private struct Frame {
    let type: FrameType
    let requestID: Data
    let payload: Data
  }

  private static func marshalFrame(
    type: FrameType,
    requestID: Data,
    payload: Data
  ) throws -> Data {
    guard requestID.count == requestIDLength,
          payload.count <= maximumFrameBytes - frameHeaderLength else {
      throw DirectBootstrapClientError.invalidRequest
    }
    var frame = Data()
    frame.append(frameMagic)
    frame.append(frameVersion)
    frame.append(type.rawValue)
    frame.append(requestID)
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
  }

  private static func unmarshalFrame(_ data: Data) throws -> Frame {
    guard data.count <= maximumFrameBytes,
          data.count >= frameHeaderLength,
          data.prefix(4) == frameMagic,
          data[data.index(data.startIndex, offsetBy: 4)] == frameVersion else {
      throw DirectBootstrapClientError.invalidResponse
    }
    guard let type = FrameType(rawValue: data[data.index(data.startIndex, offsetBy: 5)]) else {
      throw DirectBootstrapClientError.invalidResponse
    }
    let requestID = data.subdata(in: 6..<22)
    let length = data.withUnsafeBytes {
      $0.loadUnaligned(fromByteOffset: 22, as: UInt32.self).bigEndian
    }
    guard data.count == frameHeaderLength + Int(length) else {
      throw DirectBootstrapClientError.invalidResponse
    }
    return Frame(
      type: type,
      requestID: requestID,
      payload: data.subdata(in: frameHeaderLength..<data.count)
    )
  }

  private static func randomRequestID() -> Data {
    var bytes = [UInt8](repeating: 0, count: requestIDLength)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: .min ... .max)
    }
    return Data(bytes)
  }

  private static func parseEndpoint(_ value: String) throws -> (host: String, port: UInt16) {
    if value.hasPrefix("[") {
      guard let closing = value.firstIndex(of: "]") else { throw DirectBootstrapClientError.invalidEndpoint }
      let host = String(value[value.index(after: value.startIndex)..<closing])
      let remainder = value[value.index(after: closing)...]
      guard remainder.hasPrefix(":"),
            let port = UInt16(remainder.dropFirst()),
            port != 0 else { throw DirectBootstrapClientError.invalidEndpoint }
      return (host, port)
    }
      guard let separator = value.lastIndex(of: ":"),
            separator != value.startIndex,
            let port = UInt16(value[value.index(after: separator)...]),
            port != 0 else { throw DirectBootstrapClientError.invalidEndpoint }
      return (String(value[..<separator]), port)
  }

  /// Loads the joiner service private key from the shared keychain group:
  /// the app's identity (`identity.v1`), or the transaction's own key for
  /// transactions staged before the device layer (`NativeJoinStore`'s accounts).
  static func joinerServiceKey(
    transactionId: String,
    profilePublicKey: String
  ) throws -> KeyChain {
    let expectedKey = KeyChain.spkiPublicKey(rawBase64: profilePublicKey) ?? profilePublicKey
    if let identity = try? KeyChain.hubIdentity(), identity.publicKey() == expectedKey {
      return identity
    }
    let accessGroup = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String
    let key = try KeyChain(
      keychain: .init(
        service: "dev.v57.Hub.network.native-join.v1",
        account: "\(hexDigest(transactionId)).profile",
        accessGroup: accessGroup?.isEmpty == false ? accessGroup : nil,
        useDataProtectionKeychain: true
      ),
      createIfMissing: false
    )
    // The staged record's profilePublicKey is raw base64; KeyChain.publicKey()
    // is canonical SPKI — normalize before comparing.
    let expected = KeyChain.spkiPublicKey(rawBase64: profilePublicKey) ?? profilePublicKey
    guard key.publicKey() == expected else {
      throw DirectBootstrapClientError.keyMismatch
    }
    return key
  }

  /// Signs a direct bootstrap request under the joiner's service identity.
  static func signRequest(
    key: KeyChain,
    replayId: String,
    joinerServiceKey: String,
    joinerWireGuardKey: String,
    now: Date = Date()
  ) throws -> DirectBootstrapRequest {
    let nonce = Data((0..<4).map { _ in UInt8.random(in: .min ... .max) })
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    var request = DirectBootstrapRequest(
      replayId: replayId,
      joinerServiceKey: joinerServiceKey,
      joinerWireGuardKey: joinerWireGuardKey,
      nonce: nonce,
      issuedAt: ISO8601DateFormatter.hubNetworkDateString(now),
      signature: ""
    )
    let input = try HubNetworkSignedEnvelope.signatureInput(
      for: request,
      domain: HubNetworkDirectBootstrapDomain.request
    )
    request = DirectBootstrapRequest(
      replayId: replayId,
      joinerServiceKey: joinerServiceKey,
      joinerWireGuardKey: joinerWireGuardKey,
      nonce: nonce,
      issuedAt: request.issuedAt,
      signature: key.sign(data: input)
    )
    return request
  }

  private static func hexDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

enum DirectBootstrapClientError: Error, Equatable {
  case invalidRequest
  case invalidEndpoint
  case invalidResponse
  case timedOut
  case transport(String)
  case keyMismatch
  case keychain
}

extension ISO8601DateFormatter {
  static func hubNetworkDateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
