//
//  NativeJoinStoreTests.swift
//  Tests
//

import XCTest
import HubService
@testable import HubApp

final class NativeJoinStoreTests: XCTestCase {
  private final class Secrets: NativeJoinSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func load(account: String) throws -> Data? { lock.withLock { items[account] } }
    func insert(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { items.removeValue(forKey: account) } }
  }

  private var folder: URL!
  private let secrets = Secrets()

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("join-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  /// A store as one launch of the app has it, on the same folder and secrets as the others
  private func launch() -> NativeJoinStore {
    let key = KeyChain.file(folder.appendingPathComponent("auth"))
    return NativeJoinStore(directory: folder.appendingPathComponent("joins"), secrets: secrets, appIdentity: { key })
  }

  /// Two invitations at once in one launch: the second waits for the first
  func testAnotherInvitationConflictsWhileAJoinRuns() async throws {
    let store = launch()
    _ = try await store.stage(tokenId: "first")
    do {
      _ = try await store.stage(tokenId: "second")
      XCTFail("joined over an unfinished join")
    } catch {
      XCTAssertEqual(error as? NativeJoinStoreError, .transactionConflict)
    }
  }

  /// A join cut off with its process (the app was killed mid-join) doesn't refuse every later invitation
  func testAJoinAnEarlierLaunchLeftGivesWayToAnotherInvitation() async throws {
    _ = try await launch().stage(tokenId: "cut off")
    let store = launch()
    _ = try await store.stage(tokenId: "next")
    let cutOff = try await store.resume(tokenId: "cut off")
    XCTAssertNil(cutOff)
    let next = try await store.resume(tokenId: "next")
    XCTAssertNotNil(next)
  }

  /// The same invitation opened again after a relaunch picks the join up where it was
  func testTheSameInvitationResumesAfterARelaunch() async throws {
    let first = try await launch().stage(tokenId: "join")
    let again = try await launch().stage(tokenId: "join")
    XCTAssertEqual(again.wireGuardPublicKey, first.wireGuardPublicKey)
  }
}
