//
//  LocalHubTests.swift
//  Tests
//

#if canImport(HubServer)
import XCTest
@testable import HubApp

final class LocalHubTests: XCTestCase {
  func testAddressesAreListedOnceWiFiFirst() {
    let addresses = LocalHub.reachableAddresses([
      ("pdp_ip0", "192.0.0.6"), ("en0", "192.168.1.20"), ("pdp_ip1", "192.0.0.6"), ("bridge100", "172.20.10.1"),
      ("en2", "169.254.10.4"), ("en1", "192.168.1.20"),
    ])
    XCTAssertEqual(addresses, ["192.168.1.20", "172.20.10.1", "192.0.0.6"])
  }
}
#endif
