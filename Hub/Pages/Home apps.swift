//
//  Home apps.swift
//  Hub
//
//  Service apps on Home: icons, widgets at the size the user picks, and the ones the user hid.
//

import SwiftUI
import HubUI
import HubService

/// What the user chose for the apps of each hub: hidden apps and how each widget shows. Kept in user defaults,
/// per hub address and app path, so it survives the app going offline and coming back.
@MainActor
@Observable
final class HomeApps {
  static let main = HomeApps()
  /// A widget at one of its sizes, or the app's plain icon
  enum Tile: Codable, Hashable {
    case widget(WidgetSize)
    case icon
  }
  struct Layout: Codable, Hashable {
    var hidden: Set<String> = []
    var tiles: [String: Tile] = [:]
  }
  private(set) var layouts: [String: Layout]
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let key: String
  init(defaults: UserDefaults = .standard, key: String = "home.apps.v1") {
    self.defaults = defaults
    self.key = key
    layouts = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Layout].self, from: $0) } ?? [:]
  }
  func layout(_ hub: Hub.ID) -> Layout {
    layouts[hub.absoluteString] ?? Layout()
  }
  func isHidden(_ app: AppHeader, in hub: Hub.ID) -> Bool {
    layout(hub).hidden.contains(app.path)
  }
  func setHidden(_ hidden: Bool, _ app: AppHeader, in hub: Hub.ID) {
    update(hub) {
      if hidden {
        $0.hidden.insert(app.path)
      } else {
        $0.hidden.remove(app.path)
      }
    }
  }
  /// The saved tile when the app still supports it, else the widget's default size, else an icon
  func tile(of app: AppHeader, in hub: Hub.ID) -> Tile {
    guard let widget = app.widget else { return .icon }
    switch layout(hub).tiles[app.path] {
    case .icon: return .icon
    case .widget(let size) where widget.sizes.contains(size): return .widget(size)
    default: return .widget(widget.defaultSize)
    }
  }
  func setTile(_ tile: Tile, _ app: AppHeader, in hub: Hub.ID) {
    update(hub) { $0.tiles[app.path] = tile }
  }
  private func update(_ hub: Hub.ID, _ change: (inout Layout) -> Void) {
    var layout = layout(hub)
    change(&layout)
    layouts[hub.absoluteString] = layout
    if let data = try? JSONEncoder().encode(layouts) {
      defaults.set(data, forKey: key)
    }
  }
}

extension WidgetSize {
  /// One widget unit is a 2x2 block of Home's grid, the size of the Services tile
  var gridPreset: HomeGridLayout.PositionPreset {
    switch self {
    case .x11: .x22
    case .x12: .x24
    case .x21: .x42
    case .x22: .x44
    }
  }
  var title: LocalizedStringKey {
    switch self {
    case .x11: "Small"
    case .x12: "Tall"
    case .x21: "Wide"
    case .x22: "Large"
    }
  }
  var icon: String {
    switch self {
    case .x11: "square"
    case .x12: "rectangle.portrait"
    case .x21: "rectangle"
    case .x22: "square.grid.2x2"
    }
  }
}

extension HomeView {
  /// A service app on Home: a widget or an icon, with a menu to resize or hide it
  struct AppTile: View {
    let hub: Hub
    let app: AppHeader
    @State private var apps = HomeApps.main
    var body: some View {
      let tile = apps.tile(of: app, in: hub.id)
      switch tile {
      case .widget(let size):
        NavigationLink(value: HubAppLink(hub: hub.id, app: app)) {
          HubWidgetView(header: app, size: size)
            .blockBackground()
            .overlay(alignment: .topTrailing) {
              if !app.isOnline {
                Text("Offline").badgeStyle().padding(4)
              }
            }
            .bottomLabel { Text(app.name) }
        }.buttonStyle(.environment)
          .contextMenu { menu(tile) }
          .gridSize(size.gridPreset)
      case .icon:
        NavigationLink(value: HubAppLink(hub: hub.id, app: app)) {
          Label {
            Text(app.name)
          } icon: {
            if let icon = app.icon {
              Image(systemName: icon)
            } else if app.web != nil {
              Image(systemName: "globe")
            } else {
              Text(String(app.name.first ?? "A"))
            }
          }
        }.iconBadge(app.isOnline ? nil : "Offline")
          .labelStyle(.appIcon).buttonStyle(.environment)
          .contextMenu { menu(tile) }
      }
    }
    @ViewBuilder
    func menu(_ tile: HomeApps.Tile) -> some View {
      if let widget = app.widget {
        Picker("Size", selection: Binding { tile } set: { new in
          withAnimation(.home) { apps.setTile(new, app, in: hub.id) }
        }) {
          ForEach(widget.sizes, id: \.self) { size in
            Label(size.title, systemImage: size.icon).tag(HomeApps.Tile.widget(size))
          }
          Label("Icon", systemImage: "app").tag(HomeApps.Tile.icon)
        }.pickerStyle(.inline)
      }
      Button("Hide from Home", systemImage: "eye.slash") {
        withAnimation(.home) { apps.setHidden(true, app, in: hub.id) }
      }
    }
  }
  /// The hub's hidden apps, to show them again
  struct HiddenAppsTile: View {
    let hub: Hub
    let hidden: [AppHeader]
    @State private var apps = HomeApps.main
    var body: some View {
      Menu {
        Section("Hidden from Home") {
          ForEach(hidden) { app in
            Button(app.name, systemImage: app.icon ?? (app.widget != nil ? "square.grid.2x2" : "app")) {
              withAnimation(.home) { apps.setHidden(false, app, in: hub.id) }
            }
          }
        }
        if hidden.count > 1 {
          Button("Show All", systemImage: "eye") {
            withAnimation(.home) {
              hidden.forEach { apps.setHidden(false, $0, in: hub.id) }
            }
          }
        }
      } label: {
        Label("Hidden", systemImage: "eye.slash")
      }.iconBadge(hidden.count)
        .labelStyle(.appIcon).buttonStyle(.environment)
        .menuIndicator(.hidden)
    }
  }
}
