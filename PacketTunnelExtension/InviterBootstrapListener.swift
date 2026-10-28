import Foundation
import Darwin
import HubService
import OSLog

/// Inviter-side UDP endpoint for direct bootstrap exchanges.
///
/// Mirrors the Go `hub-net/agent/invitation` `Listener`: one UDP socket owns
/// both roles —
///
///  1. It accepts framed `DirectBootstrapRequest`s from joiners, feeds them to
///     an `Inviter` handler, and answers with a framed response (or an error
///     frame). Malformed/oversized datagrams are dropped without a reply so
///     the listener cannot be used as a reflection amplifier.
///  2. It sends the inviter's invitation UDP probe to hub-net-node from the
///     same socket, so the node-observed endpoint delivered to the joiner is
///     exactly the listener's address and port.
///
/// Implemented as one POSIX UDP socket (bind `0.0.0.0:0`, single reader) so
/// both roles share the exact same local address:port — the node's observed
/// endpoint and the joiner's dial target are the same socket. This mirrors the
/// Go `Listener` (a `net.UDPConn`).
///
/// Frame format matches `DirectBootstrapClient` exactly: magic `HUBB`, version
/// 1, 26-byte header, 16-byte request ID, UInt32BE payload length, ≤64 KB.
final class InviterBootstrapListener {
  private static let maximumFrameBytes = 64 * 1024
  private static let frameHeaderLength = 26
  private static let frameMagic = Data("HUBB".utf8)

  enum FrameType: UInt8 {
    case request = 1
    case response = 2
    case error = 3
  }

  enum ListenerError: Error, Equatable {
    case closed
    case invalidFrame
    case listenerUnavailable
    case probeFailed(String)
  }

  private let logger = Logger(
    subsystem: "dev.v57.Hub.PacketTunnelExtension",
    category: "InviterBootstrapListener"
  )

  private let handle: (DirectBootstrapRequest) async throws -> DirectBootstrapResponse
  private let socket: Int32
  private var address: sockaddr_in = sockaddr_in()
  private var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
  private let readQueue = DispatchQueue(label: "dev.v57.Hub.PacketTunnelExtension.inviter-listener")
  private var running = false

  /// Binds the UDP listener on an ephemeral port. `handle` verifies a signed
  /// joiner request and returns the signed response.
  init(handle: @escaping (DirectBootstrapRequest) async throws -> DirectBootstrapResponse) throws {
    self.handle = handle
    let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw ListenerError.listenerUnavailable }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = INADDR_ANY
    addr.sin_port = 0
    let bindResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      close(fd)
      throw ListenerError.listenerUnavailable
    }
    socket = fd
  }

  deinit {
    stop()
  }

  /// Starts the read loop and returns the bound address:port.
  func start() -> String {
    var addr = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(socket, $0, &length)
      }
    }
    address = addr
    addressLength = length
    running = true
    readQueue.async { [weak self] in
      self?.readLoop()
    }
    let port = UInt16(bigEndian: addr.sin_port)
    return "0.0.0.0:\(port)"
  }

  func stop() {
    guard running else { return }
    running = false
    Darwin.shutdown(socket, SHUT_RDWR)
    close(socket)
  }

  var port: UInt16? {
    UInt16(bigEndian: address.sin_port)
  }

  /// Sends a datagram from the listener socket to `endpoint`. Used by the
  /// node client as the probe hook so the node observes the listener's
  /// address:port.
  func sendProbe(endpoint: String, payload: Data) async throws {
    // The node is usually a name (v57.dev:1964): resolve it like the joiner's probe, inet_pton below takes only numbers
    guard let target = parseEndpoint(PacketTunnelWireGuardAdapter.resolvedEndpoint(endpoint)) else {
      throw ListenerError.listenerUnavailable
    }
    var destination = sockaddr_in()
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    destination.sin_port = target.port.bigEndian
    let resolved = target.host.withCString({ host in
      inet_pton(AF_INET, host, &destination.sin_addr)
    })
    guard resolved == 1 else {
      throw ListenerError.probeFailed("resolve \(target.host)")
    }
    let sent = payload.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
      withUnsafePointer(to: &destination) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.sendto(
            socket, bytes.baseAddress, payload.count, 0,
            $0, socklen_t(MemoryLayout<sockaddr_in>.size)
          )
        }
      }
    }
    guard sent == payload.count else {
      throw ListenerError.probeFailed("sendto \(String(describing: sent))")
    }
  }

  private func readLoop() {
    var buffer = [UInt8](repeating: 0, count: Self.maximumFrameBytes + 1)
    while running {
      var source = sockaddr_in()
      var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let received = buffer.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Int in
        withUnsafeMutablePointer(to: &source) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.recvfrom(socket, bytes.baseAddress, bytes.count, 0, $0, &sourceLength)
          }
        }
      }
      if received <= 0 { continue }
      let data = Data(bytes: buffer.prefix(received))
      dispatch(data, from: source)
    }
  }

  private func dispatch(_ data: Data, from source: sockaddr_in) {
    extensionDiagnostics("listener rx from=\(Self.sourceString(source)) bytes=\(data.count)")
    // Non-HUBB datagrams are probe responses from the node; the listener does
    // not initiate probe requests itself, so ignore them (the WireGuard
    // backend handles the joiner-side probe; the inviter only serves HUBB).
    guard data.count >= 4, data.prefix(4) == Self.frameMagic else {
      return
    }
    let parsed: Frame
    do {
      parsed = try unmarshalFrame(data)
    } catch {
      logger.debug("drop malformed bootstrap frame")
      return
    }
    guard parsed.type == .request else { return }
    let request: DirectBootstrapRequest
    do {
      request = try JSONDecoder().decode(DirectBootstrapRequest.self, from: parsed.payload)
    } catch {
      writeError(source, requestID: parsed.requestID, code: "bootstrap_request_invalid", message: "invalid request payload", retryable: false)
      return
    }
    Task {
      do {
        let response = try await handle(request)
        let payload = try JSONEncoder().encode(response)
        try writeFrame(source, type: .response, requestID: parsed.requestID, payload: payload)
        extensionDiagnostics("listener response sent to \(Self.sourceString(source))")
      } catch {
        let mapped = Self.mapError(error)
        writeError(source, requestID: parsed.requestID, code: mapped.code, message: mapped.message, retryable: mapped.retryable)
        extensionDiagnostics("listener error \(mapped.code) to \(Self.sourceString(source))")
      }
    }
  }

  private static func sourceString(_ source: sockaddr_in) -> String {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    var address = source
    let rc = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host,
                    socklen_t(host.count), nil, 0, NI_NUMERICHOST)
      }
    }
    let ip = rc == 0 ? String(cString: host) : "?"
    return "\(ip):\(UInt16(bigEndian: source.sin_port))"
  }

  private static func mapError(_ error: Error) -> (code: String, message: String, retryable: Bool) {
    if let inviterError = error as? InviterError {
      switch inviterError {
      case .invalidRequest(let message): return ("bootstrap_request_invalid", message, false)
      case .replay: return ("bootstrap_replay", "invitation already in use", false)
      case .capacity: return ("bootstrap_capacity", "bootstrap address capacity exceeded", true)
      case .internalError(let message): return ("bootstrap_internal", message, true)
      }
    }
    return ("bootstrap_internal", String(describing: error), true)
  }

  private func writeFrame(_ source: sockaddr_in, type: FrameType, requestID: Data, payload: Data) throws {
    let frame = try marshalFrame(type: type, requestID: requestID, payload: payload)
    let sent = frame.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
      var target = source
      return withUnsafePointer(to: &target) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.sendto(
            socket, bytes.baseAddress, frame.count, 0,
            $0, socklen_t(MemoryLayout<sockaddr_in>.size)
          )
        }
      }
    }
    if sent != frame.count {
      logger.warning("sendto bootstrap response failed (\(sent))")
    }
  }

  private func writeError(_ source: sockaddr_in, requestID: Data, code: String, message: String, retryable: Bool) {
    let networkError = NetworkError(code: code, message: message, retryable: retryable)
    guard let payload = try? JSONEncoder().encode(networkError) else { return }
    try? writeFrame(source, type: .error, requestID: requestID, payload: payload)
  }

  // MARK: Frame codec (mirrors DirectBootstrapClient)

  private struct Frame {
    let type: FrameType
    let requestID: Data
    let payload: Data
  }

  private func marshalFrame(type: FrameType, requestID: Data, payload: Data) throws -> Data {
    guard requestID.count == 16,
          payload.count <= Self.maximumFrameBytes - Self.frameHeaderLength else {
      throw ListenerError.invalidFrame
    }
    var frame = Data()
    frame.append(Self.frameMagic)
    frame.append(1)
    frame.append(type.rawValue)
    frame.append(requestID)
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
  }

  private func unmarshalFrame(_ data: Data) throws -> Frame {
    guard data.count <= Self.maximumFrameBytes,
          data.count >= Self.frameHeaderLength,
          data.prefix(4) == Self.frameMagic,
          data[data.index(data.startIndex, offsetBy: 4)] == 1 else {
      throw ListenerError.invalidFrame
    }
    guard let type = FrameType(rawValue: data[data.index(data.startIndex, offsetBy: 5)]) else {
      throw ListenerError.invalidFrame
    }
    let requestID = data.subdata(in: 6..<22)
    let length = data.withUnsafeBytes {
      $0.loadUnaligned(fromByteOffset: 22, as: UInt32.self).bigEndian
    }
    guard data.count == Self.frameHeaderLength + Int(length) else {
      throw ListenerError.invalidFrame
    }
    return Frame(
      type: type,
      requestID: requestID,
      payload: data.subdata(in: Self.frameHeaderLength..<data.count)
    )
  }

  private func parseEndpoint(_ value: String) -> (host: String, port: UInt16)? {
    if value.hasPrefix("[") {
      guard let closing = value.firstIndex(of: "]") else { return nil }
      let host = String(value[value.index(after: value.startIndex)..<closing])
      let remainder = value[value.index(after: closing)...]
      guard remainder.hasPrefix(":"),
            let port = UInt16(remainder.dropFirst()),
            port != 0 else { return nil }
      return (host, port)
    }
    guard let separator = value.lastIndex(of: ":"),
          separator != value.startIndex,
          let port = UInt16(value[value.index(after: separator)...]),
          port != 0 else { return nil }
    return (String(value[..<separator]), port)
  }
}
