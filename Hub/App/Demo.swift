//
//  Demo.swift
//  Hub
//
//  `--demo` (Debug): ten hubs as the design boards draw them, filled from fixtures instead of a connection, to check
//  layouts with many hubs, long lists and every state. Their addresses don't resolve, so nothing is sent anywhere.
//

#if DEBUG
import Foundation
import HubService

@MainActor
enum HubDemo {
  static let isOn = ProcessInfo.processInfo.arguments.contains("--demo")

  static func hubs() -> [Hub] {
    // `--demo --empty`: no hubs yet, the welcome
    guard !ProcessInfo.processInfo.arguments.contains("--empty") else { return [] }
    return [
      hub("Home", services: 102, role: "owners", host: "studio-mac.local", security: 2, apps: [
        app("Pulse", "waveform.path.ecg", widget: ["2x1", "1x1"]), app("Weather", "cloud.sun"), app("Tasks", "checklist"),
        app("Monitor", nil), app("Fleet Control", "point.3.connected.trianglepath.dotted"), app("Pulse Admin", nil, web: true),
      ], devices: 6, pending: 1, launcher: [("Hub", true, false), ("Ollama Service", true, true), ("Files", true, false), ("Login with Apple", true, false), ("Apple Push Notifications", false, false), ("Hasher", true, false)]),
      hub("Studio", services: 70, role: "owners", security: 3, apps: [app("Tasks", "checklist"), app("Monitor", nil)],
          devices: 7, pending: 1, launcher: [("Build Server", true, false), ("Ollama", true, true), ("S3 Local", false, false)]),
      hub("Lab", services: 64, role: "owners", apps: [
        app("Sensors", "sensor"), app("Home Assistant", "house"), app("Zigbee2MQTT", nil), app("Weather", "cloud.sun"),
        app("Flaky Error", nil, online: false), app("Flaky Live", nil, online: false),
      ], devices: 4),
      hub("Office", services: 42, role: "admins", apps: [app("Office", nil), app("Storage", "cylinder")], devices: 212),
      hub("Loop", services: 32, role: "owners", apps: [app("Loop Ops", nil), app("Loop Admin", nil)], devices: 3),
      hub("Vijo Hub", services: 0, role: nil, reach: .connecting),
      hub("Frankfurt", services: 4, role: "family", apps: [app("Files", "folder"), app("Photos", "photo")], devices: 2),
      hub("Parents", services: 1, role: "family", security: 1, apps: [app("Photos", "photo")], devices: 1),
      hub("Garage Pi", services: 0, role: nil, reach: .offline),
      hub("Playground", services: 0, role: nil, reach: .offline),
    ]
  }

  private static func app(_ name: String, _ icon: String?, widget: [String]? = nil, web: Bool = false, online: Bool = true) -> [String: Any] {
    var header: [String: Any] = ["type": "app", "name": name, "path": name.lowercased().replacingOccurrences(of: " ", with: "-") + "/app"]
    if let icon { header["icon"] = icon }
    if let widget { header["widget"] = ["sizes": widget] }
    if web { header["web"] = ["url": "http://{hubHost}:8090/"] }
    header["services"] = online ? 1 : 0
    return header
  }

  private static func hub(
    _ name: String, services: Int, role: String?, host: String? = nil, security: Int = 0, apps: [[String: Any]] = [],
    devices: Int = 0, pending: Int = 0, launcher: [(String, Bool, Bool)] = [], reach: Reach = .online
  ) -> Hub {
    let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
    let hub = Hub(settings: .init(name: name, address: URL(string: "ws://\(host.map { $0.replacingOccurrences(of: ".local", with: "") } ?? slug).demo.invalid:1997")!))
    hub.isDemo = true
    hub.isConnected = reach == .online
    hub.isUnreachable = reach == .offline
    guard reach == .online else { return hub }
    hub.api = Set(allPaths)
    let state = hub.state
    var users: [[String: Any]] = [["id": "me", "key": hub.key, "name": KitDemoNames.thisDevice, "services": 0, "apps": 0, "group": role as Any]]
    for index in 0..<min(services, 8) {
      users.append(["id": "u\(index)", "key": "MCowBQYDK2VwAyEA\(index)demo\(slug)", "name": userNames[index % userNames.count], "services": index % 3 + 1, "apps": index % 2, "group": ["owners", "family", "services"][index % 3]])
    }
    load(state.users, users)
    load(state.statusBadges, ["services": services, "security": security, "apps": apps])
    load(state.status, ["requests": 4812, "services": serviceStatus(count: services)])
    load(state.groups, ["owners": ["s3/read", "s3/write", "llm/list"], "family": ["s3/read", "llm/list"], "services": ["s3/read"]])
    load(state.permissions, ["s3/read": "Files: Read files", "s3/list": "Files: List folders", "s3/write": "Files: Write files", "llm/list": "Language models: List models", "text/llm": "Language models: Chat"])
    load(state.whitelist, ["enabled": false, "users": [hub.key]])
    if security > 0 {
      load(state.hostPending, ["MCowBQYDK2VwAyEAlmstudio\(slug)": ["llm/list", "llm/chat"], "MCowBQYDK2VwAyEAapns\(slug)": ["apns/send", "apns/send/many"]].prefix(security).reduce(into: [String: [String]]()) { $0[$1.key] = $1.value })
    }
    load(state.devices, (0..<devices).map { device($0, slug: slug) })
    if name == "Home" { network(hub) }
    load(state.pendingDevices, (0..<pending).map { ["id": "pending\($0)", "key": "pendingkey\($0)\(slug)", "name": "Gaming PC", "platform": "windows", "safetyCode": "728 621"] })
    if !launcher.isEmpty {
      load(state.launcherInfo, ["apps": launcher.map { ["name": $0.0, "active": $0.1, "restarts": true, "updateAvailable": $0.2, "instances": 1] }])
      load(state.launcherStatus, ["apps": launcher.enumerated().map { index, app in
        app.1 ? ["name": app.0, "processes": [["pid": 100 + index, "cpu": Double(index * 7 % 50), "memory": Double(48 + index * 210)]]] : ["name": app.0]
      }])
    }
    return hub
  }

  enum Reach { case online, connecting, offline }

  private static let userNames = ["studio-mac", "hub-launcher", "maya-iphone", "Rafael’s MacBook Air", "Aiko’s iPad", "Ollama Service", "LM Studio", "Files"]
  private static let platforms = ["macos", "linux", "macos", "macos", "linux", "android", "ios", "ipados", "windows", "tvos"]
  private static let deviceNames = ["Mac Studio", "build-runner", "Dmitry’s MacBook Pro", "MacBook Air", "NAS", "Pixel 9", "Aiko’s iPhone", "Jonas’s iPad Pro", "Rafael’s Dell XPS", "Meeting Room"]

  private static func device(_ index: Int, slug: String) -> [String: Any] {
    let name = index < deviceNames.count ? deviceNames[index] : "\(deviceNames[index % deviceNames.count]) \(index / deviceNames.count + 1)"
    return [
      "id": "dev\(index)\(slug)", "key": "devkey\(index)\(slug)", "name": name, "platform": platforms[index % platforms.count],
      "os": index % 2 == 0 ? "27.0" : "6.8", "approved": true, "revoked": false, "online": index % 7 != 6,
      "services": (0..<(index % 4)).map { ["key": "svc\($0)", "instance": "i\($0)", "name": "service \($0)", "online": true, "paths": ["s3/read"]] },
    ]
  }

  private static func serviceStatus(count: Int) -> [[String: Any]] {
    let paths = ["llm/list", "text/llm", "s3/read", "s3/list", "s3/write", "s3/read/directory", "s3/size", "s3/delete", "image/encode",
                 "image/sensitive", "video/encode/hevc", "apns/send", "apns/send/many", "apple/login", "launcher/info"]
    return paths.prefix(max(0, min(count, paths.count))).enumerated().map { index, path in
      ["name": path, "services": path.hasPrefix("apns") ? 0 : index % 3 + 1, "requests": [1987, 412, 1204, 640, 388, 96, 30, 12, 312, 41, 18, 0, 0, 5, 9][index],
       "running": index == 0 ? 1 : 0, "pending": index == 10 ? 3 : 0, "balancer": index == 1 ? "available" : "counter"]
    }
  }

  private static let allPaths = [
    "hub/connections", "hub/devices", "hub/devices/data", "hub/device/approve", "hub/security/mode", "hub/host/pending", "hub/host/update",
    "hub/group/list", "hub/group/names", "hub/group/update", "hub/group/update/users", "hub/whitelist", "hub/whitelist/status",
    "hub/status", "hub/status/badges", "launcher/info", "launcher/status", "s3/read/directory", "hub/merge/add",
  ]

  // MARK: Hub Network

  /// The agent key of this device on the demo's networks
  static let thisAgentKey = "agent-studio-mac"

  /// Home's network as the hub-net boards draw it: this Mac, home-nas sharing its internet and two apps, a phone, a PC
  /// this Mac can't reach, an asleep laptop, and two more devices that share their internet. `--demo-net 100`: that
  /// many devices, for the map's rings and the list. `--demo-net-off`: this Mac's network is off.
  static func network(_ hub: Hub) {
    let arguments = ProcessInfo.processInfo.arguments
    let count = arguments.firstIndex(of: "--demo-net").flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 0
    var devices: [(name: String, platform: String, state: String, gateway: Bool, apps: [(String, Int, String?)])] = [
      ("studio-mac", "macos", "online", false, []),
      ("home-nas", "linux", "online", true, [("photos", 2342, nil), ("jellyfin", 8096, "family")]),
      ("maya-iphone", "ios", "online", false, []),
      ("gaming-pc", "windows", "unreachable", false, [("steam-link", 27036, nil)]),
      ("old-macbook", "macos", "asleep", false, []),
      ("fra-vps", "linux", "online", true, []),
      ("office-mini", "macos", "online", true, [("files", 8384, nil), ("notes", 3000, nil), ("print", 631, nil)]),
      ("parents-pi", "linux", "asleep", true, []),
    ]
    let extra = ["lab-runner", "kiosk-lobby", "pixel", "ipad", "nas", "printer", "tv", "build", "camera", "sensor"]
    for index in devices.count..<max(devices.count, count) {
      let name = "\(extra[index % extra.count])-\(String(format: "%02d", index / extra.count + 1))"
      let state = index % 33 == 0 ? "unreachable" : index % 9 == 0 ? "asleep" : "online"
      devices.append((name, ["linux", "macos", "ios", "android"][index % 4], state, false, []))
    }
    let now = Date()
    var agents = [[String: Any]](), statuses = [[String: Any]](), gateways = [[String: Any]](), resources = [[String: Any]]()
    var providers = [String: [HubNetworkProvider]]()
    for (index, device) in devices.enumerated() {
      let key = index == 0 ? thisAgentKey : "agent-\(device.name)"
      let address = "100.96.\(index / 250).\(index % 250 + 2)"
      let seen = ISO8601DateFormatter.js.string(from: now.addingTimeInterval(device.state == "asleep" ? -26 * 3600 : -60))
      agents.append([
        "version": 1, "key": key, "wireGuardKey": "wg-\(device.name)", "name": device.name, "platform": device.platform,
        "overlayAddresses": [address, "fd48:5542:4e45::\(index + 2)"], "connectedAt": seen, "online": device.state != "asleep",
      ])
      statuses.append([
        "version": 1, "key": key, "available": device.state != "asleep", "addresses": [address], "peers": 3,
        "shares": device.apps.count, "updatedAt": seen,
      ])
      if device.gateway {
        gateways.append([
          "version": 1, "hubNetworkId": "home", "key": key, "wireGuardKey": "wg-\(device.name)", "endpoint": "203.0.113.\(index):51820",
          "capability": ["version": 1, "capability": "internet-gateway-v1", "ipv4": true, "ipv6": device.name != "home-nas", "dns": true,
                         "metered": device.name == "office-mini", "updatedAt": seen],
          "state": device.state == "asleep" ? "unavailable" : "available", "updatedAt": seen,
        ])
      }
      for app in device.apps {
        let id = "res-\(device.name)-\(app.0)"
        resources.append([
          "version": 1, "resourceId": id, "ownerKey": key, "shareName": app.0, "authority": "\(app.0).\(device.name).hub.invalid:\(app.1)",
          "policy": ["mode": app.2 == nil ? "hub" : "group", "group": app.2 as Any], "generation": 1,
        ])
        providers[id] = [HubNetworkProvider(version: 1, providerId: "p-\(id)", resourceId: id, serviceKey: key, key: key, protocol: .tcp,
                                            overlayAddress: address, port: UInt16(app.1), connectedAt: seen)]
      }
      if device.state == "unreachable" { NetworkLinks.main.mark(key, unreachable: true, since: now.addingTimeInterval(-240)) }
    }
    // This Mac's own shares
    for (port, policy) in [(5432, "family"), (8096, nil as String?)] {
      resources.append([
        "version": 1, "resourceId": "res-mine-\(port)", "ownerKey": hub.key, "shareName": "tcp-\(port)",
        "authority": "tcp-\(port).studio-mac.hub.invalid:\(port)", "policy": ["mode": policy == nil ? "hub" : "group", "group": policy as Any],
        "generation": 1,
      ])
    }
    load(hub.state.networkAgents, agents)
    load(hub.state.networkAgentStatus, statuses)
    load(hub.state.networkGateways, gateways)
    load(hub.state.networkResources, resources)
    hub.state.hubNetNode.value = "wss://v57.dev:1964"
    load(hub.state.networkLocalAgent, [
      "version": 1, "state": "available", "capabilities": [String](), "connected": true, "bootstrapCapable": true,
      "updatedAt": ISO8601DateFormatter.js.string(from: now),
    ])
    NetworkProviders.main.providers.merge(providers) { $1 }
    hub.api.formUnion([
      "network/resource/list", "network/agents/list", "network/status/agents", "network/gateway/list", "network/gateway/grant",
      "network/gateway/advertise", "network/gateway/remove", "network/resource/update", "network/resource/revoke",
      "hub/net/node", "hub/net/node/set", "hub/net/list", "hub/net/local-agent",
    ])
    let joined = !arguments.contains("--demo-net-off")
    hub.net.demo(joined: joined, address: .init(ipv4: "100.96.0.2", ipv6: "fd48:5542:4e45::2"), tcp: joined ? [5432, 8096] : [])
    if joined, !arguments.contains("--demo-net-own") {
      hub.net.demo(vpn: .some(hub.net.devices.first { $0.key == "agent-home-nas" }))
      NetworkRecents.main.use("agent-home-nas", hub: hub, internet: true)
    }
  }

  /// `--demo-net-join`: a device joins Home's network while Add a Device is open
  static func join(_ name: String, platform: String, hub: Hub) {
    let seen = ISO8601DateFormatter.js.string(from: Date())
    let index = hub.state.networkAgents.value.count
    let address = "100.96.\(index / 250).\(index % 250 + 2)"
    let agents = hub.state.networkAgents, statuses = hub.state.networkAgentStatus
    append(agents, [
      "version": 1, "key": "agent-\(name)", "wireGuardKey": "wg-\(name)", "name": name, "platform": platform,
      "overlayAddresses": [address], "connectedAt": seen, "online": true,
    ])
    append(statuses, ["version": 1, "key": "agent-\(name)", "available": true, "addresses": [address], "peers": 1, "shares": 0, "updatedAt": seen])
  }

  private static func append<T: Decodable & Sendable>(_ sync: HubStateStorage.Sync<[T]>, _ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]), let items = try? JSONDecoder().decode([T].self, from: data) else { return }
    sync.value += items
  }

  /// Who may use one of the demo's shared apps
  static func setPolicy(_ policy: HubNetworkPolicy, share: String, hub: Hub) {
    hub.state.networkResources.value = hub.state.networkResources.value.map { resource in
      guard resource.shareName == share || resource.resourceId == share else { return resource }
      return HubNetworkResource(version: resource.version, resourceId: resource.resourceId, ownerKey: resource.ownerKey,
                                shareName: resource.shareName, authority: resource.authority, policy: policy,
                                generation: resource.generation + 1)
    }
  }

  private static func load<T: Decodable & Sendable>(_ sync: HubStateStorage.Sync<T>, _ value: Any) {
    do {
      let data = try JSONSerialization.data(withJSONObject: value)
      sync.value = try JSONDecoder().decode(T.self, from: data)
    } catch {
      print("Demo fixture for \(sync.path): \(error)")
    }
  }
}

private enum KitDemoNames {
  static let thisDevice = "This Mac"
}
#endif
