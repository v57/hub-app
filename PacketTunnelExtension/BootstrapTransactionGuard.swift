import Foundation
import Network

/// Pure bootstrap trust boundary shared by provider orchestration and tests.
/// Network and WireGuard side effects stay behind their respective adapters.
enum BootstrapTransactionGuard {
  struct Identity: Equatable {
    let tunnelInstanceId: String
    let generation: UInt64
  }

  struct Pin: Equatable {
    let assignmentId: String
    let tokenDigest: String
    let transactionId: String
    let hubNetworkId: String
    let tunnelInstanceId: String
    let generation: UInt64
    let expiresAt: Date
  }

  enum Rejection: Error, Equatable {
    case staleIdentity, wrongNetwork, expired, replay, invalidRoute, duplicateRoute
  }

  static func validate(_ pin: Pin, identity: Identity, activeHubNetworkId: String, existing: Pin?, now: Date = Date()) throws {
    guard pin.tunnelInstanceId == identity.tunnelInstanceId,
          pin.generation == identity.generation else {
      throw Rejection.staleIdentity
    }
    guard pin.hubNetworkId == activeHubNetworkId else {
      throw Rejection.wrongNetwork
    }
    guard pin.expiresAt > now else { throw Rejection.expired }
    guard existing == nil || existing == pin else { throw Rejection.replay }
  }

  static func validateHostRoutes(overlayAddresses: [String], hubProBootstrapAddresses: [String]) throws -> [String] {
    guard !overlayAddresses.isEmpty, !hubProBootstrapAddresses.isEmpty else {
      throw Rejection.invalidRoute
    }
    let routes = overlayAddresses + hubProBootstrapAddresses
    guard routes.allSatisfy(isOverlayHostRoute) else {
      throw Rejection.invalidRoute
    }
    guard Set(routes).count == routes.count else {
      throw Rejection.duplicateRoute
    }
    return routes
  }

  private static func isOverlayHostRoute(_ route: String) -> Bool {
    let pieces = route.split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 2, let prefix = Int(pieces[1]) else { return false }
    let address = String(pieces[0])
    if let ipv4 = IPv4Address(address) {
      let bytes = Array(ipv4.rawValue)
      return prefix == 32 && bytes[0] == 100 && (bytes[1] & 0b1110_0000) == 96
    }
    if let ipv6 = IPv6Address(address) {
      let bytes = Array(ipv6.rawValue)
      return prefix == 128 && bytes.starts(with: [0xfd, 0x48, 0x55, 0x42, 0x4e, 0x45])
    }
    return false
  }
}
