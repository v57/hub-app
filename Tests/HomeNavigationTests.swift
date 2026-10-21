//
//  HomeNavigationTests.swift
//  Tests
//

import XCTest
import HubService
@testable import Hub

@MainActor
final class HomeNavigationTests: XCTestCase {
  /// The home stack used one hub's destination for every app link, so apps opened on a hub that wasn't connected
  func testAppLinkOpensOnItsOwnHub() {
    let first = Hub(settings: .init(name: "First", address: URL(string: "ws://127.0.0.1:9")!))
    let second = Hub(settings: .init(name: "Second", address: URL(string: "ws://127.0.0.1:10")!))
    defer {
      first.client.stop()
      second.client.stop()
    }
    let hubs = [first, second]
    let weather = AppHeader(type: .app, name: "Weather", path: "weather/ui")
    let link = HubAppLink(hub: second.id, app: weather)
    XCTAssertTrue(link.hub(in: hubs) === second)
    XCTAssertNotEqual(link, HubAppLink(hub: first.id, app: weather))
    XCTAssertNil(HubAppLink(hub: URL(string: "ws://127.0.0.1:11")!, app: weather).hub(in: hubs))
  }
}
