import Darwin
import Foundation

/// Picks a reachable IPv4 address for the inviter's advertised endpoints
/// (HUBB bootstrap listener + WireGuard socket).
///
/// The HUBB listener binds INADDR_ANY, so its socket address is 0.0.0.0 —
/// not routable by remote joiners. Mirroring the Go inviter
/// (`hub-net/agent` `-advertise-address` semantics), we advertise the host's
/// primary non-loopback IPv4 instead. The Tailscale CGNAT range
/// (100.64.0.0/10, which also covers the frozen hub-net overlay
/// 100.96.0.0/11) is skipped so candidates do not loop through the tunnel.
enum ReachableAddress {
  static func primaryIPv4() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let head = interfaces else { return nil }
    defer { freeifaddrs(head) }

    struct Candidate {
      let name: String
      let address: String
    }
    var physical: [Candidate] = []
    var fallback: [Candidate] = []

    var cursor: UnsafeMutablePointer<ifaddrs>? = head
    while let ifa = cursor {
      cursor = ifa.pointee.ifa_next
      guard let rawAddr = ifa.pointee.ifa_addr,
            rawAddr.pointee.sa_family == AF_INET else { continue }
      let flags = ifa.pointee.ifa_flags
      guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

      let name = String(cString: ifa.pointee.ifa_name)
      guard !isSkippedInterface(name) else { continue }

      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        getnameinfo(sa, socklen_t(rawAddr.pointee.sa_len), &host,
                    socklen_t(host.count), nil, 0, NI_NUMERICHOST)
      }
      guard result == 0 else { continue }
      let ip = String(cString: host)
      guard isRoutable(ip) else { continue }

      let candidate = Candidate(name: name, address: ip)
      if name.hasPrefix("en") {
        physical.append(candidate)
      } else {
        fallback.append(candidate)
      }
    }
    return (physical + fallback).first?.address
  }

  private static func isSkippedInterface(_ name: String) -> Bool {
    let skipped = ["utun", "awdl", "llw", "ipsec", "ppp", "tun", "tap",
                   "gif", "stf", "bridge"]
    return skipped.contains { name.hasPrefix($0) }
  }

  /// Shared routability rule (used by the inviter's advertised endpoints and
  /// the joiner's probe target resolution): skips unspecified, loopback,
  /// link-local (169.254/16), and CGNAT/Tailscale/overlay (100.64/10).
  static func isRoutableIPv4(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return false }
    let a = parts[0], b = parts[1], c = parts[2], d = parts[3]
    // unspecified
    if a == 0 && b == 0 && c == 0 && d == 0 { return false }
    // loopback 127/8
    if a == 127 { return false }
    // link-local 169.254/16
    if a == 169 && b == 254 { return false }
    // CGNAT / Tailscale + frozen overlay 100.64.0.0/10
    let value = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    let base = (UInt32(100) << 24) | (UInt32(64) << 16)
    if (value & 0xFFC00000) == (base & 0xFFC00000) { return false }
    return true
  }

  private static func isRoutable(_ ip: String) -> Bool {
    isRoutableIPv4(ip)
  }
}
