//
//  App credentials.swift
//  Hub
//
//  Which keys the app connects to each hub with (Docs/Devices/protocol.md, section 2). A hub added since auth v2 gets
//  its own service key and device key, derived from the device key and the address, so what it receives, relays or
//  claims means nothing on another hub; the Vault client on this device derives the same device key. A hub pinned
//  before keeps the shared keys it was approved with, and so does the hub this app runs itself.
//

import Foundation
import HubService

extension Hub.Settings {
  /// `keys` of a hub on the shared keys
  static let sharedKeys = "shared"
}

@MainActor
enum AppCredentials {
  /// The scope of an address the app hasn't kept any: what the vault's record of it says, else keys of its own
  static func scope(for address: URL) -> String {
#if canImport(VaultHub)
    if let scope = AppVault.scope(for: address) { return scope }
#endif
    return HubAddress.canonical(address) ?? address.absoluteString
  }

  /// An invitation decides which hub the app joins only later, and may lead anywhere: keys of its own for each one
  static func joinScope(transactionId: String) -> String {
    "join:\(transactionId)"
  }

  /// The service key: the legacy membership key of `tag`, `KeyChain.main` on the shared keys, else derived
  static func service(scope: String, tag: String?) -> KeyChain {
    if let tag { return .keychain(tag) }
    return service(scope: scope)
  }

  static func service(scope: String) -> KeyChain {
    guard scope != Hub.Settings.sharedKeys else { return .main }
    return (DeviceIdentity.app?.key.keyChain ?? .main).hubCredential(.hubApp, address: scope)
  }

  /// This device on the hub
  static func device(scope: String) -> DeviceIdentity? {
    guard let app = DeviceIdentity.app, scope != Hub.Settings.sharedKeys else { return DeviceIdentity.app }
    let key = DeviceKey(app.key.keyChain.hubCredential(.device, address: scope))
    return DeviceIdentity(key: key, name: app.name, platform: app.platform, parent: app.parent)
  }
}
