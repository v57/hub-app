//
//  NetworkShareTests.swift
//  Tests
//
//  The name a shared app carries to other devices, how they show shares, and the bounded wait for the hub's answer.
//

import XCTest
@testable import HubApp

@MainActor
final class NetworkShareTests: XCTestCase {
  func testShareNameCarriesTheAppsName() {
    XCTAssertEqual(HubNet.shareName(protocol: "tcp", port: 18080, label: "ZZ 3b app"), "tcp-18080:ZZ 3b app")
    XCTAssertEqual(HubNet.shareName(protocol: "udp", port: 51820, label: nil), "udp-51820")
    XCTAssertEqual(HubNet.shareName(protocol: "tcp", port: 8096, label: "  "), "tcp-8096")
    let long = HubNet.shareName(protocol: "tcp", port: 8096, label: String(repeating: "ä", count: 200))
    XCTAssertLessThanOrEqual(long.utf8.count, 128)
    XCTAssertTrue(long.hasPrefix("tcp-8096:ä"))
  }

  func testLabelAndPortOfAShareName() {
    XCTAssertEqual(HubNet.label(ofShare: "tcp-18080:ZZ 3b app"), "ZZ 3b app")
    XCTAssertEqual(HubNet.label(ofShare: "udp-5000:Game: Server"), "Game: Server")
    XCTAssertNil(HubNet.label(ofShare: "tcp-18080"))
    XCTAssertNil(HubNet.label(ofShare: "Camera: Kitchen"))
    XCTAssertNil(HubNet.label(ofShare: "s3"))
    XCTAssertTrue(HubNet.isShare("tcp-18080", protocol: "tcp", port: 18080))
    XCTAssertTrue(HubNet.isShare("tcp-18080:ZZ", protocol: "tcp", port: 18080))
    XCTAssertFalse(HubNet.isShare("tcp-180800", protocol: "tcp", port: 18080))
    XCTAssertFalse(HubNet.isShare("udp-18080", protocol: "tcp", port: 18080))
  }

  func testOtherDevicesSharesByName() {
    let names = NetworkAppNames.main
    XCTAssertEqual(names.name(share: "tcp-18080:ZZ 3b app", port: 18080), "ZZ 3b app")
    XCTAssertEqual(names.name(share: "s3", port: 62855), "Storage")
    XCTAssertEqual(names.name(share: "Camera: Kitchen", port: 45678), "Camera: Kitchen")
    XCTAssertEqual(names.name(share: "tcp-62781", port: 62781), names.name(port: 62781))
    XCTAssertEqual(names.name(share: "port-8080-tcp", port: 8080), names.name(port: 8080))
  }

  private struct TimedOut: Error {}

  func testBoundedAnswersInTime() async throws {
    let value = try await bounded(.seconds(2), timedOut: { TimedOut() }) { @MainActor in
      try await Task.sleep(for: .milliseconds(50))
      return 7
    }
    XCTAssertEqual(value, 7)
  }

  func testBoundedGivesUpOnASilentHub() async {
    let start = ContinuousClock.now
    do {
      _ = try await bounded(.milliseconds(200), timedOut: { TimedOut() }) { @MainActor () async throws -> Int in
        // A send to a hub that went away: never answers, and ignores cancellation
        try? await Task.sleep(for: .seconds(30))
        return 1
      }
      XCTFail("no timeout")
    } catch {
      XCTAssertTrue(error is TimedOut)
    }
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
  }

  func testBoundedStopsWhenCancelled() async {
    let task = Task { @MainActor in
      try await bounded(.seconds(30), timedOut: { TimedOut() }) { @MainActor () async throws -> Int in
        try? await Task.sleep(for: .seconds(30))
        return 1
      }
    }
    try? await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let start = ContinuousClock.now
    do {
      _ = try await task.value
      XCTFail("not cancelled")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
  }
}
