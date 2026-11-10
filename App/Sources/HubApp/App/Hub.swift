//
//  Client.swift
//  Hub
//
//  Created by Dmitry Kozlov on 17/2/25.
//

import Foundation
import HubService
import SwiftUI

extension KeyChain {
  /// The app's service key: what hubs know this app by. Reset Data keeps it.
  static let identityService = "dev.v57.Hub.identity.v1"
  static let main: KeyChain = {
    let accessGroup = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String
    return try! KeyChain(keychain: .init(
      service: identityService,
      account: "ed25519-private-key",
      accessGroup: accessGroup?.isEmpty == false ? accessGroup : nil,
      useDataProtectionKeychain: true
    ))
  }()

}

@MainActor
@Observable class Hub: @preconcurrency Identifiable {
  static let test = Hub(settings: Settings(name: "My Hub", address: URL(string: "ws://localhost:1997")!))
  var id: Settings.ID { settings.id }
  var settings: Settings
  let key: String
  let client: HubClient
  var service: HubService { client.service }
  var isConnected: Bool = false
  /// Why the hub refuses this app's connection, while it does
  var refusal: HubClient.Refusal?
  /// Not connected for a while: listed behind the sidebar's Show More
  var isUnreachable = false
  @ObservationIgnored private var unreachableTask: Task<Void, Never>?
  /// Filled from fixtures (`--demo`): the connection's events leave its state alone
  @ObservationIgnored var isDemo = false
  var api = Set<String>()
  var hasLauncher: Bool { require(permissions: "launcher/info") }
  
  @ObservationIgnored var appServices: AppServices!
  @ObservationIgnored var apiTask: Task<Void, Error>?
  @ObservationIgnored var state = HubStateStorage()
  @ObservationIgnored private(set) lazy var net = HubNet(hub: self)
  @ObservationIgnored lazy var networkAppAgent =
    ShareNetworkAppAgentCoordinator(hub: self)
  
  /// The key this app connects to the hub with, and binds as its machine's agent with
  @ObservationIgnored let identity: KeyChain

  init(settings: Settings) {
    var settings = settings
    let scope = settings.keys ?? AppCredentials.scope(for: settings.address)
    settings.keys = scope
    self.settings = settings
    let identity = AppCredentials.service(scope: scope, tag: settings.identityTag)
    let device = AppCredentials.device(scope: scope)
    self.identity = identity
    key = identity.publicKey()
    let address = settings.address
    self.client = HubClient(settings.address, keyChain: identity, options: .init(
      // A derived key has no place of its own to pin beside; a legacy membership key has
      hubKeys: settings.identityTag == nil ? HubKeyPins.beside(.main) : nil,
      device: device, instance: "Hub",
      // Away from the hub's own address, its machine still answers on Hub Network through the link to it
      alternateURLs: { await HubNet.alternateURLs(for: address) }
    ))
    // Every frame on stdout, invitation and pairing codes included: Debug builds only (security audit L34).
    #if DEBUG
      client.debugNetwork = true
    #endif
    if let device {
      client.report(description: { await AppDevice.description(device: device.key) }, data: AppDevice.data)
    }
    isConnected = client.isConnected
    client.onRefused = { [weak self] in
      guard self?.isDemo == false else { return }
      self?.refusal = $0
    }
    client.isConnectedChanged = { [weak self] in
      guard self?.isDemo == false else { return }
      self?.isConnected = $0
      if $0 { self?.refusal = nil }
      self?.waitForConnection()
      self?.net.connectionChanged($0)
    }
    apiTask = Task {
      for try await api: Set<String> in client.values("hub/api") {
        EventDelayManager.main.execute {
          self.api = api
          self.net.apiCapabilitiesChanged()
        }
      }
    }
    appServices = AppServices(hub: self)
    waitForConnection()
    Task { [weak self] in
      await self?.net.restoreIfActive()
    }
  }
  deinit {
    apiTask?.cancel()
    unreachableTask?.cancel()
  }
  /// A hub that doesn't connect within 15 seconds reads as unreachable until it does
  private func waitForConnection() {
    unreachableTask?.cancel()
    guard !isDemo else { return }
    guard !isConnected else {
      isUnreachable = false
      return
    }
    unreachableTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(15))
      guard !Task.isCancelled, let self, !self.isConnected, !self.isDemo else { return }
      self.isUnreachable = true
    }
  }
  struct Settings: Codable, Identifiable, Hashable {
    var id: URL { address }
    var name: String
    var address: URL
    var identityTag: String? = nil
    /// Which keys the app uses on this hub (App credentials.swift): `sharedKeys`, or what its own are derived from
    var keys: String? = nil
  }
  /// Whether this app connects to this hub with the keys every hub from before auth v2 shares
  var usesSharedKeys: Bool { settings.keys == Settings.sharedKeys || settings.identityTag != nil }
  /// A device's safety code, worked out from the key this app pinned for this hub. Nil when there's no value to work it
  /// from: nothing is shown then, since a code without the hub's value says nothing.
  func safetyCode(deviceKey: String, codeValue: String?) -> String? {
    guard let codeValue, let pinned = client.hubKey else { return nil }
    return DeviceKey.safetyCode(hubKey: pinned, deviceKey: deviceKey, codeValue: codeValue)
  }
  /// What the page shows for a device asking to join; a hub stating another code than the pinned key gives shows none
  func safetyCode(of device: PendingDevice) -> String? {
    if isDemo { return device.safetyCode }
    return client.hubKey.flatMap { device.verifiedCode(hubKey: $0) }
  }
  /// The same for a device asking to attach. Without it there's nothing to compare, so nothing to sign.
  func safetyCode(of request: AttachRequest) -> String? {
    if isDemo { return request.safetyCode }
    return client.hubKey.flatMap { request.verifiedCode(hubKey: $0) }
  }
  /// What the packet tunnel derives this hub's key from; `nil` for the app's shared key, which it reads as it is
  var tunnelKeyScope: String? {
    settings.identityTag == nil && settings.keys != Settings.sharedKeys ? settings.keys : nil
  }
  func require(permissions: String...) -> Bool {
    !permissions.contains { !api.contains($0) }
  }

}

struct Status: Decodable, Hashable {
  let requests: Int
  let services: [Service]
  struct Service: Decodable, Hashable {
    let name: String
    let services: Int
    let disabled: Int?
    let requests: Int
    let balancer: String?
    var balancerType: BalancerType {
      guard let balancer else { return .counter }
      return BalancerType(rawValue: balancer) ?? .unknown
    }
    let pending: Int?
    let running: Int?
  }
  enum BalancerType: String {
    case random, counter, first, available, unknown
    static var all: [BalancerType] { [.random, .counter, .first, .available] }
  }
  func contains(service: String) -> Bool {
    let launcher = services.first(where: {
      $0.name.starts(with: "\(service)/")
    })
    let disabled = launcher?.disabled ?? 0
    let services = launcher?.services ?? 0
    return disabled + services > 0
  }
}

@MainActor
@Observable
class Hubs {
  static let main = Hubs()
  var selected: Hub.ID? {
    didSet {
      guard selected != oldValue, Self.persists else { return }
      UserDefaults.standard.set(selected, forKey: "selected")
    }
  }
  /// Whether choices are kept across launches: not in the demo, whose hubs would replace the real ones' (a Debug
  /// build shares the app's container).
  static var persists: Bool {
#if DEBUG
    !HubDemo.isOn
#else
    true
#endif
  }
  var list = [Hub]()
  var selectedHub: Hub? {
    guard let selected else { return nil }
    return list.first(where: { $0.id == selected })
  }
  init() {
#if DEBUG
    if HubDemo.isOn {
      list = HubDemo.hubs()
      return
    }
#endif
    if let data = UserDefaults.standard.data(forKey: "hubs") {
      do {
        list = []
        let pins = HubKeyPins.beside(.main)
        for var settings in try JSONDecoder().decode([Hub.Settings].self, from: data) {
          // Kept from before auth v2: a pinned hub was approved with the shared keys, so nobody pairs again
          if settings.keys == nil, settings.identityTag != nil || pins.key(for: settings.address) != nil {
            settings.keys = Hub.Settings.sharedKeys
          }
          let hub = Hub(settings: settings)
          list.append(hub)
        }
        save()
        if let selected = UserDefaults.standard.url(forKey: "selected") {
          self.selected = selected
        }
      } catch {}
    }
#if canImport(VaultHub)
    AppVault.start(hubs: list.map(\.settings))
#endif
  }
  func select(_ hub: Hub.ID?) {
    selected = hub
  }
  /// Back in front: every hub tries at once instead of waiting out its backoff, or an attempt iOS suspended
  /// mid-way (this device's own hub restarting under it) left the hub Offline until Hub was relaunched
  func reconnectNow() {
    for hub in list where !hub.isDemo {
      hub.client.reconnectNow()
    }
  }
  @discardableResult
  func insert(with settings: Hub.Settings) -> Hub {
    var settings = settings
    let hub: Hub
    if let index = list.firstIndex(where: { $0.id == settings.id }) {
      if settings.keys == nil { settings.keys = list[index].settings.keys }
      if list[index].settings == settings {
        hub = list[index]
      } else {
        list[index].client.stop()
        hub = Hub(settings: settings)
        list[index] = hub
      }
    } else {
      hub = Hub(settings: settings)
      list.append(hub)
    }
    selected = settings.id
    save()
#if canImport(VaultHub)
    AppVault.add(hub.settings)
#endif
    return hub
  }
  /// The user says the hub at this address has a new key on purpose. Whatever answers there is a new hub to this device,
  /// so a hub on the shared keys moves to keys of its own, and an owner approves it again.
  func trustNewKey(of hub: Hub) {
    hub.refusal = nil
    var settings = hub.settings
#if canImport(VaultHub)
    AppVault.forgetKey(settings)
#endif
    guard settings.keys == Hub.Settings.sharedKeys, settings.identityTag == nil else {
      hub.client.forgetHubKey()
      return
    }
    hub.client.hubKeys.forget(settings.address)
    settings.keys = HubAddress.canonical(settings.address) ?? settings.address.absoluteString
    insert(with: settings)
  }
  func remove(with settings: Hub.Settings) {
    guard let index = self.list.firstIndex(where: { $0.id == settings.id }) else { return }
    if let selected, selected == settings.id {
      self.selected = list.first?.id
    }
    list[index].client.stop()
    list.remove(at: index)
    save()
#if canImport(VaultHub)
    AppVault.remove(settings)
#endif
  }
  func save() {
    do {
      let data = try JSONEncoder().encode(list.map(\.settings))
      UserDefaults.standard.set(data, forKey: "hubs")
    } catch { }
  }
}


extension View {
  func hub(_ hub: Hub) -> some View {
    environment(hub).environment(hub.client)
  }
}
