//
//  Hub state.swift
//  Hub
//
//  Created by Linux on 07.02.26.
//

import Foundation
import Combine
import SwiftUI
import HubService

@MainActor
struct HubStateStorage {
  let users = Sync("hub/connections", [Hub.User]())
  let groups = Sync("hub/group/list", GroupList())
  let permissions = Sync("hub/group/names", PermissionList())
  let statusBadges = Sync("hub/status/badges", Hub.StatusBadges())
  let status = Sync("hub/status", Status(requests: 0, services: []))
  let merge = Sync("hub/merge/status", [Hub.MergeStatus]())
  let hostPending = Sync("hub/host/pending", PendingList())
  let launcherInfo = Sync("launcher/info", Hub.Launcher.Apps())
  let launcherStatus = Sync("launcher/status", Hub.Launcher.Status())
  let whitelist = Sync("hub/whitelist/status", WhitelistStatus())
  
  @MainActor @Observable
  class Sync<T: Decodable> {
    @ObservationIgnored let path: String
    @ObservationIgnored weak var subscription: AnyCancellable?
    var value: T
    init(_ path: String, _ defaultValue: T) {
      self.value = defaultValue
      self.path = path
    }
    func subscribe(hub: Hub) -> AnyCancellable {
      if let subscription {
        return subscription
      } else {
        let path = path
        let subscription = Task { [weak self] in
          do {
            for try await value: T in hub.client.values(path) {
              EventDelayManager.main.execute {
                self?.value = value
              }
            }
          } catch { }
        }.cancellable()
        self.subscription = subscription
        return subscription
      }
    }
  }
}

@MainActor
@propertyWrapper
struct HubState<T: Decodable>: DynamicProperty {
  @Environment(Hub.self) var hub
  typealias Path = KeyPath<HubStateStorage, HubStateStorage.Sync<T>>
  @State var storage = Storage()
  let path: Path
  var wrappedValue: T {
    storage.subscribeIfNeeded(hub: hub, path: path)
    return hub.state[keyPath: path].value
  }
  var projectedValue: Binding<T> {
    Binding(get: { hub.state[keyPath: path].value }, set: { hub.state[keyPath: path].value = $0 })
  }
  init(_ path: Path) {
    self.path = path
  }
  class Storage {
    var hub: Hub?
    var subscription: AnyCancellable?
    @MainActor
    func subscribeIfNeeded(hub: Hub, path: Path) {
      guard self.hub?.id != hub.id else { return }
      self.hub = hub
      subscription = hub.state[keyPath: path].subscribe(hub: hub)
    }
  }
}

struct PendingList: Decodable {
  var list: [Item]
  init() {
    list = []
  }
  init(from decoder: any Decoder) throws {
    list = try decoder.singleValueContainer()
      .decode([String: [String]].self)
      .map { Item(id: $0.key, pending: $0.value.sorted()) }
      .sorted(by: { $0.id < $1.id })
  }
  struct Item: Identifiable, Hashable {
    let id: String
    let pending: [String]
    var name: String {
      var set = Set<String>()
      pending.forEach { set.insert($0.components(separatedBy: "/")[0]) }
      return set.sorted().joined(separator: " & ")
    }
  }
}

struct WhitelistStatus: Decodable {
  var enabled: Bool = false
  var users: Set<String> = []
}

struct SetLockdown: Encodable {
  var enabled: Bool?
  var add: [String]?
  var remove: [String]?
  var allowsCurrent: Bool?
}

extension Hub {
  var host: HostApi { HostApi(hub: self) }
  var hasStorage: Bool { require(permissions: "s3/read/directory") }
  var canInstall: Bool { require(permissions: "launcher/app/create") }
  struct HostApi {
    let hub: Hub
    @MainActor
    var canManage: Bool { hub.require(permissions: "hub/host/update") }
    func allow(key: String, paths: [String]) async throws {
      guard !paths.isEmpty else { return }
      try await update(key: key, allow: paths)
    }
    private func update(key: String, allow: [String]? = nil, revoke: [String]? = nil) async throws {
      try await hub.client.send("hub/host/update", UpdateApi(key: key, allow: allow, revoke: revoke))
    }
    struct UpdateApi: Encodable {
      let key: String, allow: [String]?, revoke: [String]?
    }
  }
  var canLockdown: Bool { require(permissions: "hub/whitelist") }
  func lockdown(_ lockdown: SetLockdown) async throws {
    try await client.send("hub/whitelist", lockdown)
  }
  struct User: Hashable, Decodable, Identifiable {
    var id: String
    var key: String?
    var services: Int
    var name: String
    var icon: Icon
    var apps: Int
    enum CodingKeys: CodingKey {
      case id, key, services, apps, permissions, name, icon
    }
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(.id)
      key = container.decodeIfPresent(.key)
      services = container.decodeIfPresent(.services, 0)
      apps = container.decodeIfPresent(.apps, 0)
      name = container.decodeIfPresent(.name, "")
      icon = container.decodeIfPresent(.icon) ?? Icon(symbol: .init(name: "hexagon"))
    }
  }
  
  func isMerged(to hub: Hub) -> Bool {
    var addresses = Set<String>()
    return isMerged(address: settings.address.absoluteString, addresses: &addresses)
  }
  private func isMerged(address: String, addresses: inout Set<String>) -> Bool {
    for status in state.merge.value {
      guard addresses.insert(status.address).inserted else { continue }
      guard let hub = Hubs.main.list.first(where: { $0.settings.address.absoluteString == status.address })
      else { continue }
      guard hub.isMerged(address: address, addresses: &addresses) else { continue }
      return true
    }
    return false
  }
  func addOwner(_ key: String) async throws {
    try await client.send("auth/keys/add", KeyAdd(key: key, type: .key, permissions: ["owner"]))
  }
  func add(key: String, group: String) async throws {
    try await client.send("hub/group/update/users", EditGroupUsers(group: group, add: [key], remove: nil))
  }
  func merge(other: Hub) async throws {
    let key: String = try await client.send("hub/key")
    try await other.client.send("auth/keys/add", KeyAdd(key: key, type: .key, permissions: ["merge"]))
    try await client.send("hub/merge/add", other.settings.address.absoluteString)
  }
  func unmerge(other: Hub) async throws {
    let key: String = try await client.send("hub/key")
    try await other.client.send("auth/keys/remove", key)
    try await client.send("hub/merge/remove", other.settings.address.absoluteString)
  }
  struct KeyAdd: Encodable {
    enum KeyType: String, Encodable {
      case key, hmac
    }
    let key: String
    let type: KeyType
    let permissions: [String]
  }
  struct EditGroupUsers: Encodable {
    let group: String, add: [String]?, remove: [String]?
  }
  struct MergeStatus: Decodable, Equatable {
    let address: String
    let error: String?
    let isConnected: Bool
  }
  struct StatusBadges: Decodable {
    var services: Int = 0
    var connections: Int?
    var security: Int?
    var apps: [AppHeader]?
  }
  struct AppHeader: Identifiable, Hashable, Decodable {
    var id: String { path }
    var name: String
    var path: String
    var services: Int?
    var isOnline: Bool { (services ?? 1) != 0 }
  }
}
