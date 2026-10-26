import Foundation
import XCTest

@testable import InviterNode

/// When a phone that falls back sends its traffic through the gateway, and when through its own network
final class GatewayPathTests: XCTestCase {
  let start = Date(timeIntervalSince1970: 1_800_000_000)

  func testItsOwnNetworkUntilTheGatewayAnswers() {
    var path = GatewayPath()
    XCTAssertNil(path.update(receivedBytes: 0, now: start))
    XCTAssertNil(path.update(receivedBytes: 0, now: start + 20))
    XCTAssertEqual(path.update(receivedBytes: 148, now: start + 25), true)
    XCTAssertTrue(path.isReachable)
  }

  func testKeepalivesKeepTheGatewayAndSilenceFallsBack() {
    var path = GatewayPath()
    XCTAssertEqual(path.update(receivedBytes: 148, now: start), true)
    // A keepalive every 25 s
    XCTAssertNil(path.update(receivedBytes: 180, now: start + 25))
    XCTAssertNil(path.update(receivedBytes: 212, now: start + 50))
    XCTAssertNil(path.update(receivedBytes: 212, now: start + 85))
    XCTAssertEqual(path.update(receivedBytes: 212, now: start + 90), false, "nothing for 40 s")
    XCTAssertNil(path.update(receivedBytes: 212, now: start + 200))
    XCTAssertEqual(path.update(receivedBytes: 300, now: start + 205), true, "back once it answers")
  }

  func testAPeerConfiguredAnewCountsFromZero() {
    var path = GatewayPath()
    XCTAssertEqual(path.update(receivedBytes: 5_000, now: start), true)
    XCTAssertNil(path.update(receivedBytes: 92, now: start + 30))
    XCTAssertNil(path.update(receivedBytes: 92, now: start + 60))
    XCTAssertEqual(path.update(receivedBytes: 92, now: start + 70), false)
  }

  func testAWatchStartedOverWorkingRoutesGivesTheGatewayTime() {
    var path = GatewayPath(reachable: true, now: start)
    XCTAssertNil(path.update(receivedBytes: 0, now: start + 30))
    XCTAssertEqual(path.update(receivedBytes: 0, now: start + 40), false)
  }
}
