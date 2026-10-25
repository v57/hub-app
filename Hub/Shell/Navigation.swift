//
//  Navigation.swift
//  Hub
//
//  Where the window is: All Hubs, one of a hub's pages, or one of this device's features.
//

#if canImport(ComponentKit)
import SwiftUI
import HubService
import ComponentKit

/// A page of one hub, in the sidebar's order: the hub's own card, then Access, then Hub Network.
enum HubPage: String, Hashable, CaseIterable, Sendable {
  case overview, services, apps, files, launcher
  case devices, requests, connections, permissions, lockdown
  case network

  var title: String {
    switch self {
    case .overview: "Overview"
    case .services: "Services"
    case .apps: "Apps"
    case .files: "Files"
    case .launcher: "Launcher"
    case .devices: "Devices"
    case .requests: "Requests"
    case .connections: "Connections"
    case .permissions: "Permissions"
    case .lockdown: "Lockdown"
    case .network: "Network"
    }
  }
  var systemImage: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .services: "hexagon"
    case .apps: "square.grid.3x3"
    case .files: "folder"
    case .launcher: "apple.terminal"
    case .devices: "macbook.and.iphone"
    case .requests: "clock"
    case .connections: "wifi"
    case .permissions: "lock"
    case .lockdown: "lock.shield"
    case .network: "network"
    }
  }
  /// The sidebar card the page is in
  var group: Group {
    switch self {
    case .overview, .services, .apps, .files, .launcher: .hub
    case .devices, .requests, .connections, .permissions, .lockdown: .access
    case .network: .network
    }
  }
  enum Group: Hashable, Sendable {
    case hub, access, network
  }
}

/// What this device offers without a hub (the sidebar's This Mac card)
enum DevicePage: String, Hashable, Sendable {
  case localHub, sharedServices, farm, settings
}

/// The window's selection: the sidebar selects it, and pages open each other through it.
enum Route: Hashable, Sendable {
  case allHubs
  case hub(Hub.ID, HubPage)
  /// iPhone: a hub's pages as a list, which push
  case hubHome(Hub.ID)
  /// A service app, opened under its hub's Apps
  case app(Hub.ID, path: String)
  case device(DevicePage)

  var hubID: Hub.ID? {
    switch self {
    case .hub(let id, _), .app(let id, _), .hubHome(let id): id
    case .allHubs, .device: nil
    }
  }
  var hubPage: HubPage? {
    switch self {
    case .hub(_, let page): page
    case .app: .apps
    case .allHubs, .device, .hubHome: nil
    }
  }
}

/// The window's route and how hubs are listed, kept across launches.
@MainActor @Observable
final class Navigator {
  static let main = Navigator()
  var route: Route? = .allHubs {
    didSet {
      // A hub's row opens its Overview beside the sidebar; on iPhone it pushes the list of its pages
      if case .hubHome(let id) = route, KitDevice.name != "iPhone" {
        route = .hub(id, .overview)
      }
      guard let id = route?.hubID, id != oldValue?.hubID else { return }
      Hubs.main.select(id)
      opened[id.absoluteString] = Date().timeIntervalSince1970
      UserDefaults.standard.set(opened, forKey: "hubs.opened")
    }
  }
  /// The last hub opened: its pages stay in the sidebar while All Hubs is open
  var openHub: Hub? {
    guard let id = route?.hubID else { return nil }
    return Hubs.main.list.first { $0.id == id }
  }
  var sort: HubSort {
    didSet { UserDefaults.standard.set(sort.rawValue, forKey: "hubs.sort") }
  }
  /// When each hub was last opened
  private var opened: [String: Double]
  /// The same as of launch, for the Recent sort: opening a hub doesn't move its row under the pointer
  private let openedAtLaunch: [String: Double]

  init() {
    let opened = UserDefaults.standard.dictionary(forKey: "hubs.opened") as? [String: Double] ?? [:]
    self.opened = opened
    openedAtLaunch = opened
    sort = UserDefaults.standard.string(forKey: "hubs.sort").flatMap(HubSort.init) ?? .recent
    if let selected = Hubs.main.selectedHub {
      route = .hub(selected.id, .overview)
    }
#if DEBUG
    // `--open Home/devices`, `--open all`, `--open Home/app/pulse`: a page at launch, for captures
    if let index = CommandLine.arguments.firstIndex(of: "--open"), index + 1 < CommandLine.arguments.count {
      let parts = CommandLine.arguments[index + 1].split(separator: "/").map(String.init)
      if let hub = Hubs.main.list.first(where: { $0.settings.name == parts[0] }) {
        if parts.count > 2, parts[1] == "app" {
          route = .app(hub.id, path: parts[2...].joined(separator: "/"))
        } else {
          route = .hub(hub.id, parts.count > 1 ? HubPage(rawValue: parts[1]) ?? .overview : .overview)
        }
      } else if let page = DevicePage(rawValue: parts[0]) {
        route = .device(page)
      } else {
        route = .allHubs
      }
    }
#endif
  }
  /// Reset Data: no hub opened before, sorted as it comes
  func reset() {
    opened = [:]
    sort = .recent
  }
  func open(_ hub: Hub, _ page: HubPage = .overview) {
    route = .hub(hub.id, page)
  }
  func lastOpened(_ hub: Hub) -> Double {
    openedAtLaunch[hub.id.absoluteString] ?? 0
  }
  /// Hubs in the sidebar's order: the ones that answer first, then by the chosen sort
  func sorted(_ hubs: [Hub]) -> [Hub] {
    switch sort {
    case .recent:
      hubs.enumerated().sorted {
        let a = lastOpened($0.element), b = lastOpened($1.element)
        return a != b ? a > b : $0.offset < $1.offset
      }.map(\.element)
    case .name:
      hubs.sorted { $0.settings.name.localizedStandardCompare($1.settings.name) == .orderedAscending }
    }
  }
}

enum HubSort: String, CaseIterable, Hashable, Sendable {
  case recent, name
  var title: String {
    switch self {
    case .recent: "Recent"
    case .name: "Name"
    }
  }
}
#endif
