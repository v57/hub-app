//
//  LocalHubTests.swift
//  Tests
//

#if canImport(HubServer)
import XCTest
import HubServer
@testable import HubApp

final class LocalHubTests: XCTestCase {
  func testAddressesAreListedOnceWiFiFirst() {
    let addresses = LocalHub.reachableAddresses([
      ("pdp_ip0", "192.0.0.6"), ("en0", "192.168.1.20"), ("pdp_ip1", "192.0.0.6"), ("bridge100", "172.20.10.1"),
      ("en2", "169.254.10.4"), ("en1", "192.168.1.20"),
    ])
    XCTAssertEqual(addresses, ["192.168.1.20", "172.20.10.1", "192.0.0.6"])
  }

  /// iOS takes the listener while Hub is suspended: once back in front, the hub starts again by itself
  func testRestartsWhenItStopsListeningInFront() {
    XCTAssertTrue(LocalHub.restarts(from: .running, to: .failed("ECONNABORTED"), isEnabled: true, isInBackground: false))
  }

  func testWaitsForResumeInTheBackground() {
    XCTAssertFalse(LocalHub.restarts(from: .running, to: .failed("ECONNABORTED"), isEnabled: true, isInBackground: true))
  }

  func testLeavesAHubThatFailedToStartOrWasTurnedOff() {
    // A port in use fails the start: starting again would fail the same way
    XCTAssertFalse(LocalHub.restarts(from: .starting, to: .failed("address in use"), isEnabled: true, isInBackground: false))
    XCTAssertFalse(LocalHub.restarts(from: .running, to: .failed("ECONNABORTED"), isEnabled: false, isInBackground: false))
    XCTAssertFalse(LocalHub.restarts(from: .running, to: .stopped, isEnabled: true, isInBackground: false))
  }
}
#endif
