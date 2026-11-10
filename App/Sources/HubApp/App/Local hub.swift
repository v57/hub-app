//
//  Local hub.swift
//  Hub
//
//  Runs a Hub server inside the app (Core/HubServer), so this device can be the hub.
//

#if canImport(HubServer)
import Foundation
import HubServer
import HubService
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// The hub this device runs: the embedded `HubServer`, listening on the local network, with its data in the app's
/// container. The app is its owner from the start (its key and its device), and connects to it like to any hub.
@MainActor
@Observable
final class LocalHub {
  static let main = LocalHub()

  /// Run a hub on this device, also after the next launch
  private(set) var isEnabled: Bool {
    didSet { UserDefaults.standard.set(isEnabled, forKey: "localHub.enabled") }
  }
  /// The port it listens on, 1997 like every hub
  var port: UInt16 {
    didSet { UserDefaults.standard.set(Int(port), forKey: "localHub.port") }
  }
  private(set) var status = HubServer.Status()
  /// Why it couldn't start, until the next try
  private(set) var error: String?
  /// A pairing code for another device to become an owner too, while shown
  var pairing: HubServer.PairingCode? { isPairingHidden ? nil : status.pairingCode }
  private var isPairingHidden = false
  /// The shown code was used: another device paired
  private(set) var didPair = false
  /// This device's local network addresses, `192.168.1.5`
  private(set) var addresses: [String] = []

  @ObservationIgnored private var server: HubServer?
  @ObservationIgnored private var statusTask: Task<Void, Never>?
  /// Hub has left the screen (iOS suspends it soon after)
  @ObservationIgnored private var isInBackground = false
#if os(iOS) || os(tvOS) || os(visionOS)
  @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
#endif

  init() {
    isEnabled = UserDefaults.standard.bool(forKey: "localHub.enabled")
    let stored = UserDefaults.standard.integer(forKey: "localHub.port")
    port = (1...65535).contains(stored) ? UInt16(stored) : 1997
  }

  var isRunning: Bool { status.state == .running }
  var isStarting: Bool { status.state == .starting }

  /// Where the app reaches its own hub
  var localURL: URL { URL(string: "ws://127.0.0.1:\(status.port ?? port)")! }

  /// What other devices on the network dial: `192.168.1.5:1997`
  var networkAddress: String? {
    addresses.first.map { "\($0):\(status.port ?? port)" }
  }

  /// `hub://pair?a=<address>&c=<code>` for the current pairing code
  var pairingLink: URL? {
    guard let pairing, let address = networkAddress else { return nil }
    return HubServer.pairingLink(address: address, code: pairing.code)
  }

  /// The hub's data: its key (`auth`), devices, grants and groups. Kept across launches, since the key is what
  /// other devices pin.
  static var dataDirectory: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Hub Server", isDirectory: true)
  }

  func setEnabled(_ enabled: Bool) async {
    isEnabled = enabled
    if enabled {
      await start()
    } else {
      await stop()
    }
  }

  /// At launch and when the app comes back: starts the hub if it should run and doesn't
  func resume() async {
    isInBackground = false
    endBackgroundTask()
    refreshAddresses()
    guard isEnabled, !isRunning, !isStarting else { return }
    await start()
  }

  func start() async {
    if server != nil, isRunning || isStarting { return }
    // A hub whose listener failed (the app was suspended) starts over
    if let old = server { await old.stop() }
    error = nil
    refreshAddresses()
    let server: HubServer
    do {
      server = HubServer(try configuration())
    } catch {
      // Never a new key instead: that would change the hub's identity for every device that pinned it
      self.server = nil
      self.error = String(localized: "Couldn't read the hub's key: \(String(describing: error))")
      return
    }
    self.server = server
    statusTask?.cancel()
    statusTask = Task { [weak self] in
      for await status in server.statusUpdates() {
        guard let self, self.server === server else { return }
        // The code went away while running: someone used it (it can also expire, after an hour)
        if self.status.pairingCode != nil, status.state == .running, status.pairingCode == nil,
          let shown = self.status.pairingCode, shown.expires > Date() {
          self.didPair = true
        }
        let restarts = Self.restarts(from: self.status.state, to: status.state, isEnabled: self.isEnabled, isInBackground: self.isInBackground)
        self.status = status
        if restarts {
          Task { await self.start() }
        }
      }
    }
    do {
      _ = try await server.start()
      status = server.status
      connectApp()
    } catch {
      self.error = Self.describe(error, port: port)
      status = server.status
    }
  }

  func stop() async {
    guard let server else { return }
    self.server = nil
    statusTask?.cancel()
    await server.stop()
    status = server.status
    if let hub = Hubs.main.list.first(where: { $0.settings.address == localURL }) {
      Hubs.main.remove(with: hub.settings)
    }
  }

  /// Reset Data: stops the hub and forgets that it runs; its data goes with the rest of the app's
  func reset() async {
    await setEnabled(false)
    port = 1997
    error = nil
    didPair = false
    isPairingHidden = false
  }

  /// A new code for another device to pair with, replacing the old one
  func newPairingCode() async {
    guard let server else { return }
    do {
      _ = try await server.newPairingCode()
      isPairingHidden = false
      didPair = false
      error = nil
    } catch {
      self.error = "\(error)"
    }
  }

  func hidePairingCode() {
    isPairingHidden = true
  }

  private func configuration() throws -> HubServer.Configuration {
    var configuration = HubServer.Configuration(dataDirectory: Self.dataDirectory)
#if canImport(Security)
    configuration.key = try Self.hubKey()
#endif
    configuration.listen = ListenAddress(port: port)
    configuration.name = AppDevice.name
    configuration.deviceName = AppDevice.name
    configuration.platform = AppDevice.platform
    // Its devices learn from `hub/info` that this app is the hub's Hub Network agent
    configuration.host = "app"
    // The app is the owner: its service key and its device
    configuration.owners = [KeyChain.main.publicKey()] + (DeviceIdentity.app.map { [$0.key.publicKey] } ?? [])
    configuration.devicePublicKey = DeviceIdentity.app?.key.publicKey
    configuration.pairsAtStart = false
#if DEBUG
    configuration.log = { print("[Hub Server]", $0) }
#else
    configuration.log = { _ in }
#endif
    return configuration
  }

#if canImport(Security)
  /// The hub's key, in the app's own keychain group and on this device only, moved there from the `auth` file older
  /// builds wrote. Other devices pin it and it signs what they trust, so no other app and no file should hold it.
  /// Settings' Reset Data removes it with the hub's data. Without a keychain (Linux) it stays the `auth` file.
  private static func hubKey() throws -> HubKeyPair {
    let group = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String
    let item = KeyChain.KeychainConfiguration(
      service: "dev.v57.Hub.local-hub.v1",
      account: "ed25519-private-key",
      accessGroup: group?.isEmpty == false ? group : nil,
      useDataProtectionKeychain: true
    )
    return try HubKeyPair.moved(
      from: dataDirectory.appendingPathComponent("auth"),
      load: { try KeyChain.loadData(keychain: item) },
      save: { try KeyChain.replaceData($0, keychain: item) }
    )
  }
#endif

  /// Adds this hub to the app's hubs, with its key pinned so the first connection is already hub-bound
  private func connectApp() {
    guard let hubKey = status.hubKey else { return }
    let url = localURL
    HubKeyPins.beside(.main).pin(hubKey, for: url)
    if let hub = Hubs.main.list.first(where: { $0.settings.address == url }) {
      // A restarted hub: its client tries at once, also when it was mid-way through an attempt iOS suspended
      if hub.client.hubKey != hubKey { hub.client.forgetHubKey() } else { hub.client.reconnectNow() }
      return
    }
    let selected = Hubs.main.selected
    // Its key is pinned above and the app is its owner: it stays on the shared keys
    Hubs.main.insert(with: Hub.Settings(name: status.name ?? AppDevice.name, address: url, keys: Hub.Settings.sharedKeys))
    // Keep the hub the user was looking at
    if let selected { Hubs.main.select(selected) }
  }

  private static func describe(_ error: Error, port: UInt16) -> String {
    let text = "\(error)"
    if text.contains("rawValue: 48") || text.localizedCaseInsensitiveContains("address already in use") {
      return String(localized: "Port \(port) is in use by another app or hub. Pick another port.")
    }
    return text
  }

  // MARK: Background

  /// iOS suspends the app soon after it leaves the screen, and the hub with it. This asks for the few minutes iOS
  /// grants to finish what's in flight; Farm keeps the app on screen to serve for longer.
  func enteredBackground() {
    isInBackground = true
#if os(iOS) || os(tvOS) || os(visionOS)
    guard isRunning, backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Hub Server") { [weak self] in
      self?.endBackgroundTask()
    }
#endif
  }

  private func endBackgroundTask() {
#if os(iOS) || os(tvOS) || os(visionOS)
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
#endif
  }

  /// Whether the hub starts again by itself: it was running and stopped listening (iOS takes the listener while the
  /// app is suspended, and may say so only once the app is back, after `resume()` found it still running), it should
  /// run, and Hub is in front. In the background `resume()` starts it on the way back.
  nonisolated static func restarts(
    from old: HubServer.State, to new: HubServer.State, isEnabled: Bool, isInBackground: Bool
  ) -> Bool {
    guard case .failed = new, old == .running else { return false }
    return isEnabled && !isInBackground
  }

  // MARK: Addresses

  func refreshAddresses() {
    addresses = Self.localAddresses()
  }

  /// IPv4 addresses of the interfaces that are up, Wi-Fi and Ethernet first
  static func localAddresses() -> [String] {
    var result: [(name: String, address: String)] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let interface = pointer.pointee
      let flags = Int32(interface.ifa_flags)
      guard let address = interface.ifa_addr, Int32(address.pointee.sa_family) == AF_INET,
        flags & Int32(IFF_UP) != 0, flags & Int32(IFF_RUNNING) != 0, flags & Int32(IFF_LOOPBACK) == 0
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length = socklen_t(MemoryLayout<sockaddr_in>.size)
      guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
      result.append((String(cString: interface.ifa_name), String(cString: host)))
    }
    return reachableAddresses(result)
  }

  /// The addresses other devices can dial, each once, Wi-Fi and Ethernet first. An address two interfaces share
  /// (cellular's 192.0.0.x on an iPhone) was listed twice.
  nonisolated static func reachableAddresses(_ interfaces: [(name: String, address: String)]) -> [String] {
    func rank(_ name: String) -> Int {
      // Wi-Fi and Ethernet: en* on Apple platforms, en*, eth* and wl* on Linux
      if name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("wl") { return 0 }
      if name.hasPrefix("bridge") { return 1 }
      return 2
    }
    var seen = Set<String>()
    return interfaces
      // Link-local addresses aren't reachable from other devices
      .filter { !$0.address.hasPrefix("169.254.") }
      .sorted { rank($0.name) < rank($1.name) }
      .map(\.address)
      .filter { seen.insert($0).inserted }
  }
}
#endif
