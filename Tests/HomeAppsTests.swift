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

  func testWidgetUnitsAreTwoGridCells() {
    XCTAssertEqual(WidgetSize.x11.gridPreset.value, HomeGridLayout.GridSize(w: 2, h: 2))
    XCTAssertEqual(WidgetSize.x12.gridPreset.value, HomeGridLayout.GridSize(w: 2, h: 4))
    XCTAssertEqual(WidgetSize.x21.gridPreset.value, HomeGridLayout.GridSize(w: 4, h: 2))
    XCTAssertEqual(WidgetSize.x22.gridPreset.value, HomeGridLayout.GridSize(w: 4, h: 4))
  }

  /// The height counted rows from 64-bit word boundaries, one short when rows didn't line up with them
  func testGridHeightCountsTheLastRow() {
    var cache = HomeGridLayout.Cache()
    cache.width = 14
    cache[3, 7] = true // cell 101, in the second word
    XCTAssertEqual(cache.height, 8)
    var aligned = HomeGridLayout.Cache()
    aligned.width = 4
    aligned[3, 15] = true // cell 63, the last bit of the first word
    XCTAssertEqual(aligned.height, 16)
    XCTAssertEqual(HomeGridLayout.Cache().height, 0)
  }
}
