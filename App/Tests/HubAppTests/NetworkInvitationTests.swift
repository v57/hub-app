//
//  NetworkInvitationTests.swift
//  Tests
//
//  What the hub machine's net/invite holds for a member (H-034).
//

import CryptoKit
import Foundation
import HubService
import XCTest
@testable import HubApp

@MainActor
final class NetworkInvitationTests: XCTestCase {
  private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// An invitation signed the way `net/invite` signs one, valid for a week
  private func code() -> String {
    func part(_ value: UInt32) -> String {
      var big = value.bigEndian
      return withUnsafeBytes(of: &big) { base64URL(Data($0)) }
    }
    let key = Curve25519.Signing.PrivateKey()
    let expires = UInt32(Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)
    let payload = "\(base64URL(key.publicKey.rawRepresentation)).\(part(expires)).\(part(42))?e=wss%3A%2F%2Fv57.dev%3A1964"
    let signature = try! key.signature(for: Data(payload.utf8))
    return "\(payload)/\(base64URL(signature))"
  }

  func testAnOwnersInvitationIsNotHeld() throws {
    XCTAssertNil(try HubService.Group.invitationHold(code: code(), caller: Caller(key: "owner", owner: true)))
  }

  func testAMembersInvitationIsHeldWithWhoAskedForIt() throws {
    let code = code()
    let invitation = try NetworkInvitationParser.decode(code)
    let member = Caller(key: "member", device: .init(id: "member-device", name: "iPhone"), owner: false)
    let hold = try XCTUnwrap(HubService.Group.invitationHold(code: code, caller: member))
    XCTAssertEqual(hold.replayId, invitation.replayId)
    XCTAssertEqual(hold.replayId.count, 43)
    XCTAssertEqual(hold.by.key, "member")
    XCTAssertEqual(hold.by.device, "member-device")
    XCTAssertEqual(hold.by.name, "iPhone")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expires = try XCTUnwrap(formatter.date(from: hold.expiresAt))
    XCTAssertEqual(expires.timeIntervalSince1970, invitation.expiresAt.timeIntervalSince1970, accuracy: 1)
  }

  func testAnInvitationForACallerTheHubDidNotNameIsHeld() throws {
    XCTAssertNotNil(try HubService.Group.invitationHold(code: code(), caller: nil))
  }
}
