//
//  Reset.swift
//  Hub
//
//  `--reset` (Debug): wipes everything this app keeps on the device, so the next launch is a first launch, then
//  quits. Only the app itself may do this: its sandbox container, app group and Keychain group are closed to the
//  shell. Gone: the saved hubs and settings, the hub this device runs (Hub Server) and native joins, the app
//  group's files, every Keychain item in the app's access group, the per-hub identities and pins, and the Hub
//  Network VPN profile. What it removed is printed, so run the binary itself to read it:
//  `Hub.app/Contents/MacOS/Hub --reset`.
//

#if DEBUG
import Foundation
import Security
#if canImport(NetworkExtension) && !os(tvOS)
import NetworkExtension
#endif

@MainActor
enum HubReset {
  static let isRequested = ProcessInfo.processInfo.arguments.contains("--reset")

  static let appGroup = "group.dev.v57.hub"

  /// Wipes and quits. Runs before anything reads the Keychain or the saved hubs, so nothing writes them back.
  static func run() async {
    var report: [String] = []
    report += removeKeychainItems()
    report += removeDefaults()
    report += removeFiles()
    report += await removeVPNProfiles()
    for line in report { print("[HubReset] \(line)") }
    print("[HubReset] done")
    exit(0)
  }

  // MARK: Keychain

  private static var accessGroup: String? {
    (Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Every item in the app's access group, then the items the Mac keeps in the login keychain by service: the
  /// WireGuard key and the identities hubs joined with their own tag (`KeyChain.keychain(tag)`), with their pins.
  private static func removeKeychainItems() -> [String] {
    var removed: [String] = []
    if let accessGroup {
      for itemClass in [kSecClassGenericPassword, kSecClassKey, kSecClassInternetPassword, kSecClassCertificate] {
        let query: [String: Any] = [
          kSecClass as String: itemClass,
          kSecAttrAccessGroup as String: accessGroup,
          kSecUseDataProtectionKeychain as String: true,
        ]
        let services = services(matching: query)
        if SecItemDelete(query as CFDictionary) == errSecSuccess {
          removed += services.map { "Keychain \($0)" }
        }
      }
    }
    let tags = savedHubs().compactMap(\.identityTag)
    let legacy = [HubNetworkWireGuardKeyStore.service] + tags.flatMap { [$0, "\($0).hubs"] }
    for service in legacy {
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
      // The file-based keychain may delete one match per call
      var count = 0
      while count < 20, SecItemDelete(query as CFDictionary) == errSecSuccess { count += 1 }
      if count > 0 { removed.append("Keychain \(service) (login keychain)") }
    }
    return removed
  }

  /// The services of the items a query matches, one line each, for the report
  private static func services(matching query: [String: Any]) -> [String] {
    var search = query
    search[kSecMatchLimit as String] = kSecMatchLimitAll
    search[kSecReturnAttributes as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
          let items = result as? [[String: Any]] else { return [] }
    return items.map { item in
      let service = item[kSecAttrService as String] as? String ?? item[kSecAttrLabel as String] as? String ?? "item"
      let account = item[kSecAttrAccount as String] as? String
      return account.map { "\(service) / \($0)" } ?? service
    }
  }

  private static func savedHubs() -> [Hub.Settings] {
    guard let data = UserDefaults.standard.data(forKey: "hubs") else { return [] }
    return (try? JSONDecoder().decode([Hub.Settings].self, from: data)) ?? []
  }

  // MARK: Defaults and files

  /// Each key goes on its own and the change is saved before the app quits: a removed domain alone came back
  /// after `exit`.
  private static func removeDefaults() -> [String] {
    var removed: [String] = []
    func clear(_ defaults: UserDefaults, domain: String) {
      let keys = defaults.persistentDomain(forName: domain)?.keys.sorted() ?? []
      guard !keys.isEmpty else { return }
      for key in keys { defaults.removeObject(forKey: key) }
      defaults.removePersistentDomain(forName: domain)
      defaults.synchronize()
      removed.append("Settings \(domain): \(keys.joined(separator: ", "))")
    }
    if let bundle = Bundle.main.bundleIdentifier { clear(.standard, domain: bundle) }
    if let group = UserDefaults(suiteName: appGroup) { clear(group, domain: appGroup) }
    return removed
  }

  /// The container's own folders and the app group's files. Outside a sandbox these folders are the user's
  /// shared Library, so then only Hub's own entries in them go.
  private static func removeFiles() -> [String] {
    let files = FileManager.default
    var removed: [String] = []
    func remove(_ url: URL) {
      guard files.fileExists(atPath: url.path) else { return }
      do {
        try files.removeItem(at: url)
        removed.append(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
      } catch {
        removed.append("FAILED \(url.path): \(error.localizedDescription)")
      }
    }
    func contents(_ url: URL) -> [URL] {
      (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }
    let library = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let caches = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let documents = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
    if isSandboxed {
      for folder in [support, caches, documents, files.temporaryDirectory] + ["HTTPStorages", "WebKit", "Cookies",
          "Saved Application State"].map({ library.appendingPathComponent($0) }) {
        // A sandbox's Desktop, Downloads and the like are links out to the user's own folders: never followed
        guard !isLink(folder) else {
          removed.append("KEPT \(folder.path): a link to \(folder.resolvingSymlinksInPath().path)")
          continue
        }
        let items: [URL]
        do {
          items = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])
        } catch {
          if files.fileExists(atPath: folder.path) { removed.append("FAILED to list \(folder.path): \(error.localizedDescription)") }
          continue
        }
        for item in items {
          if isLink(item) {
            removed.append("KEPT \(item.path): a link to \(item.resolvingSymlinksInPath().path)")
          } else {
            remove(item)
          }
        }
      }
    } else {
      remove(support.appendingPathComponent("Hub Server", isDirectory: true))
      remove(support.appendingPathComponent("Hub", isDirectory: true))
      remove(documents.appendingPathComponent("hub.key"))
      if let bundle = Bundle.main.bundleIdentifier {
        remove(caches.appendingPathComponent(bundle))
        remove(library.appendingPathComponent("HTTPStorages/\(bundle)"))
      }
    }
    if let group = files.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
      // The system's own bookkeeping (`.com.apple.containermanagerd.metadata.plist`, Application Scripts) stays
      func isSystem(_ item: URL) -> Bool {
        item.lastPathComponent.hasPrefix(".com.apple.") || item.lastPathComponent == "Application Scripts"
      }
      for item in contents(group) where item.lastPathComponent != "Library" && !isSystem(item) { remove(item) }
      // The group's Library keeps the system's folders; only what's inside them goes
      for folder in contents(group.appendingPathComponent("Library")) where !isSystem(folder) {
        for item in contents(folder) { remove(item) }
      }
    }
    return removed
  }

  private static func isLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
  }

  private static var isSandboxed: Bool {
#if os(macOS)
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
#else
    true
#endif
  }

  // MARK: VPN

  private static func removeVPNProfiles() async -> [String] {
#if canImport(NetworkExtension) && !os(tvOS)
    guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences() else { return [] }
    var removed: [String] = []
    for manager in managers {
      do {
        try await manager.removeFromPreferences()
        removed.append("VPN profile \(manager.localizedDescription ?? "Hub Network")")
      } catch {
        removed.append("FAILED VPN profile: \(error.localizedDescription)")
      }
    }
    return removed
#else
    return []
#endif
  }
}
#endif
