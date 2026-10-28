//
//  HubNetDaemon.swift
//  Hub
//
//  The hub-net agent (Network/hub-net, Go) is this device's Hub Network where there's no NetworkExtension: on Linux
//  it runs as a privileged service with kernel WireGuard. The app talks to its command socket, the same requests its
//  CLI sends (`hub-net join|local|leave|list|vpn`): JSON in an HTTP POST to /v1/command over a Unix socket.
//
//  The service's socket is `/var/lib/hub-net/command.sock`, for root only, unless it was started to share it with a
//  group (`hub-net -socket /run/hub-net/command.sock -socket-group hub-net`); a member of that group runs the app.
//  `HUB_NET_COMMAND_SOCKET` names another socket.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The hub-net agent's command socket
struct HubNetDaemon: Sendable {
  /// One hub this device is on through the agent, as `hub-net list` shows it
  struct Membership: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
      case starting, connected, disconnected, error, stopping
      /// Kept with its keys and address, without a tunnel (`hub-net pause`)
      case paused
    }
    /// The membership's id: the invitation's token id, `local-…` for the hub on this machine
    let id: String
    /// The name `hub-net leave` takes, from the hub's name
    let alias: String
    /// The hub's name
    let header: String
    let status: Status
    let error: String?
    let nodeUrl: String?
    let gatewayAllowed: Bool
    let overlayIpv4: String?
    let overlayIpv6: String?
    /// Where the membership reaches the hub (a `ws://` URL), as the agent recorded it at the join
    let hubAddress: String?

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      alias = try container.decode(String.self, forKey: .alias)
      header = try container.decodeIfPresent(String.self, forKey: .header) ?? alias
      // A status this app doesn't know yet reads as starting
      status = (try? container.decode(Status.self, forKey: .status)) ?? .starting
      error = try container.decodeIfPresent(String.self, forKey: .error)
      nodeUrl = try container.decodeIfPresent(String.self, forKey: .nodeUrl)
      gatewayAllowed = try container.decodeIfPresent(Bool.self, forKey: .gatewayAllowed) ?? false
      overlayIpv4 = try container.decodeIfPresent(String.self, forKey: .overlayIpv4)
      overlayIpv6 = try container.decodeIfPresent(String.self, forKey: .overlayIpv6)
      hubAddress = try container.decodeIfPresent(String.self, forKey: .hubAddress)
    }

    private enum CodingKeys: String, CodingKey {
      case id, alias, header, status, error, nodeUrl, gatewayAllowed, overlayIpv4, overlayIpv6, hubAddress
    }
  }

  /// What `join` and `local` made
  struct Joined: Decodable, Sendable {
    struct Record: Decodable, Sendable {
      let id: String
      let alias: String
      let header: String
      /// The hub's address: `ws://<its overlay address>:1997` for a joined hub
      let hubAddress: String?
      let canonicalIpv4: String?
      let canonicalIpv6: String?
      let local: Bool?

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        alias = try container.decode(String.self, forKey: .alias)
        header = try container.decodeIfPresent(String.self, forKey: .header) ?? alias
        // Any JSON value in the agent; the CLI and the app always give a string
        hubAddress = try? container.decodeIfPresent(String.self, forKey: .hubAddress)
        canonicalIpv4 = try container.decodeIfPresent(String.self, forKey: .canonicalIpv4)
        canonicalIpv6 = try container.decodeIfPresent(String.self, forKey: .canonicalIpv6)
        local = try container.decodeIfPresent(Bool.self, forKey: .local)
      }

      private enum CodingKeys: String, CodingKey {
        case id, alias, header, hubAddress, canonicalIpv4, canonicalIpv6, local
      }
    }
    let record: Record
    /// The hub's machine on the overlay, for a joined hub
    let virtualHost: String?
    let virtualIp: String?
  }

  enum Failure: LocalizedError, Equatable {
    /// No socket, or nothing listening on it
    case notRunning(String)
    /// The socket is there but this user may not use it
    case notPermitted(String)
    /// The agent answered with an error
    case refused(String)
    case malformed

    var errorDescription: String? {
      switch self {
      case .notRunning:
        "Hub Network runs through the hub-net service here, and it isn’t running. Start it, then try again."
      case .notPermitted:
        "This user may not use the hub-net service. Add it to the service’s group (hub-net), then sign in again."
      case .refused(let message):
        message
      case .malformed:
        "The hub-net service gave an answer Hub doesn’t understand. Update hub-net and Hub."
      }
    }
  }

  let socketPath: String

  /// The socket `HUB_NET_COMMAND_SOCKET` names, else the shared one under /run, else the service's own
  static var defaultSocketPath: String {
    if let path = ProcessInfo.processInfo.environment["HUB_NET_COMMAND_SOCKET"], !path.isEmpty { return path }
    let shared = "/run/hub-net/command.sock"
    return FileManager.default.fileExists(atPath: shared) ? shared : "/var/lib/hub-net/command.sock"
  }

  init(socketPath: String = Self.defaultSocketPath) {
    self.socketPath = socketPath
  }

  // MARK: Commands

  func list() async throws -> [Membership] {
    try await command(Request(command: "list"), timeout: 10).items ?? []
  }

  /// Joins a hub's network with an invitation (`hub://join/…` or its code). The agent meets the inviting device
  /// directly, which can take a while.
  func join(invitation: String) async throws -> Joined {
    guard let joined = try await command(Request(command: "join", code: invitation), timeout: 180).joined else {
      throw Failure.malformed
    }
    return joined
  }

  /// Makes the agent the network agent of the hub that runs on this machine, at `address`
  func local(address: String) async throws -> Joined {
    guard let joined = try await command(Request(command: "local", address: address), timeout: 30).joined else {
      throw Failure.malformed
    }
    return joined
  }

  /// Leaves a hub's network; leaving one this device isn't on does nothing
  func leave(alias: String) async throws {
    _ = try await command(Request(command: "leave", alias: alias), timeout: 30)
  }

  /// Takes the tunnel down and keeps the membership (`hub-net pause`), or brings it back (`resume`)
  func setPaused(_ paused: Bool, alias: String) async throws {
    _ = try await command(Request(command: paused ? "pause" : "resume", alias: alias), timeout: 30)
  }

  /// Lets the hub's devices use this device's internet, or stops
  func setGateway(alias: String, allowed: Bool) async throws {
    _ = try await command(Request(command: allowed ? "vpnAllow" : "vpnRemove", alias: alias), timeout: 30)
  }

  /// Shares a port of this device with the hub's devices (TCP and UDP), or stops
  func setPort(_ port: UInt16, open: Bool, alias: String) async throws {
    _ = try await command(Request(command: open ? "open" : "close", alias: alias, port: port), timeout: 30)
  }

  // MARK: Transport

  private struct Request: Encodable {
    var version = 1
    let command: String
    var code: String?
    var address: String?
    var alias: String?
    var port: UInt16?
  }

  private struct Response: Decodable {
    let joined: Joined?
    let items: [Membership]?
    let error: String?
  }

  private func command(_ request: Request, timeout: Int) async throws -> Response {
    let body = try JSONEncoder().encode(request)
    let path = socketPath
    let data = try await Task.detached {
      try HubNetDaemon.post(body, path: "/v1/command", socket: path, timeout: timeout)
    }.value
    let response: Response
    do {
      response = try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw Failure.malformed
    }
    if let error = response.error, !error.isEmpty { throw Failure.refused(error) }
    return response
  }

  /// One HTTP/1.1 request over the Unix socket, blocking: the response's body
  private static func post(_ body: Data, path: String, socket socketPath: String, timeout: Int) throws -> Data {
    let fd = try openSocket(socketPath, timeout: timeout)
    defer { close(fd) }
    var message = Data(
      "POST \(path) HTTP/1.1\r\nHost: hub-net\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        .utf8)
    message.append(body)
    try message.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let count = sendBytes(fd, raw.baseAddress! + sent, raw.count - sent)
        guard count > 0 else { throw Failure.notRunning(String(cString: strerror(errno))) }
        sent += count
      }
    }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw Failure.notRunning(String(cString: strerror(errno)))
      }
      response.append(contentsOf: buffer[0..<count])
      guard response.count < 4 * 1024 * 1024 else { throw Failure.malformed }
    }
    return try httpBody(response)
  }

  private static func openSocket(_ socketPath: String, timeout: Int) throws -> Int32 {
#if os(Linux)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
#else
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
#endif
    guard fd >= 0 else { throw Failure.notRunning(String(cString: strerror(errno))) }
    var interval = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
#if canImport(Darwin)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
#endif
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(fd)
      throw Failure.notRunning("socket path too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
#if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
#endif
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let code = errno
      close(fd)
      let reason = String(cString: strerror(code))
      throw code == EACCES || code == EPERM ? Failure.notPermitted(reason) : Failure.notRunning(reason)
    }
    return fd
  }

  private static func sendBytes(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
#if os(Linux)
    send(fd, pointer, count, Int32(MSG_NOSIGNAL))
#else
    send(fd, pointer, count, 0)
#endif
  }

  /// The body of an HTTP/1.1 response, de-chunked; any status (the agent answers errors as JSON with 400)
  static func httpBody(_ response: Data) throws -> Data {
    let separator = Data("\r\n\r\n".utf8)
    guard let end = response.range(of: separator),
          let head = String(data: response[..<end.lowerBound], encoding: .utf8) else { throw Failure.malformed }
    let lines = head.components(separatedBy: "\r\n")
    guard lines.first?.hasPrefix("HTTP/1.") == true else { throw Failure.malformed }
    let chunked = lines.dropFirst().contains {
      let parts = $0.split(separator: ":", maxSplits: 1)
      return parts.count == 2 && parts[0].lowercased() == "transfer-encoding"
        && parts[1].lowercased().contains("chunked")
    }
    let body = Data(response[end.upperBound...])
    guard chunked else { return body }
    var result = Data()
    var index = body.startIndex
    let lineEnd = Data("\r\n".utf8)
    while let sizeEnd = body.range(of: lineEnd, in: index..<body.endIndex) {
      let sizeText = String(decoding: body[index..<sizeEnd.lowerBound], as: UTF8.self)
        .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
      guard let size = Int(sizeText, radix: 16) else { throw Failure.malformed }
      if size == 0 { break }
      let start = sizeEnd.upperBound
      guard body.distance(from: start, to: body.endIndex) >= size else { throw Failure.malformed }
      let stop = body.index(start, offsetBy: size)
      result.append(body[start..<stop])
      index = body.index(stop, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
    }
    return result
  }
}
