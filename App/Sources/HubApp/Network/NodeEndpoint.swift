import Foundation

/// Host extraction for hub-net-node endpoint values.
///
/// The node endpoint is stored as a URL for plain (non-TLS) nodes per the
/// runbook (`ws://host:1964`), but the older control-plane derivation used
/// `split(separator: ":").first`, which returns the SCHEME for URL values
/// (`"ws"`) and fed a non-IP into `controlPlaneIPv4Hosts` validation. Accepts
/// bare IPs, `host:port`, full URLs, and bracketed IPv6.
enum HubNetworkNodeEndpoint {
  /// v57.dev's coordinator, what a hub uses until an owner sets another (as HubServer and hub-server do)
  static let `default` = "wss://v57.dev:1964"

  static func host(from endpoint: String) -> String? {
    var value = endpoint.trimmingCharacters(in: .whitespaces)
    for scheme in ["wss://", "ws://", "https://", "http://"] where value.hasPrefix(scheme) {
      value.removeFirst(scheme.count)
      break
    }
    if value.hasPrefix("[") {
      guard let close = value.firstIndex(of: "]") else { return nil }
      return String(value[value.index(after: value.startIndex)..<close])
    }
    if let colon = value.lastIndex(of: ":") {
      value = String(value[..<colon])
    }
    return value.isEmpty ? nil : value
  }

  /// Host extracted from a node endpoint value, returned only when it is a
  /// plain IPv4 — the only form usable as a tunnel control-plane exclusion
  /// (NEIPv4Route entries are per-address; hostnames cannot be excluded).
  static func ipv4Host(from endpoint: String) -> String? {
    guard let host = host(from: endpoint) else { return nil }
    let parts = host.split(separator: ".")
    guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
    return host
  }
}
