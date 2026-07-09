//
//  Launcher.swift
//  Hub
//
//  Created by Dmitry Kozlov on 1/6/25.
//

#if canImport(SwiftCrossUI)
import SwiftCrossUI
#else
import SwiftUI
#endif
import HubService

struct UnknownValueError: Error { }

// Launcher api
extension Hub {
  var launcher: Launcher { Launcher(hub: self) }
  struct Launcher {
    let hub: Hub
    func app(id: String) -> AppApi {
      AppApi(hub: hub, id: id)
    }
    func create(_ create: Create) async throws {
      try await hub.client.send("launcher/app/create", create)
    }
    func checkForUpdates() async throws {
      try await hub.client.send("launcher/update/check/all")
    }
    func updateAll() async throws {
      try await hub.client.send("launcher/update/all")
    }
    func pro(_ key: String) async throws {
      try await hub.client.send("launcher/pro", key)
    }
    struct AppApi {
      let hub: Hub
      let id: String
      func stop() async throws {
        try await hub.client.send("launcher/app/stop", id)
      }
      func restart() async throws {
        try await hub.client.send("launcher/app/restart", id)
      }
      func start() async throws {
        try await hub.client.send("launcher/app/start", id)
      }
      func uninstall() async throws {
        try await hub.client.send("launcher/app/uninstall", id)
      }
      func updateSettings(_ settings: Hub.Launcher.AppSettings) async throws {
        try await hub.client.send("launcher/app/settings", UpdateSettings(app: id, settings: settings))
      }
    }
    struct Apps: Decodable, Hashable {
      var apps: [AppInfo] = []
    }
    struct Status: Decodable, Hashable {
      var apps: [String: AppStatus] = [:]
      enum CodingKeys: CodingKey {
        case apps
      }
      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let apps: [AppStatus] = try container.decode([AppStatus].self, forKey: CodingKeys.apps)
        for app in apps {
          self.apps[app.name] = app
        }
      }
      init() { }
    }
    struct AppInfo: Identifiable, Decodable, Hashable {
      var id: String { name }
      var name: String
      var active: Bool
      var restarts: Bool
      var updateAvailable: Bool
      var instances: Int
      var settings: AppSettings?
      enum CodingKeys: CodingKey {
        case name
        case active
        case restarts
        case updateAvailable
        case instances
        case settings
      }
      
      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(.name)
        active = container.decodeIfPresent(.active, false)
        restarts = container.decodeIfPresent(.restarts, false)
        updateAvailable = container.decodeIfPresent(.updateAvailable, false)
        instances = container.decodeIfPresent(.instances, 1)
        settings = container.decodeIfPresent(.settings)
      }
    }
    struct AppSettings: Codable, Hashable {
      var env: [String: String]?
      var secrets: [String: String]?
      init(env: [String : String]?, secrets: [String : String]?) {
        self.env = env
        self.secrets = secrets
      }
    }
    struct AppStatus: Decodable, Hashable {
      var name: String
      var checkingForUpdates: Bool?
      var updating: Bool?
      var crashes: Int?
      var totalCpu: Double? {
        processes?.lazy.compactMap(\.cpu).reduce(into: 0, +=)
      }
      var manyRunning: Bool {
        guard let processes, processes.count > 1 else { return false }
        var found = false
        for p in processes {
          if p.memory != nil {
            if found {
              return true
            } else {
              found = true
            }
          }
        }
        return false
      }
      var totalMemory: Double? {
        processes?.lazy.compactMap(\.memory).reduce(into: 0, +=)
      }
      var processes: [ProcessStatus]?
      var started: Date?
    }
    struct ProcessStatus: Decodable, Hashable, Identifiable {
      var id: Int { pid }
      var pid: Int
      var cpu: Double?
      var memory: Double?
    }
    struct Create: Codable {
      let name: String
      let active: Bool
      let restarts: Bool
      let setup: Setup
      let settings: AppSettings?
      
      private enum CodingKeys: CodingKey {
        case name, active, restarts, settings
      }
      init(name: String, active: Bool, restarts: Bool, setup: Setup, settings: AppSettings? = nil) {
        self.name = name
        self.active = active
        self.restarts = restarts
        self.setup = setup
        self.settings = settings
      }
      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(.name)
        active = try container.decode(.active)
        restarts = try container.decode(.restarts)
        setup = try Setup(from: decoder)
        settings = container.decodeIfPresent(.settings)
      }
      
      func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(active, forKey: .active)
        try container.encode(restarts, forKey: .restarts)
        try container.encodeIfPresent(settings, forKey: .settings)
        try setup.encode(to: encoder)
      }
    }
    enum Setup: Codable {
      case bun(Bun)
      struct Bun: Codable {
        let repo: String
        let commit: String?
        let command: String?
      }
      case sh(Sh)
      struct Sh: Codable {
        let directory: String?
        let install: [String]?
        let uninstall: [String]?
        let run: String
      }
      enum SetupType: String, Decodable {
        case bun, sh
      }
      
      private enum CodingKeys: CodingKey {
        case type
      }
      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type: SetupType = try container.decode(.type)
        switch type {
        case .bun:
          self = try .bun(.init(from: decoder))
        case .sh:
          self = try .sh(.init(from: decoder))
        }
      }
      
      func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bun(let bun):
          try container.encode("bun", forKey: .type)
          try bun.encode(to: encoder)
        case .sh(let sh):
          try container.encode("sh", forKey: .type)
          try sh.encode(to: encoder)
        }
      }
    }
    struct UpdateSettings: Encodable {
      let app: String
      let settings: Hub.Launcher.AppSettings
    }
  }
}

#if PRO
@Observable
class Launcher {
  static let main = Launcher()
  var isInstalled: Bool = false
  var status: Status
  enum Status {
    case installed, offline, running, stopping
    case notInstalled
    case status(LocalizedStringKey), downloadFailed, bunInstallationFailed, installationFailed
  }
  static var url: URL {
    URL.homeDirectory.appendingPathComponent("hub-launcher", conformingTo: .directory)
  }
  var url: URL { Launcher.url }
  var git: GitHub { GitHub(directory: url) }
  init() {
    if FileManager.default.fileExists(atPath: Launcher.url.path()) {
      status = .offline
    } else {
      status = .notInstalled
    }
  }
  private func installBunIfNeeded() async throws {
    if await !hasSh("bun") {
      status = .status("Installing Bun")
      try await sh("curl -fsSL https://bun.sh/install | bash")
    }
  }
  func install() async {
    status = .status("Downloading")
    do {
      try await git.clone("v57/hub-launcher")
    } catch {
      status = .downloadFailed
      return
    }
    status = .status("Installing")
    do {
      try await installBunIfNeeded()
    } catch {
      status = .bunInstallationFailed
      return
    }
    do {
      try await sh("""
cd hub-launcher
bun i
""")
    } catch {
      status = .installationFailed
      return
    }
    status = .installed
  }
  func launch() async {
    do {
      do {
        status = .status("Installing Bun")
        try await installBunIfNeeded()
      } catch {
        status = .status("Failed to install bun")
        return
      }
      status = .status("Launching")
      try await sh("""
if screen -ls | grep hub >/dev/null; then
  screen -X -S hub quit
fi
cd hub-launcher
screen -dmS hub bun .
""")
    } catch {
      status = .offline
    }
  }
  func stop(hub: Hub) async {
    do {
      status = .stopping
      _ = try await hub.client.send("launcher/stop") as Int?
    } catch {
      status = .offline
    }
  }
  func update() async {
    try? await git.pull()
  }
  func checkForUpdates() async -> Bool {
    await git.checkForUpdates()
  }
}
#endif
