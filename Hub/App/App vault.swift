//
//  App vault.swift
//  Hub
//
//  The v57 vault (v57/Vault) the Hub app shares with every v57 app: its hubs are the vault's Hub records, turned on
//  for this device, and it holds the Hub directory the Vault app holds otherwise. With the device key they share
//  (App device.swift), each connection writes which Hub device this machine is and mirrors every hub's devices into
//  the hosts Code, Git, Shell and the others read, so they reach the user's devices without the Vault app.
//

#if canImport(VaultHub)
import Foundation
import VaultHub
import VaultKit

@MainActor
enum AppVault {
  private static var directory: HubDirectory?

  /// Starts iCloud sync of the vault and the Hub directory, and turns the app's hubs on for this device
  static func start(hubs: [Hub.Settings]) {
    guard directory == nil else { return }
    let vault = Vault.shared
    guard vault.store != nil else { return }
    vault.startSync()
    // This device's SSH key (the Secure Enclave key the v57 apps share), for the user's machines to authorize
    try? vault.store?.publishDeviceKey()
    let directory = HubDirectory(vault: vault)
    self.directory = directory
    directory.start()
    for hub in hubs { add(hub) }
  }

  /// The hub joins the vault's records, turned on for this device
  static func add(_ settings: Hub.Settings) {
    _ = try? directory?.add(url: settings.address.absoluteString, name: settings.name)
  }

  /// This device stops connecting to the hub; the record stays for the user's other devices
  static func remove(_ settings: Hub.Settings) {
    guard let directory, let hub = record(of: settings) else { return }
    directory.setConnects(hub, false)
  }

#if DEBUG
  /// What the vault holds about hubs, devices and projects, for `--net-test vault`
  static func lines() -> [String] {
    let vault = Vault.shared
    var lines = ["device \(vault.deviceID) store=\(vault.store != nil) sync=\(vault.sync?.isRunning == true) pending=\((try? vault.store?.pendingCount()) ?? -1) error=\(vault.sync?.lastError ?? "-")"]
    for hub in vault.hubs {
      let status = directory?.connection(for: hub.id).map { "\($0.status)" } ?? "-"
      lines.append("hub \(hub.url) key=\(hub.hubKey?.suffix(8) ?? "-") connects=\(hub.connects.sorted()) members=\(hub.members) status=\(status)")
    }
    for host in vault.hosts where host.isViaHub {
      lines.append("host \(host.name) \(host.user)@\(host.hostname):\(host.port) hub=\(host.hub?.hubID ?? "-") device=\(host.hub?.deviceID ?? "-") vaultDevice=\(vault.vaultDevice(of: host) ?? "-")")
    }
    for project in vault.projects {
      lines.append("project \(project.name) on=\(project.paths.keys.sorted()) places=\(vault.otherPlaces(of: project).map { "\($0.deviceName):\($0.host?.hostname ?? "no host")" })")
    }
    for key in vault.deviceKeys { lines.append("deviceKey \(key.id) \(key.deviceName) \(key.publicKey.suffix(20))") }
    return lines
  }
#endif

  private static func record(of settings: Hub.Settings) -> VaultHubServer? {
    let url = HubDirectory.normalized(settings.address.absoluteString)
    return Vault.shared.hubs.first { HubDirectory.normalized($0.url) == url }
  }
}
#endif
