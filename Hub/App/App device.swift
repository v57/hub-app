//
//  App device.swift
//  Hub
//
//  The Hub app is one device and its reporter (Docs/Devices/device-layer.md, section 10).
//

import Foundation
import HubService
import PlatformPower
import PlatformSystem
#if canImport(VaultHub)
import VaultHub
#endif
#if canImport(UIKit)
import UIKit
#endif

extension DeviceIdentity {
  /// The device key: the app's own (Keychain `dev.v57.Hub.device.v1`), which it also puts in the v57 keychain group
  /// for every v57 app (VaultHub's `HubKeyStore`), so the Hub app and the v57 apps are one device on a hub, with the
  /// app's approvals and Hub Network address. Without a key of its own the app takes the group's and keeps it. Without
  /// the group it keeps its own. `nil` when the Keychain refuses (then the app connects without a device).
  @MainActor static let app: DeviceIdentity? = {
    let accessGroup = (Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    var key: DeviceKey?
#if canImport(VaultHub) && canImport(Security)
    let own = ownDeviceKeySeed(accessGroup: accessGroup)
    if let shared = try? HubKeyStore.shareDeviceKey(own) {
      // Taken from the group: it becomes the app's own, which the extension and later launches read
      let keyChain = own == nil
        ? try? KeyChain(.configuredKeychain(ownDeviceKey(accessGroup: accessGroup)), rawRepresentation: shared.seed)
        : try? KeyChain(rawRepresentation: shared.seed)
      key = keyChain.map(DeviceKey.init)
    }
#endif
#if canImport(Security)
    guard let key = key ?? (try? DeviceKey.keychain(accessGroup: accessGroup)) else { return nil }
#else
    // No keychain: the device key file Hub's launcher and services on this machine use (~/.hub/device.key)
    guard let key = key ?? (try? DeviceKey.file()) else { return nil }
#endif
    return DeviceIdentity(key: key, name: AppDevice.name, platform: AppDevice.platform)
  }()

#if canImport(Security)
  private static func ownDeviceKey(accessGroup: String?) -> KeyChain.KeychainConfiguration {
    .init(service: DeviceKey.keychainService, account: "ed25519-private-key", accessGroup: accessGroup, useDataProtectionKeychain: true)
  }

  /// The seed of the device key the app kept on its own, before it shared one
  private static func ownDeviceKeySeed(accessGroup: String?) -> Data? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: DeviceKey.keychainService,
      kSecAttrAccount as String: "ed25519-private-key",
      kSecUseDataProtectionKeychain as String: true,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let seed = result as? Data, seed.count == 32 else {
      return nil
    }
    return seed
  }
#endif
}

@MainActor
enum AppDevice {
  /// Device model plus the owner's choice of name where the system shares it
  static var name: String { SystemInfo.deviceName }

  static var platform: String {
#if os(macOS) || targetEnvironment(macCatalyst)
    "macos"
#elseif os(visionOS)
    "visionos"
#elseif os(iOS)
    UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
#else
    DeviceIdentity.currentPlatform
#endif
  }

  /// Hardware identifier, `iPhone17,1` or `Mac15,9`
  static var model: String {
    SystemInfo.model ?? DeviceIdentity.currentPlatform
  }

  /// `26.1`; a Linux distribution's own version (`24.04`), not the kernel's.
  static var os: String { SystemInfo.osVersion }

  static var arch: String {
#if arch(arm64)
    "arm64"
#elseif arch(x86_64)
    "x64"
#else
    "other"
#endif
  }

  static func description() async -> DeviceDescription {
    let storage = storage()
    return DeviceDescription(
      name: name, os: os, arch: arch,
      capabilities: Capabilities(
        cpu: .init(cores: ProcessInfo.processInfo.activeProcessorCount, model: SystemInfo.cpuModel),
        memory: Int64(ProcessInfo.processInfo.physicalMemory),
        disks: storage.map { [.init(name: "System", total: $0.total, free: $0.free)] },
        power: Battery.current == nil ? .ac : .battery,
        ssh: await ssh(),
        model: model
      )
    )
  }

  static func data() -> DeviceData {
    let battery = Battery.current
    let storage = storage()
    return DeviceData(
      cpu: cpu.usage(),
      memoryUsed: SystemInfo.memoryUsed(),
      battery: battery?.level,
      charging: battery?.isCharging,
      network: network,
      thermal: thermal,
      storageFree: storage?.free,
      storageTotal: storage?.total
    )
  }

  // MARK: SSH
  /// This Mac's SSH server (Remote Login), as hub-launcher reports it: every host key it offers, signed by the device
  /// key so other devices pin it through the hub, which opens the port in its members' links to this Mac. macOS starts
  /// sshd from launchd on the `ssh` service, so the port is 22 whatever sshd_config says. A Linux machine reports
  /// its sshd the same way, on the port distributions start it on
  static func ssh() async -> Capabilities.SSH? {
#if os(macOS) || os(Linux)
    guard let device = DeviceIdentity.app?.key else { return nil }
    let keys = await hostKeys(port: 22)
    guard let preferred = keys.first else { return nil }
    return Capabilities.SSH(port: 22, user: NSUserName(), hostKey: preferred, otherHostKeys: Array(keys.dropFirst()), device: device)
#else
    return nil
#endif
  }

#if os(macOS) || os(Linux)
  /// The host keys the SSH server on this machine's port offers, Ed25519 first, then ECDSA and RSA (the v57 apps'
  /// libssh2 on mbedTLS can't use Ed25519). The sandbox can't read /etc/ssh, so sshd itself tells them through
  /// `ssh-keyscan`; none when nothing answers
  static func hostKeys(port: Int) async -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
    process.arguments = ["-T", "2", "-t", "ed25519,ecdsa,rsa", "-p", String(port), "127.0.0.1"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let text: String = await withCheckedContinuation { continuation in
      process.terminationHandler = { _ in
        continuation.resume(returning: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
      }
      do { try process.run() } catch {
        process.terminationHandler = nil
        continuation.resume(returning: "")
      }
    }
    let keys = text.split(separator: "\n").compactMap { line -> String? in
      // `127.0.0.1 ssh-ed25519 AAAA…`; comment lines start with `#`
      let fields = line.split(separator: " ")
      guard !line.hasPrefix("#"), fields.count >= 3 else { return nil }
      return "\(fields[1]) \(fields[2])"
    }
    let preference = ["ssh-ed25519", "ecdsa-sha2-", "ssh-rsa"]
    func rank(_ key: String) -> Int { preference.firstIndex { key.hasPrefix($0) } ?? preference.count }
    return keys.sorted { rank($0) < rank($1) }
  }
#endif

  // MARK: Storage, CPU
  static func storage() -> (free: Int64, total: Int64)? { SystemInfo.storage() }

  static let cpu = CPULoad()

  static var thermal: String { SystemInfo.thermalState.rawValue }


  // MARK: Network
  static var network: DeviceData.Network? {
    switch NetworkMonitor.shared.interface {
    case .wifi: .wifi
    case .cellular: .cellular
    case .ethernet: .ethernet
    case .other: .other
    case nil: nil
    }
  }

}
