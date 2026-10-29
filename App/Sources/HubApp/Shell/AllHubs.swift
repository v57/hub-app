//
//  AllHubs.swift
//  Hub
//
//  Every hub on one screen: one card per hub, as tall as what it holds, packed into columns that the window's width
//  adds to. A busy hub spans two columns; one that can't be reached shrinks to its header.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
import HubUI

struct AllHubsView: View {
  @State private var hubs = Hubs.main
  @State private var navigator = Navigator.main
  @State private var search = ""
  @Environment(ShellModel.self) private var shell
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if hubs.list.isEmpty {
      // Nothing set up yet: the welcome is the main screen
      HubWelcome()
        .kitPane(.content)
        .kitToolbar("Hub", meta: [], systemImage: "hexagon") { }
    } else {
      grid
    }
  }

  private var grid: some View {
    let listed = navigator.sorted(hubs.list).sorted { ($0.reach.isHidden ? 1 : 0) < ($1.reach.isHidden ? 1 : 0) }
    return ScrollView {
      KitPackedGrid(unit: idiom == .phone ? 280 : 320) {
        ForEach(listed) { hub in
          HubCard(hub: hub, search: search).hub(hub)
        }
      }
      .padding(KitMetrics.gutter)
      .padding(.bottom, 24)
      .animation(.kit, value: hubs.list.map(\.reach))
    }
    .kitPane(.content)
    .kitToolbar("All Hubs", meta: meta, systemImage: "square.grid.2x2.fill") {
      if idiom != .phone {
        KitSearchField(text: $search, prompt: "Hubs, apps, devices").frame(width: 220)
      }
      ToolGroup {
        Button("Connect", systemImage: "plus") { shell.sheet = .connect }
      }
    }
  }

  private var meta: [String] {
    let online = hubs.list.filter(\.isConnected).count
    let requests = hubs.list.reduce(0) { $0 + ($1.state.statusBadges.value.security ?? 0) + $1.state.pendingDevices.value.count }
    return [
      hubs.list.count == 1 ? "1 hub" : "\(hubs.list.count) hubs", "\(online) online",
      requests == 0 ? "" : requests == 1 ? "1 request" : "\(requests) requests",
    ]
  }
}

/// Hub's welcome, the main screen until a hub is set up: connect to one (by address or invitation) or run one here,
/// with the hubs this app knows as its list
struct HubWelcome: View {
  @State private var hubs = Hubs.main
  @Environment(ShellModel.self) private var shell

  var body: some View {
    KitWelcome(
      emptyTitle: "No Hub Yet",
      emptyMessage: "Hub connects to hubs you run: hub-server on a Mac, a home server or a VPS, or this \(KitDevice.nameInSentence) itself. Nothing is contacted until you connect."
    ) {
#if os(macOS) && canImport(HubServer)
      WelcomeAction("Use This Mac’s Internet Anywhere…", detail: "Browse through it from your phone or laptop when you’re away", systemImage: "globe") {
        shell.sheet = .internetSetup
      }
#elseif os(iOS)
      WelcomeAction("Browse Through My Own Internet", detail: "Use your home Mac’s or server’s connection when you’re away", systemImage: "globe") {
        shell.sheet = .browseOwnInternet
      }
#endif
      WelcomeAction("Connect to a Hub…", detail: "Its address and pairing code, or an invitation", systemImage: "plus") {
        shell.sheet = .connect
      }
#if canImport(HubServer)
      WelcomeAction("Run a Hub on This \(KitDevice.name)", detail: "This app is the hub; your devices pair with it", systemImage: "server.rack") {
        Navigator.main.route = .device(.localHub)
      }
#endif
    } recents: {
      ForEach(hubs.list) { hub in
        RecentItem(hub.settings.name, subtitle: hub.settings.address.absoluteString, systemImage: "hexagon") {
          Navigator.main.open(hub)
        }
      }
    }
    .listTitle("Your Hubs")
  }
}

// MARK: - A hub's card

/// One hub: its header (state, counts, what needs you), its launcher apps, its widgets as wells, then its pages and
/// apps as tiles.
struct HubCard: View {
  let hub: Hub
  var search: String = ""
  var facts = HubFacts()
  @HubState(\.launcherInfo) private var launcher
  @State private var homeApps = HomeApps.main
  @State private var showsMenu = false
  @State private var width: CGFloat = 0

  private var widgets: [(AppHeader, WidgetSize)] {
    facts.apps.compactMap { app in
      guard !homeApps.isHidden(app, in: hub.id), case .widget(let size) = homeApps.tile(of: app, in: hub.id) else { return nil }
      return (app, size)
    }
  }
  private var tiles: [HubTileItem] {
    // The pages used most, then the apps; the rest are a click away on the hub's sidebar cards
    let pages = HubPage.tilePages.filter { page in
      hub.canOpen(page) && (page != .requests || facts.requests > 0)
    }
    .map(HubTileItem.page)
    let apps = facts.apps.filter { app in
      !homeApps.isHidden(app, in: hub.id) && homeApps.tile(of: app, in: hub.id) == .icon
    }.map(HubTileItem.app)
    let all = pages + apps
    guard !search.isEmpty else { return all }
    return all.filter { $0.title.localizedCaseInsensitiveContains(search) }
  }
  /// Spans two columns when it holds more than a column shows well
  private var span: Int {
    guard hub.reach == .online else { return 1 }
    return !widgets.isEmpty || !launcher.apps.isEmpty || tiles.count > 9 ? 2 : 1
  }

  var body: some View {
    if !search.isEmpty && !hub.settings.name.localizedCaseInsensitiveContains(search) && tiles.isEmpty {
      EmptyView()
    } else {
      card.kitGridSpan(span)
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { Navigator.main.open(hub) } label: {
        RichHeader(Text(hub.settings.name)) {
          HubTile(hub: hub, size: 28)
        } meta: {
          MetaLine([facts.summary, hub.settings.address.host() ?? ""])
        } accessory: {
          accessory
        }
        .padding(.horizontal, 6).padding(.top, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if hub.reach == .online {
        if !launcher.apps.isEmpty && search.isEmpty {
          LauncherStrip(apps: Array(launcher.apps.prefix(span == 2 ? 3 : 2)))
        }
        if !widgets.isEmpty && search.isEmpty {
          WidgetWells(hub: hub, widgets: widgets)
        }
        TileGrid(hub: hub, items: tiles)
      }
    }
    .padding(.bottom, hub.reach == .online ? 6 : 4)
    .padding(KitMetrics.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .kitSurface(.card, cornerRadius: 16)
    .kitContextMenu { HubMenu(hub: hub) }
  }

  @ViewBuilder
  private var accessory: some View {
    switch hub.reach {
    case .online:
      if facts.requests > 0 {
        Button { Navigator.main.open(hub, facts.pendingDevices.isEmpty ? .requests : .devices) } label: {
          Chip(facts.requests == 1 ? "1 request" : "\(facts.requests) requests", hue: .orange).controlSize(.small)
        }
        .buttonStyle(.plain)
      } else {
        Button("More", systemImage: "ellipsis") { showsMenu = true }
          .buttonStyle(.kitIcon)
          .kitMenu(isPresented: $showsMenu) { HubMenu(hub: hub) }
      }
    case .connecting:
      Image(systemName: "wifi").foregroundStyle(Hue.orange.text)
        .symbolEffect(.variableColor.iterative.dimInactiveLayers.reversing, options: .repeating)
        .padding(6).background(Hue.orange.soft(), in: .rect(cornerRadius: KitMetrics.radiusSmall))
    case .offline, .refused:
      Button("More", systemImage: "ellipsis") { showsMenu = true }
        .buttonStyle(.kitIcon)
        .kitMenu(isPresented: $showsMenu) { HubMenu(hub: hub) }
    }
  }
}

/// A page or a service app shown as a tile on a hub's card
enum HubTileItem: Identifiable {
  case page(HubPage)
  case app(AppHeader)
  var id: String {
    switch self {
    case .page(let page): "page/\(page.rawValue)"
    case .app(let app): "app/\(app.path)"
    }
  }
  var title: String {
    switch self {
    case .page(let page): page.title
    case .app(let app): app.name
    }
  }
}

/// Tiles in rows of the card's width; past two rows, the last one is More (which opens the hub)
private struct TileGrid: View {
  let hub: Hub
  let items: [HubTileItem]
  @State private var width: CGFloat = 0
  var facts = HubFacts()

  var body: some View {
    let perRow = max(1, Int((width + 2) / 64))
    let limit = perRow * 2
    let shown = items.count > limit ? Array(items.prefix(limit - 1)) : items
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 2)], spacing: 6) {
      ForEach(shown) { item in
        tile(item).buttonStyle(.plain)
      }
      if items.count > limit {
        Button { Navigator.main.open(hub) } label: {
          Label {
            Text("More")
          } icon: {
            Text("+\(items.count - shown.count)").kitFont(.caption).fontWeight(.semibold)
              .foregroundStyle(.kitSecondary)
              .frame(width: 36, height: 36)
              .background(.kitFill, in: .rect(cornerRadius: 9))
          }
        }
        .labelStyle(HubTileLabelStyle())
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 4)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
  }

  @ViewBuilder
  private func tile(_ item: HubTileItem) -> some View {
    switch item {
    case .page(let page):
      Button { Navigator.main.open(hub, page) } label: {
        Label {
          Text(page.title)
        } icon: {
          Tile(systemImage: page.systemImage, hue: page.hue, size: 36)
        }
      }
      .labelStyle(HubTileLabelStyle(badge: badge(page)))
    case .app(let app):
      Button { Navigator.main.route = .app(hub.id, path: app.path) } label: {
        Label {
          Text(app.name)
        } icon: {
          AppTileIcon(app: app, size: 36)
        }
      }
      .labelStyle(HubTileLabelStyle(badge: app.isOnline ? nil : "Offline"))
    }
  }

  private func badge(_ page: HubPage) -> String? {
    switch page {
    case .devices: facts.pendingDevices.isEmpty ? nil : "\(facts.pendingDevices.count)"
    case .requests: (facts.badges.security ?? 0) > 0 ? "\(facts.badges.security ?? 0)" : nil
    default: nil
    }
  }
}

/// A tile with its name under it, lit by the hover effect; a red badge on its corner
struct HubTileLabelStyle: LabelStyle {
  var badge: String?
  func makeBody(configuration: Configuration) -> some View {
    VStack(spacing: 4) {
      configuration.icon
        .kitHoverEffect(in: RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .topTrailing) {
          if let badge {
            Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
              .lineLimit(1).fixedSize()
              .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
              .background(Hue.red.fill, in: .capsule)
              .offset(x: 6, y: -5)
          }
        }
      configuration.title
        .kitFont(.caption).lineLimit(1).truncationMode(.tail)
        .foregroundStyle(.kitLabel)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

/// A service app's icon: its symbol, a globe for a web app, or its first letter
struct AppTileIcon: View {
  let app: AppHeader
  var size: CGFloat = 24
  var body: some View {
    let hue = StableHue.pick(app.name)
    if let icon = app.icon {
      Tile(systemImage: icon, hue: hue, size: size)
    } else if app.web != nil {
      Tile(systemImage: "globe", hue: hue, size: size)
    } else {
      Tile(letters: String(app.name.first ?? "A"), hue: hue, size: size)
    }
  }
}

/// The hub's widgets, each a well in the card: two units for wide ones
private struct WidgetWells: View {
  let hub: Hub
  let widgets: [(AppHeader, WidgetSize)]

  var body: some View {
    KitPackedGrid(unit: 150, spacing: 6) {
      ForEach(widgets, id: \.0.path) { app, size in
        Button { Navigator.main.route = .app(hub.id, path: app.path) } label: {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
              Text(app.name).kitFont(.caption).fontWeight(.semibold).foregroundStyle(.kitLabel)
              Spacer(minLength: 0)
              if !app.isOnline { Chip("Offline", hue: .gray).controlSize(.small) }
            }
            HubWidgetView(header: app, size: size)
              .frame(height: size.wellHeight)
          }
          .padding(.horizontal, 10).padding(.vertical, 9)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.kitFill, in: .rect(cornerRadius: 11))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kitGridSpan(size.columns)
      }
    }
    .padding(.horizontal, 4)
  }
}

extension WidgetSize {
  /// Columns of a hub card's widget grid
  var columns: Int {
    switch self {
    case .x11, .x12: 1
    case .x21, .x22: 2
    }
  }
  /// The widget's body height in a well
  var wellHeight: CGFloat {
    switch self {
    case .x11, .x21: 80
    case .x12, .x22: 190
    }
  }
}

/// The hub's launcher apps, running or stopped, with their play and pause
private struct LauncherStrip: View {
  let apps: [Hub.Launcher.AppInfo]
  @Environment(Hub.self) private var hub
  @HubState(\.launcherStatus) private var statuses

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 6)], spacing: 6) {
      ForEach(apps) { app in
        let status = statuses.apps[app.name]
        let running = (status?.processes?.count ?? 0) > 0
        HStack(spacing: 8) {
          Tile(systemImage: "apple.terminal", hue: .gray, size: 24)
          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
              Text(app.id).kitFont(.caption).fontWeight(.semibold).lineLimit(1)
              if app.updateAvailable { Chip("Update", hue: .red, style: .solid).controlSize(.small) }
            }
            Text(app.statusLine(status)).kitFont(.caption).foregroundStyle(.kitSecondary).lineLimit(1)
              .monospacedDigit()
          }
          Spacer(minLength: 0)
          if !app.isHub {
            AsyncButton(running ? "Stop" : "Start", systemImage: running ? "pause.fill" : "play.fill") {
              if running {
                try await hub.launcher.app(id: app.id).stop()
              } else {
                try await hub.launcher.app(id: app.id).start()
              }
            }
            .buttonStyle(.kitRound).controlSize(.small)
          }
        }
        .padding(.vertical, 7).padding(.leading, 10).padding(.trailing, 6)
        .background(.kitFill, in: .rect(cornerRadius: 11))
      }
    }
    .padding(.horizontal, 4)
  }
}

extension Hub.Launcher.AppInfo {
  /// hub-server is "Hub" in the store; older launchers list "Hub Pro" and "Hub Lite"
  var isHub: Bool { id == "Hub" || id == "Hub Pro" || id == "Hub Lite" }
  /// "4% · 143 MB · 23h", "Stopped", "Updating"
  func statusLine(_ status: Hub.Launcher.AppStatus?) -> String {
    if status?.updating == true { return "Updating" }
    guard let status, let processes = status.processes, !processes.isEmpty else {
      return active ? "Not running" : "Stopped"
    }
    var parts = [String]()
    if let cpu = status.totalCpu ?? processes.compactMap(\.cpu).reduce(nil, { ($0 ?? 0) + $1 }) {
      parts.append("\(Int(cpu))%")
    }
    if let memory = status.totalMemory ?? processes.compactMap(\.memory).reduce(nil, { ($0 ?? 0) + $1 }) {
      parts.append(memory >= 1024 ? String(format: "%.1f GB", memory / 1024) : "\(Int(memory)) MB")
    }
    if processes.count > 1 { parts.append("\(processes.count) instances") }
    if let started = status.started { parts.append(started.shortRelative) }
    return parts.joined(separator: " · ")
  }
}

extension HubPage {
  /// The pages a hub's card shows as tiles
  static let tilePages: [HubPage] = [.services, .devices, .requests, .connections, .launcher, .files]
  /// The page's tile colour on a hub's card and in its toolbar
  var hue: Hue {
    switch self {
    case .overview: .accent
    case .services: .blue
    case .apps: .purple
    case .files: .blue
    case .launcher: .gray
    case .devices: .gray
    case .requests: .orange
    case .connections: .teal
    case .permissions: .orange
    case .lockdown: .red
    case .network: .teal
    }
  }
}
#endif
