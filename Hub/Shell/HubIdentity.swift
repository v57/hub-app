//
//  HubIdentity.swift
//  Hub
//
//  How a hub reads at a glance in the sidebar, on All Hubs and in a page's title: its letter tile, its state, what
//  it needs from you and the line under its name.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService

extension Hub {
  /// The hub's tile colour, stable for its name
  var hue: Hue {
    let hues: [Hue] = [.red, .indigo, .teal, .orange, .purple, .pink, .blue, .brown, .green]
    let sum = settings.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
    return hues[sum % hues.count]
  }
  var letter: String {
    settings.name.first.map { String($0).uppercased() } ?? "H"
  }
  /// Online, connecting, or unreachable for a while (behind the sidebar's Show More)
  var reach: Reach {
    if isConnected { return .online }
    if refusal != nil { return .refused }
    return isUnreachable ? .offline : .connecting
  }
  enum Reach: Hashable {
    case online, connecting, offline, refused
    var hue: Hue {
      switch self {
      case .online: .green
      case .connecting: .orange
      case .offline: .gray
      case .refused: .red
      }
    }
    var isHidden: Bool { self == .offline || self == .refused }
  }
}

/// A hub's letter in its colour
struct HubTile: View {
  let hub: Hub
  var size: CGFloat = 24
  var body: some View {
    Tile(letters: hub.letter, hue: hub.hue, size: size)
      .opacity(hub.reach.isHidden ? 0.5 : 1)
  }
}

/// What a hub has and needs, read from its live state: one per hub view, under `.hub(hub)`.
@MainActor
struct HubFacts: DynamicProperty {
  @Environment(Hub.self) var hub
  @HubState(\.statusBadges) var badges
  @HubState(\.pendingDevices) var pendingDevices
  @HubState(\.users) var users
  @HubState(\.devices) var devices

  init() {}

  /// Service requests and devices waiting for approval
  var requests: Int {
    (hub.require(permissions: "hub/host/pending") ? badges.security ?? 0 : 0)
      + (hub.require(permissions: "hub/device/approve") ? pendingDevices.count : 0)
  }
  /// The group this app's key is in ("Owner"), when the hub lists its connections
  var role: String? {
    guard let group = users.first(where: { $0.key == hub.key })?.group else { return nil }
    return group.hasSuffix("s") && group.count > 1 ? String(group.dropLast()).capitalized : group.capitalized
  }
  var services: Int { badges.services }
  var apps: [AppHeader] { badges.apps ?? [] }
  /// The line under the hub's name: role and services, or what keeps it away
  var summary: String {
    switch hub.reach {
    case .online:
      return [role, services == 1 ? "1 service" : "\(services) services"].compactMap { $0 }.joined(separator: " · ")
    case .connecting: return "Connecting…"
    case .offline: return "Offline"
    case .refused: return hub.refusal?.description ?? "Refused"
    }
  }
}
#endif
