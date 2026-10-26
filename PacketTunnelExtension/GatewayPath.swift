import Foundation

/// Whether the gateway in use answers, from the bytes WireGuard received from it. Both ends of the path send a
/// keepalive every 25 seconds, so a working path brings something at least that often. A profile that falls back
/// sends this device's traffic through its own network until the first bytes arrive and once none came for `quiet`.
struct GatewayPath {
  static let quiet: TimeInterval = 40

  private var lastBytes = 0
  private var lastReceived: Date?
  private(set) var isReachable: Bool

  /// Starting from what the routes are now: a gateway taken for reachable gets `quiet` to show it
  init(reachable: Bool = false, now: Date = Date()) {
    isReachable = reachable
    lastReceived = reachable ? now : nil
  }

  /// The gateway's new reachability, when it changed. `receivedBytes` is WireGuard's counter for the gateway's peer;
  /// it starts again from zero when the peer is configured anew.
  mutating func update(receivedBytes: Int, now: Date) -> Bool? {
    if receivedBytes < lastBytes { lastBytes = 0 }
    if receivedBytes > lastBytes {
      lastBytes = receivedBytes
      lastReceived = now
    }
    let reachable = lastReceived.map { now.timeIntervalSince($0) < Self.quiet } ?? false
    guard reachable != isReachable else { return nil }
    isReachable = reachable
    return reachable
  }
}
