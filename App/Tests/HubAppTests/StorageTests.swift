//
//  StorageTests.swift
//  Tests
//
//  This Device's Storage without a hub: the s3/* answers over a real folder, the limit, links, and a running server.
//

#if canImport(S3ServerSwift)
import XCTest
import HubService
import S3ServerSwift
@testable import HubApp

final class StorageTests: XCTestCase {
  func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "StorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func backend(limit: Int64 = 10 << 30, free: Int64? = 100 << 30) throws -> StorageBackend {
    let backend = try StorageBackend(folder: try folder(), limit: limit)
    backend.freeSpace = { free }
    return backend
  }

  func write(_ backend: StorageBackend, _ key: String, _ text: String = "hello") throws {
    let url = backend.folder.appending(path: key)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  // MARK: Listing

  func testListIsOneLevelWithRelativeNames() throws {
    let backend = try backend()
    try write(backend, "a.txt")
    try write(backend, "photos/b.jpg", "12345678")
    try write(backend, "photos/2026/c.jpg")
    let top = try backend.list(nil)
    XCTAssertEqual(top.files.map(\.name), ["a.txt"])
    XCTAssertEqual(top.directories, ["photos/"])
    XCTAssertEqual(top.count, 2)
    XCTAssertNotNil(top.files.first?.lastModified)
    let photos = try backend.list("photos/")
    XCTAssertEqual(photos.files, [StorageFileInfo(name: "b.jpg", size: 8, lastModified: photos.files.first?.lastModified)])
    XCTAssertEqual(photos.directories, ["2026/"])
  }

  func testReadDirectoryGivesEveryKeyBelow() throws {
    let backend = try backend()
    try write(backend, "a.txt")
    try write(backend, "photos/b.jpg")
    try write(backend, "photos/2026/c.jpg")
    XCTAssertEqual(Set(try backend.readDirectory("photos/").map(\.name)), ["photos/b.jpg", "photos/2026/c.jpg"])
    XCTAssertEqual(try backend.readDirectory(nil).count, 3)
  }

  func testSizeAndMissingFile() throws {
    let backend = try backend()
    try write(backend, "a.txt", "abc")
    XCTAssertEqual(try backend.size("a.txt"), 3)
    XCTAssertThrowsError(try backend.size("missing.txt")) { error in
      XCTAssertEqual((error as? HubError)?.code, HubError.notFound().code)
    }
  }

  func testDeleteFileAndFolder() throws {
    let backend = try backend()
    try write(backend, "a.txt")
    try write(backend, "photos/b.jpg", "12345678")
    try write(backend, "photos/2026/c.jpg")
    backend.set(used: 18)
    try backend.delete("a.txt")
    XCTAssertEqual(backend.usedBytes, 13)
    // A key naming a folder without the slash removes nothing
    try backend.delete("photos")
    XCTAssertEqual(try backend.readDirectory(nil).count, 2)
    try backend.delete("photos/")
    XCTAssertEqual(try backend.readDirectory(nil).count, 0)
    XCTAssertEqual(backend.usedBytes, 0)
    // Deleting what's gone already is fine, as S3's DELETE
    XCTAssertNoThrow(try backend.delete("a.txt"))
  }

  func testDeleteNotifiesTheFoldersAbove() throws {
    let backend = try backend()
    try write(backend, "photos/2026/c.jpg")
    let top = Counter(), photos = Counter(), other = Counter()
    _ = backend.watch(folder: "") { top.add() }
    _ = backend.watch(folder: "photos/") { photos.add() }
    _ = backend.watch(folder: "music/") { other.add() }
    try backend.delete("photos/2026/c.jpg")
    XCTAssertEqual(top.value, 1)
    XCTAssertEqual(photos.value, 1)
    XCTAssertEqual(other.value, 0)
  }

  func testFoldersAbove() {
    XCTAssertEqual(StorageBackend.folders(above: "a/b/c.txt"), ["", "a/b/", "a/"])
    XCTAssertEqual(StorageBackend.folders(above: "c.txt"), [""])
  }

  // MARK: Limit

  func testUploadsPastTheLimitAreRefused() throws {
    let backend = try backend(limit: 100)
    backend.set(used: 60)
    XCTAssertNil(backend.admit(S3Upload(bucket: "hub", key: "a", length: 40, replacedSize: 0)))
    XCTAssertEqual(backend.admit(S3Upload(bucket: "hub", key: "a", length: 41, replacedSize: 0))?.status, 507)
    // Replacing a file counts only what it adds
    XCTAssertNil(backend.admit(S3Upload(bucket: "hub", key: "a", length: 50, replacedSize: 30)))
    // Over the limit already (a lower limit keeps what's stored): a smaller replacement still goes in
    backend.set(limit: 10)
    XCTAssertNil(backend.admit(S3Upload(bucket: "hub", key: "a", length: 5, replacedSize: 20)))
  }

  func testUploadsThatWouldFillTheDeviceAreRefused() throws {
    let backend = try backend(limit: 100 << 30, free: StorageBackend.reserve + 1000)
    XCTAssertNil(backend.admit(S3Upload(bucket: "hub", key: "a", length: 1000, replacedSize: 0)))
    let error = backend.admit(S3Upload(bucket: "hub", key: "a", length: 1001, replacedSize: 0))
    XCTAssertEqual(error?.code, "StorageFull")
  }

  @MainActor func testDefaultLimit() {
    let gigabyte = DeviceStorage.gigabyte
    XCTAssertEqual(DeviceStorage.defaultLimit(free: nil), gigabyte)
    XCTAssertEqual(DeviceStorage.defaultLimit(free: 2 * gigabyte), gigabyte)
    XCTAssertEqual(DeviceStorage.defaultLimit(free: 41 * gigabyte), 10 * gigabyte)
    XCTAssertEqual(DeviceStorage.defaultLimit(free: 2000 * gigabyte), 100 * gigabyte)
  }

  // MARK: Links

  func publication(authority: String = "s3.abcd1234.hub.invalid", protocol: NetworkProtocol = .tcp, port: UInt16 = 443) -> NetworkSharePublication {
    NetworkSharePublication(resourceId: "r", authority: authority, providerId: "p", protocol: `protocol`, overlayAddress: "100.96.0.2", port: port)
  }

  func testLinksFailClosedUntilTheShareIsPublished() throws {
    let backend = try backend()
    XCTAssertThrowsError(try backend.link(method: "GET", key: "a.txt")) { XCTAssertEqual($0 as? StorageError, .off) }
    backend.set(port: 4567, endpoint: nil)
    XCTAssertThrowsError(try backend.link(method: "GET", key: "a.txt")) { error in
      XCTAssertEqual(error.localizedDescription, "Hub Network S3 share is not published")
    }
    backend.set(publication: publication())
    let link = try XCTUnwrap(URL(string: try backend.link(method: "PUT", key: "photos/a b.jpg")))
    XCTAssertEqual(link.host, "s3.abcd1234.hub.invalid")
    XCTAssertEqual(link.port, 443)
    XCTAssertEqual(link.scheme, "http")
    XCTAssertTrue(link.path.hasPrefix("/hub/photos/"))
    XCTAssertTrue(link.query?.contains("X-Amz-Signature=") ?? false)
    XCTAssertTrue(link.query?.contains("X-Amz-Expires=604800") ?? false)
  }

  func testOnlyCanonicalShareAuthoritiesAreUsed() {
    XCTAssertThrowsError(try StorageBackend.overlayEndpoint(publication(authority: "evil.example.com")))
    XCTAssertThrowsError(try StorageBackend.overlayEndpoint(publication(authority: "a..hub.invalid")))
    XCTAssertThrowsError(try StorageBackend.overlayEndpoint(publication(authority: "-a.hub.invalid")))
    XCTAssertThrowsError(try StorageBackend.overlayEndpoint(publication(authority: "A.hub.invalid")))
    XCTAssertThrowsError(try StorageBackend.overlayEndpoint(publication(protocol: .udp)))
    XCTAssertThrowsError(try StorageBackend.overlayEndpoint(publication(port: 0)))
    XCTAssertEqual(try StorageBackend.overlayEndpoint(publication()).absoluteString, "http://s3.abcd1234.hub.invalid:443")
  }

  func testDirectEndpointTakesTheServersPort() {
    XCTAssertEqual(StorageBackend.direct(URL(string: "http://127.0.0.1")!, port: 4567).absoluteString, "http://127.0.0.1:4567")
    XCTAssertEqual(StorageBackend.direct(URL(string: "http://127.0.0.1:80")!, port: 4567).absoluteString, "http://127.0.0.1:80")
  }

  func testOnlyThisDeviceAndHubNetworkConnect() {
    for address in ["127.0.0.1", "::1", "100.64.0.1", "100.96.0.2", "100.127.255.254", "fd48:5542:4e45::2", "FD48:5542:4E45:1::9"] {
      XCTAssertTrue(StorageBackend.isAllowed(address), address)
    }
    for address in ["192.168.1.2", "10.0.0.1", "100.128.0.1", "100.63.255.255", "fd00::1", "8.8.8.8", "fe80::1"] {
      XCTAssertFalse(StorageBackend.isAllowed(address), address)
    }
  }

  // MARK: Streams

  func testStreamYieldsChangesWithoutRepeats() async throws {
    let backend = try backend()
    let (stream, continuation) = AsyncThrowingStream<Encodable & Sendable, Error>.makeStream()
    let task = Task {
      try await StorageBackend.stream(continuation, subscribe: { backend.watch(folder: "", $0) }, unsubscribe: backend.unwatch) {
        try backend.list(nil)
      }
    }
    var iterator = stream.makeAsyncIterator()
    let first = try await iterator.next() as? StorageFiles
    XCTAssertEqual(first?.count, 0)
    try write(backend, "a.txt")
    backend.notify(folder: nil)
    let second = try await iterator.next() as? StorageFiles
    XCTAssertEqual(second?.files.map(\.name), ["a.txt"])
    task.cancel()
  }

  func testStatusUpdates() throws {
    let backend = try backend()
    let count = Counter()
    _ = backend.watchStatuses { count.add() }
    backend.update(StorageStatusUpdate(path: "a.mov", status: StorageFileStatus(name: "Encoding", progress: 0.5)))
    XCTAssertEqual(backend.currentStatuses["a.mov"]?.progress, 0.5)
    backend.update(StorageStatusUpdate(path: "a.mov", status: nil))
    XCTAssertNil(backend.currentStatuses["a.mov"])
    XCTAssertEqual(count.value, 2)
  }

  // MARK: A running server

  func testUploadReadAndDeleteThroughTheServer() async throws {
    let backend = try backend(limit: 1000)
    let server = S3Server(options: try StorageBackend.options(folder: backend.folder, port: 0, key: backend.accessKeyID, secret: backend.secretAccessKey), hooks: backend.hooks)
    try await server.start()
    let bound = await server.boundPort
    let port = try XCTUnwrap(bound)
    addTeardownBlock { await server.stop() }
    backend.set(port: port, endpoint: URL(string: "http://127.0.0.1"))
    let changed = Counter()
    _ = backend.watch(folder: "docs/") { changed.add() }

    var put = URLRequest(url: URL(string: try backend.link(method: "PUT", key: "docs/a.txt"))!)
    put.httpMethod = "PUT"
    let (_, putResponse) = try await URLSession.shared.upload(for: put, from: Data("hello storage".utf8))
    XCTAssertEqual((putResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(backend.usedBytes, 13)
    XCTAssertEqual(changed.value, 1)
    XCTAssertEqual(try backend.list("docs/").files.map(\.name), ["a.txt"])

    let (body, getResponse) = try await URLSession.shared.data(from: URL(string: try backend.link(method: "GET", key: "docs/a.txt"))!)
    XCTAssertEqual((getResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello storage")

    // A read link doesn't write
    var forged = URLRequest(url: URL(string: try backend.link(method: "GET", key: "docs/a.txt"))!)
    forged.httpMethod = "PUT"
    let (_, forgedResponse) = try await URLSession.shared.upload(for: forged, from: Data("x".utf8))
    XCTAssertEqual((forgedResponse as? HTTPURLResponse)?.statusCode, 403)

    // Past the limit: refused, and nothing stored
    var big = URLRequest(url: URL(string: try backend.link(method: "PUT", key: "docs/big.bin"))!)
    big.httpMethod = "PUT"
    let (_, bigResponse) = try await URLSession.shared.upload(for: big, from: Data(count: 2000))
    XCTAssertEqual((bigResponse as? HTTPURLResponse)?.statusCode, 507)
    XCTAssertEqual(try backend.list("docs/").files.map(\.name), ["a.txt"])

    try backend.delete("docs/")
    XCTAssertEqual(backend.usedBytes, 0)
    XCTAssertEqual(try backend.readDirectory(nil).count, 0)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func add() { lock.withLock { count += 1 } }
}
#endif
