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
    [
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
