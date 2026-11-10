//
//  Storage driver.swift
//  Hub
//
//  Debug: turns on the storage this device shares without taps and prints `[STORAGE]` lines, beside the normal window.
//  `--storage-on`: on for the first connected hub (`--storage-hub <name>` picks one); prints the port, whether it's on
//  Hub Network, and what's used. `--storage-endpoint http://127.0.0.1` (read by DeviceStorage) makes links point there
//  instead of the Hub Network address, for simulators, which share the Mac's loopback and run no tunnel.
//  `--storage-limit <GB>` sets the limit.
//

#if DEBUG && canImport(S3ServerSwift)
import Foundation

@MainActor
enum StorageDriver {
  static var isRequested: Bool { CommandLine.arguments.contains("--storage-on") }

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
}
#endif
