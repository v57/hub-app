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
    let attempts = retries + 1
    for attempt in 0..<attempts {
      if attempt > 0 {
        try? await Task.sleep(for: .milliseconds(50 * attempt))
      }
      do {
        return try await sendOnce(
          host: host,
          port: port,
          frame: frame,
          requestID: requestID,
          request: request,
          expectedInviterServiceKey: expectedInviterServiceKey,
          timeout: timeout
        )
      } catch {
        lastError = error
        if let exchange = error as? ExchangeError, !exchange.retryable {
          throw error
        }
      }
    }
    throw lastError ?? DirectBootstrapClientError.timedOut
  }

  private static func sendOnce(
    host: String,
    port: UInt16,
    frame: Data,
    requestID: Data,
    request: DirectBootstrapRequest,
    expectedInviterServiceKey: String,
    timeout: TimeInterval
  ) async throws -> DirectBootstrapResponse {
    let connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!,
      using: .udp
    )
    let started = AsyncStream<Void> { continuation in
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          continuation.yield()
          continuation.finish()
        case .failed:
          continuation.finish()
        case .cancelled:
          continuation.finish()
        default:
          break
        }
      }
      connection.start(queue: .global(qos: .userInitiated))
    }
    var iterator = started.makeAsyncIterator()
    let ready = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        _ = await iterator.next()
        return true
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return false
      }
      let value = await group.next() ?? false
      group.cancelAll()
      return value
    }
    guard ready else {
      connection.cancel()
      throw DirectBootstrapClientError.timedOut
    }

    defer { connection.cancel() }
    return try await withThrowingTaskGroup(of: DirectBootstrapResponse.self) { group in
      group.addTask {
        try await Task.sleep(for: .seconds(timeout))
        throw DirectBootstrapClientError.timedOut
      }
      group.addTask {
        var attempts = 0
        while attempts < 3 {
          attempts += 1
          let sent = AsyncStream<NWError?> { continuation in
            connection.send(content: frame, completion: .contentProcessed { error in
              continuation.yield(error)
              continuation.finish()
            })
          }
          for await error in sent {
            if let error {
              throw DirectBootstrapClientError.transport(error.localizedDescription)
            }
          }
          let received = AsyncStream<Data> { continuation in
            connection.receiveMessage { data, _, _, error in
              if let data {
                continuation.yield(data)
              }
              continuation.finish()
            }
          }
          for await data in received {
            if let reply = try? unmarshalFrame(data) {
              guard reply.requestID == requestID else { continue }
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
                guard let networkError = try? JSONDecoder().decode(
                  NetworkError.self,
                  from: reply.payload
                ) else {
                  throw DirectBootstrapClientError.invalidResponse
                }
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
        }
        throw DirectBootstrapClientError.timedOut
      }
      guard let response = try await group.next() else {
        group.cancelAll()
        throw DirectBootstrapClientError.timedOut
      }
      group.cancelAll()
      return response
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

  /// Loads the transaction-scoped joiner service private key from the shared
  /// keychain group, mirroring `NativeJoinStore`'s secret accounts.
  static func joinerServiceKey(
    transactionId: String,
    profilePublicKey: String
  ) throws -> KeyChain {
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
