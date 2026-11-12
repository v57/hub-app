//
//  NetworkInvitationTests.swift
//  Tests
//
//  What the hub machine's net/invite holds for a member (H-034), and invitation links that say they're for browsing
//  through the inviting device's internet (H-035).
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

  func testABrowseLinkCarriesTheSameInvitation() throws {
    let code = code()
    let join = NetworkInvitationParser.urlPrefix + code
    let browse = NetworkInvitationLink.browse(join)
    XCTAssertEqual(browse, "hub://browse/" + code)
    XCTAssertEqual(NetworkInvitationLink.browse(code), browse, "a bare code becomes a browse link too")
    XCTAssertTrue(NetworkInvitationLink.parse(browse).browse)
    XCTAssertEqual(NetworkInvitationLink.parse(browse).link, join)
    XCTAssertFalse(NetworkInvitationLink.parse(join).browse)
    XCTAssertEqual(NetworkInvitationLink.parse(" \(join)\n").link, join)
    XCTAssertEqual(try NetworkInvitationLink.decode(browse).replayId, try NetworkInvitationParser.decode(join).replayId)
    XCTAssertThrowsError(try NetworkInvitationParser.decode(browse), "the plain parser takes only join links")
  }

  func testTheRouterTakesBothLinksAndSaysWhichOne() throws {
    let router = NetworkInvitationRouter()
    router.open(URL(string: "hub://browse/" + code())!)
    XCTAssertTrue(router.pendingIsBrowse)
    _ = router.consume()
    router.open(URL(string: NetworkInvitationParser.urlPrefix + code())!)
    XCTAssertFalse(router.pendingIsBrowse)
    XCTAssertFalse(router.consume().isEmpty)
    router.open(URL(string: "hub://pair/abc")!)
    XCTAssertTrue(router.pendingInput.isEmpty)
  }
}
