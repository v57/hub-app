import Foundation

/// Which routes each bootstrap peer keeps when several claim the same one.
///
/// An inviter-side joiner peer scopes the whole overlay (`100.96.0.0/11`, `fd48:5542:4e45::/48`) besides its own
/// bootstrap host routes, because the inviter learns the joiner's permanent overlay addresses only later (member
/// peers). WireGuard routes each address to one peer, so the newest bootstrap peer keeps a shared route and older
/// ones drop it, keeping only routes nobody newer claims. An older joiner has bound by then and is reachable through
/// its member routes.
enum BootstrapRouteClaims {
  /// - Parameters:
  ///   - peers: routes per peer id with the peer's install order (higher is newer)
  ///   - identity: what makes two routes the same
  static func resolve<Route>(
    _ peers: [String: (order: Int, routes: [Route])],
    identity: (Route) -> String
  ) -> [String: [Route]] {
    var claimed = Set<String>()
    var resolved: [String: [Route]] = [:]
    for (id, peer) in peers.sorted(by: { $0.value.order > $1.value.order }) {
      var routes: [Route] = []
      for route in peer.routes where claimed.insert(identity(route)).inserted {
        routes.append(route)
      }
      resolved[id] = routes
    }
    return resolved
  }
}
