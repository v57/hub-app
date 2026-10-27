//
//  ListeningApps.swift
//  Hub
//
//  The apps running on this Mac that Share an App lists. The app is sandboxed and can't list other processes' sockets,
//  so it tries the well-known ports on this Mac's own addresses (127.0.0.1 and ::1); a port that accepts a connection
//  has an app behind it. Nothing leaves this Mac.
//

#if canImport(ComponentKit)
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ListeningApps {
  struct Found: Hashable, Identifiable {
    let port: Int
    let app: KnownPorts.App
    var id: Int { port }
  }

  /// The known ports something listens on, lowest first
  @MainActor static func scan() async -> [Found] {
#if DEBUG
    if HubDemo.isOn {
      return [8096, 5173, 5432].compactMap { port in KnownPorts.app(port).map { Found(port: port, app: $0) } }
    }
#endif
    return await withTaskGroup(of: Int?.self) { group in
      for port in KnownPorts.table.keys {
        group.addTask { await accepts(port: port) ? port : nil }
      }
      var found = [Found]()
      for await port in group {
        if let port, let app = KnownPorts.app(port) { found.append(Found(port: port, app: app)) }
      }
      return found.sorted { $0.port < $1.port }
    }
  }

  private static func accepts(port: Int) async -> Bool {
    await Task.detached {
      connects(port: port, ipv6: false) || connects(port: port, ipv6: true)
    }.value
  }

  /// A non-blocking connect to this Mac's own address that gives up after 300 ms
  private static func connects(port: Int, ipv6: Bool) -> Bool {
#if canImport(Darwin)
    let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, IPPROTO_TCP)
#else
    let fd = socket(ipv6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue), Int32(IPPROTO_TCP))
#endif
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var result: Int32
    if ipv6 {
      var address = sockaddr_in6()
#if canImport(Darwin)
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
#endif
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = in_port_t(UInt16(port).bigEndian)
      address.sin6_addr = in6addr_loopback
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
      }
    } else {
      var address = sockaddr_in()
#if canImport(Darwin)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = in_port_t(UInt16(port).bigEndian)
      address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
      result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }
    }
    if result == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&poller, 1, 300) == 1 else { return false }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
    return error == 0
  }
}
#endif
