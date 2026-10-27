//
//  HomeAppsTests.swift
//  Tests
//

import XCTest
import HubService
@testable import Hub

@MainActor
final class HomeAppsTests: XCTestCase {
  let hub = URL(string: "ws://localhost:1997")!
  let other = URL(string: "ws://localhost:1998")!
  let users = AppHeader(type: .app, name: "Users", path: "pulse/users", widget: .init(sizes: [.x21, .x11]))
  let weather = AppHeader(type: .app, name: "Weather", path: "weather/ui")

  func defaults() -> UserDefaults {
    let name = "HomeAppsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return defaults
  }

  func testHiddenAppsPersistPerHub() {
    let defaults = defaults()
    let apps = HomeApps(defaults: defaults)
    apps.setHidden(true, weather, in: hub)
    XCTAssertTrue(apps.isHidden(weather, in: hub))
    XCTAssertFalse(apps.isHidden(weather, in: other))
    let reloaded = HomeApps(defaults: defaults)
    XCTAssertTrue(reloaded.isHidden(weather, in: hub))
    reloaded.setHidden(false, weather, in: hub)
    XCTAssertFalse(HomeApps(defaults: defaults).isHidden(weather, in: hub))
  }

  func testWidgetTiles() {
    let apps = HomeApps(defaults: defaults())
    XCTAssertEqual(apps.tile(of: weather, in: hub), .icon)
    // The first declared size is the default
    XCTAssertEqual(apps.tile(of: users, in: hub), .widget(.x21))
    apps.setTile(.widget(.x11), users, in: hub)
    XCTAssertEqual(apps.tile(of: users, in: hub), .widget(.x11))
    XCTAssertEqual(apps.tile(of: users, in: other), .widget(.x21))
    apps.setTile(.icon, users, in: hub)
    XCTAssertEqual(apps.tile(of: users, in: hub), .icon)
    // A size the app stopped supporting falls back to its default
    apps.setTile(.widget(.x22), users, in: hub)
    XCTAssertEqual(apps.tile(of: users, in: hub), .widget(.x21))
  }
}
