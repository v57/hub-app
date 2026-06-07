//
//  Client.swift
//  Hub
//
//  Created by Dmitry Kozlov on 17/2/25.
//

import Foundation
import HubService
import Combine
import SwiftUI

extension KeyChain {
  static let main = KeyChain(keyChain: "dev.v57.hub")
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
  var api = Set<String>()
  var hasLauncher: Bool { require(permissions: "launcher/info") }
  
  @ObservationIgnored var appServices: AppServices!
  @ObservationIgnored var connectionTask: AnyCancellable?
  @ObservationIgnored var apiTask: AnyCancellable?
  @ObservationIgnored var state = HubStateStorage()
  
  init(settings: Settings) {
    self.settings = settings
    key = KeyChain.main.publicKey()
    self.client = HubClient(settings.address, keyChain: .main)
    connectionTask = client.isConnected.sink { [unowned self] isConnected in
      self.isConnected = isConnected
    }
    apiTask = Task {
      for try await api: Set<String> in client.values("hub/api") {
        EventDelayManager.main.execute {
          self.api = api
        }
      }
    }.cancellable()
    appServices = AppServices(hub: self)
  }
  struct Settings: Codable, Identifiable, Hashable {
    var id: URL { address }
    var name: String
    var address: URL
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
      guard selected != oldValue else { return }
      UserDefaults.standard.set(selected, forKey: "selected")
    }
  }
  var list = [Hub]()
  var selectedHub: Hub? {
    guard let selected else { return nil }
    return list.first(where: { $0.id == selected })
  }
  init() {
    if ProcessInfo.screenshotType != nil {
      list.append(.test)
      return
    }
    guard let data = UserDefaults.standard.data(forKey: "hubs") else { return }
    do {
      list = []
      for settings in try JSONDecoder().decode([Hub.Settings].self, from: data) {
        let hub = Hub(settings: settings)
        list.append(hub)
      }
      if let selected = UserDefaults.standard.url(forKey: "selected") {
        self.selected = selected
      }
    } catch {}
  }
  func select(_ hub: Hub.ID?) {
    selected = hub
  }
  func insert(with settings: Hub.Settings) {
    if let index = list.firstIndex(where: { $0.id == settings.id }) {
      list[index].settings = settings
    } else {
      let hub = Hub(settings: settings)
      list.append(hub)
    }
    selected = settings.id
    save()
  }
  func remove(with settings: Hub.Settings) {
    guard let index = self.list.firstIndex(where: { $0.id == settings.id }) else { return }
    if let selected, selected == settings.id {
      self.selected = list.first?.id
    }
    list[index].client.stop()
    list.remove(at: index)
    save()
  }
  func save() {
    do {
      let data = try JSONEncoder().encode(list.map(\.settings))
      UserDefaults.standard.set(data, forKey: "hubs")
    } catch { }
  }
}

extension Task {
  func cancellable() -> AnyCancellable {
    AnyCancellable {
      self.cancel()
    }
  }
}


extension View {
  func hub(_ hub: Hub) -> some View {
    environment(hub).environmentObject(hub.client)
  }
}
