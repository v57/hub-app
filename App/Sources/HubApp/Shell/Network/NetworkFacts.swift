//
//  NetworkFacts.swift
//  Hub
//
//  One hub's network in plain words: this device's state, the other devices with a status people understand (Online,
//  Asleep, Can't reach right now), what each one shares, and who may use it.
//

#if canImport(ComponentKit)
import SwiftUI
import ComponentKit
import HubService
import Channel

/// A device on a hub's network, as the Network page, its overlays and the sidebar card show it
struct NetDevice: Identifiable, Hashable {
  enum Status: Hashable {
    case thisDevice, online, asleep, cantReach
    /// This device's network is off, so nothing can be reached
    case off
  }
  /// The device's network agent key
  let id: String
  var name: String
  var platform: String?
  var status: Status
  /// When it was last online, for an asleep device
  var seen: Date?
  /// The internet it offers, while it offers it
  var gateway: GatewayStatus?
  var apps: [NetApp] = []
  /// Its Hub Network address, for Copy Address
  var address: String?
  /// Since when this device can't link to it
  var unreachableSince: Date?

  var isThisDevice: Bool { status == .thisDevice }
  var sharesInternet: Bool { gateway?.state == .available }
  var symbol: String { Device.symbol(platform: platform) }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.status == rhs.status && lhs.apps == rhs.apps
      && lhs.sharesInternet == rhs.sharesInternet
  }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }

  /// Its status in a few words: "Online", "Asleep · seen yesterday", "Can't reach right now"
  @MainActor var statusLine: String {
    switch status {
    case .thisDevice: "This \(KitDevice.name)"
    case .online: "Online"
    case .asleep: seen.map { "Asleep · seen \($0.formatted(.relative(presentation: .named)))" } ?? "Asleep"
    case .cantReach: "Can’t reach right now"
    case .off: "Turn on to reach it"
    }
  }
  var hue: Hue {
    switch status {
    case .thisDevice, .online: .green
    case .asleep, .off: .gray
    case .cantReach: .orange
    }
  }
  /// "2 apps"
  var appsLine: String? {
    apps.isEmpty ? nil : apps.count == 1 ? "1 app" : "\(apps.count) apps"
  }
}

/// An app a device shares on the network: one of its ports, with who may use it
struct NetApp: Identifiable, Hashable {
  /// The share's name, `tcp-5432`
  let id: String
  var name: String
  var port: Int?
  var policy: HubNetworkPolicy?
  var resource: HubNetworkResource?

  /// "Family can use it · port 5432"
  func line(hub: String) -> String {
    [policy.map { $0.whoCanUse(hub: hub) }, port.map { "port \($0)" }].compactMap { $0 }.joined(separator: " · ")
  }
}

extension HubNetworkPolicy {
  /// Who may use a shared app, in the words of the access menu
  func accessName(hub: String) -> String {
    switch mode {
    case .hub: "Everyone in \(hub)"
    case .group: (group ?? "A group").capitalized
    case .keys: keys?.count == 1 ? "1 person" : "\(keys?.count ?? 0) people"
    case .private: "Only Me"
    case .disabled: "No one"
    }
  }
  /// The line under a shared app: "Family can use it", "Everyone in Home"
  func whoCanUse(hub: String) -> String {
    switch mode {
    case .hub: "Everyone in \(hub)"
    case .group, .keys: "\(accessName(hub: hub)) can use it"
    case .private: "Only you"
    case .disabled: "No one can use it"
    }
  }
}

/// What a hub's network is like from this device, read from its live state: one per view, under `.hub(hub)`
@MainActor
struct NetworkFacts: DynamicProperty {
  @Environment(Hub.self) var hub
  @HubState(\.networkAgents) var agents
  @HubState(\.networkAgentStatus) var statuses
  @HubState(\.networkGateways) var gateways
  @HubState(\.networkResources) var resources
  @HubState(\.networkLocalAgent) var localAgent
  @HubState(\.devices) var hubDevices
  @State private var links = NetworkLinks.main
  @State private var names = NetworkAppNames.main
  @State private var used = NetworkRecents.main

  init() {}

  var isJoined: Bool { hub.net.isJoined }

  /// Why the hub's network can't be joined now: the hub's machine runs no network agent. `nil` while it runs.
  var hubNetworkOff: Bool {
    guard !hub.isOnHubMachine, hub.api.contains("hub/net/local-agent"), !localAgent.updatedAt.isEmpty else { return false }
    if localAgent.key == hub.key { return true }
    return localAgent.state != .available
  }

  /// Every device on the network, this one first, then by name
  var devices: [NetDevice] {
    let keys = Set(agents.map(\.key) + statuses.map(\.key))
    return keys.map(device).sorted {
      ($0.isThisDevice ? 0 : 1, $0.name.lowercased()) < ($1.isThisDevice ? 0 : 1, $1.name.lowercased())
    }
  }

  /// The other devices
  var others: [NetDevice] { devices.filter { !$0.isThisDevice } }

  var thisDevice: NetDevice? { devices.first(where: \.isThisDevice) }

  /// This device's name on the network: "studio-mac"
  var thisName: String { thisDevice?.name ?? "This \(KitDevice.name)" }

  /// Devices that offer their internet, the one in use first
  var internetDevices: [NetDevice] {
    others.filter { $0.gateway != nil }
  }

  /// The device whose internet this device uses
  var usingInternet: NetDevice? {
    guard let vpn = hub.net.vpn else { return nil }
    return others.first { $0.id == vpn.key || $0.gateway?.key == vpn.key }
  }

  /// The device whose internet this device used last, which the sidebar card lists first even when it's offline
  var lastInternet: NetDevice? {
    if let usingInternet { return usingInternet }
    guard let key = used.lastInternet(hub: hub) else { return nil }
    return others.first { $0.id == key || $0.gateway?.key == key }
  }

  /// The devices used last, for the Recent tiles of a big network
  var recent: [NetDevice] {
    let times = used.times(hub: hub)
    return others.sorted { (times[$0.id] ?? 0) > (times[$1.id] ?? 0) }
  }

  /// What this device shares: its shared ports, named after the apps behind them
  var sharedApps: [NetApp] {
    let ports = hub.net.sharedTcp.map { ("tcp", $0) } + hub.net.sharedUdp.map { ("udp", $0) }
    return ports.sorted { $0.1 < $1.1 }.map { kind, port in
      let id = "\(kind)-\(port)"
      let resource = resources.first { $0.shareName == id && $0.ownerKey == hub.key }
      return NetApp(id: id, name: names.name(port: port), port: port, policy: resource?.policy, resource: resource)
    }
  }

  private func device(_ key: String) -> NetDevice {
    let agent = agents.first { $0.key == key }
    let status = statuses.first { $0.key == key }
    let hubDevice = agent?.deviceId.flatMap { id in hubDevices.first { $0.id == id } }
    let isThis = isThisDevice(key, agent: agent)
    let online = status?.available ?? agent?.online ?? true
    let unreachable = links.unreachable[key]
    let state: NetDevice.Status =
      isThis ? .thisDevice
      : !isJoined ? .off
      : !online ? .asleep
      : unreachable != nil ? .cantReach
      : .online
    let gateway = gateways.first { $0.key == key && $0.state != .disabled }
      ?? agent?.deviceId.flatMap { device in
        gateways.first { gateway in gateway.state != .disabled && agents.contains { $0.key == gateway.key && $0.deviceId == device } }
      }
    var apps = [NetApp]()
    if isThis {
      apps = sharedApps
    } else {
      let addresses = Set(agent?.overlayAddresses ?? [])
      for resource in resources {
        let providers = NetworkProviders.main.providers[resource.resourceId] ?? []
        guard providers.contains(where: { $0.key == key || addresses.contains($0.overlayAddress) }) else { continue }
        let port = providers.first.map { Int($0.port) }
        apps.append(NetApp(id: resource.resourceId, name: names.name(share: resource.shareName, port: port), port: port, policy: resource.policy, resource: resource))
      }
    }
    return NetDevice(
      id: key,
      name: hubDevice?.name ?? agent?.displayName ?? String(key.prefix(8)),
      platform: hubDevice?.platform ?? agent?.platform,
      status: state,
      seen: hubDevice?.lastSeen ?? status.flatMap { HubNet.date(from: $0.updatedAt) },
      gateway: gateway,
      apps: apps,
      address: (status?.addresses ?? agent?.overlayAddresses ?? []).first { !$0.contains(":") },
      unreachableSince: unreachable
    )
  }

  private func isThisDevice(_ key: String, agent: HubNetworkAgent?) -> Bool {
#if DEBUG
    if hub.isDemo { return key == HubDemo.thisAgentKey }
#endif
    if hub.isOnHubMachine, let local = localAgent.key, local == key { return true }
    guard let device = agent?.deviceId else { return false }
    return device == hub.client.device?.key.id
  }
}

/// Which devices this device can't link to: the tunnel keeps trying them without a handshake. Polled while a page
/// that shows device statuses is open (`.networkLinksPolling()`).
@MainActor @Observable
final class NetworkLinks {
  static let main = NetworkLinks()
  /// Agent keys, and since when each one can't be reached
  private(set) var unreachable: [String: Date] = [:]
  @ObservationIgnored private var watchers = 0

  private struct Status: Decodable {
    struct Peer: Decodable {
      let key: String
      let attempting: Bool
      let lastHandshake: Date?
    }
    let peers: [Peer]
  }

  /// Polls every 5 s until the calling task ends
  func poll() async {
    watchers += 1
    defer { watchers -= 1 }
    while !Task.isCancelled {
      await check()
      try? await Task.sleep(for: .seconds(5))
    }
  }

  /// Marks a device unreachable now, for "Try Again" that didn't help, and for the demo
  func mark(_ key: String, unreachable isUnreachable: Bool, since: Date = Date()) {
    unreachable[key] = isUnreachable ? (unreachable[key] ?? since) : nil
  }

  private func check() async {
#if DEBUG
    guard !HubDemo.isOn else { return }
#endif
    guard let tunnel = try? PacketTunnelController(), let data = try? await tunnel.linkStatus(),
          let status = try? JSONDecoder().decode(Status.self, from: data) else { return }
    let now = Date()
    var next = [String: Date]()
    for peer in status.peers {
      // A WireGuard handshake renews every two minutes on a live link
      let stale = peer.lastHandshake.map { now.timeIntervalSince($0) > 180 } ?? true
      if peer.attempting && stale {
        next[peer.key] = unreachable[peer.key] ?? now
      }
    }
    if next != unreachable { unreachable = next }
  }
}

/// The devices behind each shared app (`network/providers/list`), while a page that lists apps is open
@MainActor @Observable
final class NetworkProviders {
  static let main = NetworkProviders()
  var providers: [String: [HubNetworkProvider]] = [:]

  private struct Request: Encodable, Hashable, Sendable { let resourceId: String }

  /// Streams the providers of every resource until the calling task ends
  func watch(hub: Hub, resources: [HubNetworkResource]) async {
    guard hub.api.contains("network/providers/list"), !hub.isDemo else { return }
    let tasks = resources.map { resource in
      Task { await self.stream(hub: hub, resourceId: resource.resourceId) }
    }
    await withTaskCancellationHandler {
      for task in tasks { await task.value }
    } onCancel: {
      for task in tasks { task.cancel() }
    }
  }

  private func stream(hub: Hub, resourceId: String) async {
    do {
      for try await list: [HubNetworkProvider] in hub.client.values("network/providers/list", Request(resourceId: resourceId)) {
        providers[resourceId] = list
      }
    } catch {}
  }
}

/// The names people gave the apps they share, by port, and the names of well-known ports
@MainActor @Observable
final class NetworkAppNames {
  static let main = NetworkAppNames()
  private var named: [String: String] = UserDefaults.standard.dictionary(forKey: "network.appNames") as? [String: String] ?? [:]

  func name(port: Int) -> String {
    named[String(port)] ?? KnownPorts.app(port)?.name ?? "Port \(port)"
  }
  func name(share: String, port: Int?) -> String {
    if let port { return name(port: port) }
    return share
  }
  func set(_ name: String, port: Int) {
    named[String(port)] = name
    UserDefaults.standard.set(named, forKey: "network.appNames")
  }
}

/// When this device last used each device (its internet, its apps), per hub: the Recent tiles and the sidebar card's
/// first row
@MainActor @Observable
final class NetworkRecents {
  static let main = NetworkRecents()
  private var used: [String: [String: Double]] = UserDefaults.standard.dictionary(forKey: "network.used") as? [String: [String: Double]] ?? [:]
  private var internet: [String: String] = UserDefaults.standard.dictionary(forKey: "network.lastInternet") as? [String: String] ?? [:]

  func times(hub: Hub) -> [String: Double] { used[hub.settings.address.absoluteString] ?? [:] }
  func lastInternet(hub: Hub) -> String? { internet[hub.settings.address.absoluteString] }

  func use(_ key: String, hub: Hub, internet usesInternet: Bool = false) {
    let id = hub.settings.address.absoluteString
    used[id, default: [:]][key] = Date().timeIntervalSince1970
    UserDefaults.standard.set(used, forKey: "network.used")
    if usesInternet {
      internet[id] = key
      UserDefaults.standard.set(internet, forKey: "network.lastInternet")
    }
  }
}

/// Apps people run on well-known ports, to name a shared port and the apps found listening
enum KnownPorts {
  struct App: Hashable {
    let name: String
    /// "Database", "Media server"
    let kind: String
  }
  static func app(_ port: Int) -> App? { table[port] }

  static let table: [Int: App] = [
    22: App(name: "SSH", kind: "Remote login"),
    80: App(name: "Web server", kind: "Website"),
    443: App(name: "Web server", kind: "Secure website"),
    445: App(name: "File Sharing", kind: "Shared folders"),
    631: App(name: "Printer Sharing", kind: "Printers"),
    1234: App(name: "LM Studio", kind: "Language models"),
    1883: App(name: "MQTT", kind: "Message broker"),
    2342: App(name: "Photos", kind: "Photo library"),
    3000: App(name: "Web app", kind: "Dev server"),
    3306: App(name: "MySQL", kind: "Database"),
    4000: App(name: "Web app", kind: "Dev server"),
    4200: App(name: "Angular", kind: "Web preview"),
    5000: App(name: "Web app", kind: "Dev server"),
    5173: App(name: "Vite", kind: "Web preview"),
    5432: App(name: "Postgres", kind: "Database"),
    5601: App(name: "Kibana", kind: "Dashboards"),
    5900: App(name: "Screen Sharing", kind: "Remote screen"),
    6006: App(name: "Storybook", kind: "Web preview"),
    6379: App(name: "Redis", kind: "Database"),
    8000: App(name: "Web app", kind: "Dev server"),
    8080: App(name: "Web app", kind: "Web server"),
    8086: App(name: "InfluxDB", kind: "Database"),
    8096: App(name: "Jellyfin", kind: "Media server"),
    8123: App(name: "Home Assistant", kind: "Smart home"),
    8384: App(name: "Syncthing", kind: "File sync"),
    8888: App(name: "Jupyter", kind: "Notebooks"),
    9000: App(name: "MinIO", kind: "File storage"),
    9090: App(name: "Prometheus", kind: "Monitoring"),
    9200: App(name: "Elasticsearch", kind: "Search"),
    11434: App(name: "Ollama", kind: "Language models"),
    19000: App(name: "Expo", kind: "App preview"),
    25565: App(name: "Minecraft", kind: "Game server"),
    27017: App(name: "MongoDB", kind: "Database"),
    32400: App(name: "Plex", kind: "Media server"),
  ]
}

extension View {
  /// Keeps the devices' reachability and the apps' providers current while this view shows
  func networkLive(_ facts: NetworkFacts) -> some View {
    task { await NetworkLinks.main.poll() }
      .task(id: facts.resources.map(\.resourceId)) {
        await NetworkProviders.main.watch(hub: facts.hub, resources: facts.resources)
      }
  }
}
#endif
