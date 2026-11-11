//
//  Storage driver.swift
//  Hub
//
//  Debug: turns on the storage this device shares without taps and prints `[STORAGE]` lines, beside the normal window.
//  `--storage-on`: on for the first connected hub (`--storage-hub <name>` picks one); prints the port, whether it's on
//  Hub Network, and what's used. `--storage-endpoint http://127.0.0.1` (read by DeviceStorage) makes links point there
//  instead of the Hub Network address, for simulators, which share the Mac's loopback and run no tunnel.
//  `--storage-limit <GB>` sets the limit.
//  `--storage-check <place>` (on the hub's owner, e.g. the Mac running the hub): goes through another device's storage
//  as Files does, by the place's name ("iPhone") on the first connected hub (`--storage-hub`): its space, a 300 KB
//  upload to its link, the listing, a download compared byte for byte, and a delete after which the link gets 404.
//  Over Hub Network the links go to the device's overlay address and share port. Ends with `[STORAGE] check pass|fail`.
//

#if DEBUG && canImport(S3ServerSwift)
import Foundation
import HubService
import HubUI

@MainActor
enum StorageDriver {
  static var isRequested: Bool { CommandLine.arguments.contains("--storage-on") || CommandLine.arguments.contains("--storage-check") }

  static func log(_ line: String) {
    print("[STORAGE] \(line)")
  }

  private static func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    return arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
  }

  static func run() async {
    let name = argument("--storage-hub")
    var hub: Hub?
    for _ in 0..<240 {
      hub = Hubs.main.list.first { $0.isConnected && (name == nil || $0.settings.name == name) }
      if hub != nil { break }
      try? await Task.sleep(for: .milliseconds(250))
    }
    guard let hub else { return log("result fail: no connected hub") }
    log("hub \(hub.settings.name) \(hub.settings.address.absoluteString)")
    if let place = argument("--storage-check") {
      do {
        try await check(place: place, on: hub)
        log("check pass")
      } catch {
        log("check fail: \(error)")
      }
      return
    }
    let storage = DeviceStorage.main
    if let limit = argument("--storage-limit").flatMap(Int64.init) {
      storage.setLimit(limit * DeviceStorage.gigabyte)
    }
    await storage.turnOn(hub: hub)
    log("phase \(storage.phase) port \(storage.port.map(String.init) ?? "-") limit \(StorageBackend.format(storage.settings.limit))")
    var last = ""
    while !Task.isCancelled {
      let line = "phase \(storage.phase) published \(storage.isPublished) problem \(storage.shareProblem ?? "-") used \(storage.usedBytes)"
      if line != last {
        log(line)
        last = line
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  struct CheckFailure: Error, CustomStringConvertible {
    let description: String
  }

  private static func check(place name: String, on hub: Hub) async throws {
    var service: String?
    for try await providers in hub.client.devices.providers("s3/list") {
      log("places \(providers.map { $0.name ?? $0.id })")
      service = providers.first { $0.name == name }?.id
      if service != nil { break }
    }
    guard let service else { throw CheckFailure(description: "no place named \(name)") }
    let context = HubContext(service: service)
    let before: StorageSpace = try await hub.client.send("s3/space", nil as String?, context: context)
    log("space total \(before.total) free \(before.free)")

    let path = "hub-check/\(UUID().uuidString.prefix(8)).bin"
    let bytes = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
    let write: URL = try await hub.client.send("s3/write", path, context: context)
    log("write link \(write.host() ?? "-"):\(write.port.map(String.init) ?? "-")")
    var put = URLRequest(url: write)
    put.httpMethod = "PUT"
    let (_, putResponse) = try await URLSession.shared.upload(for: put, from: bytes)
    let putStatus = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
    log("put \(putStatus)")
    guard putStatus == 200 else { throw CheckFailure(description: "upload answered \(putStatus)") }

    var listing: Listing?
    for try await list: Listing in hub.client.values("s3/list", "hub-check/", context: context) {
      listing = list
      break
    }
    let listed = listing?.files.first { "hub-check/" + $0.name == path || $0.name == path }
    log("listed \(listed.map { "\($0.name) \($0.size)" } ?? "-")")
    guard listed?.size == bytes.count else { throw CheckFailure(description: "the listing doesn't show the upload") }

    let read: String = try await hub.client.send("s3/read", path, context: context)
    guard let readURL = URL(string: read) else { throw CheckFailure(description: "bad read link \(read)") }
    let (body, getResponse) = try await URLSession.shared.data(from: readURL)
    log("get \((getResponse as? HTTPURLResponse)?.statusCode ?? 0) \(body.count) bytes, same \(body == bytes)")
    guard body == bytes else { throw CheckFailure(description: "the download differs") }

    let after: StorageSpace = try await hub.client.send("s3/space", nil as String?, context: context)
    log("space after total \(after.total) free \(after.free) (\(before.free - after.free) less)")

    try await hub.client.send("s3/delete", path, context: context)
    let (_, goneResponse) = try await URLSession.shared.data(from: readURL)
    let goneStatus = (goneResponse as? HTTPURLResponse)?.statusCode ?? 0
    log("deleted, old link \(goneStatus)")
    guard goneStatus == 404 else { throw CheckFailure(description: "the deleted file still answered \(goneStatus)") }
  }
}
#endif
