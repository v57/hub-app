//
//  HomeApps.swift
//  Hub
//
//  Which of a hub's service apps the user hid and the size each widget shows at.
//

import Foundation
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
  /// Reset Data: every hub's Home as it comes
  func reset() {
    layouts = [:]
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
