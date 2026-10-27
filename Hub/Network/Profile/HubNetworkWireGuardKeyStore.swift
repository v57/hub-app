import CryptoKit
import Foundation
import HubService
#if canImport(Security)
import Security
#endif

/// Persistent X25519 key material shared only with Hub's packet extension.
///
/// Profile JSON carries public binding data. Private material remains in the
/// shared Keychain access group used by app and extension.
struct HubNetworkWireGuardKeyStore: Sendable {
  static let service = "dev.v57.Hub.network.wireguard.v1"
  static let account = "private-key"

  func loadOrCreate() throws -> Curve25519.KeyAgreement.PrivateKey {
    if let data = try load() {
      return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }
    let key = Curve25519.KeyAgreement.PrivateKey()
    try save(key.rawRepresentation)
    return key
  }

  func publicKeyBase64() throws -> String {
    try loadOrCreate().publicKey.rawRepresentation.base64EncodedString()
  }

  /// Replaces the device WireGuard identity (joiner path: the staged
  /// per-transaction key must become the identity the extension's adapter
  /// reads from this store when the bootstrap tunnel starts; the owner/local
  /// flows only ever create it via `loadOrCreate`).
  func install(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
#if canImport(Security)
    SecItemDelete(baseQuery as CFDictionary)
#endif
    try save(key.rawRepresentation)
  }

#if canImport(Security)
  private func load() throws -> Data? {
    if let data = try load(baseQuery) { return data }
    // Moves a key an older build kept in the Mac's login keychain, where only the binary that made it reads it
    // without a password prompt, into the shared group the extension reads too
    guard let legacy = try load(legacyQuery) else { return nil }
    try save(legacy)
    SecItemDelete(legacyQuery as CFDictionary)
    return legacy
  }

  private func load(_ base: [String: Any]) throws -> Data? {
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw HubNetworkWireGuardKeyStoreError.keychain(status)
    }
    return data
  }

  private func save(_ data: Data) throws {
    var query = baseQuery
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw HubNetworkWireGuardKeyStoreError.keychain(status)
    }
  }

  /// Where older builds kept the key: the legacy keychain on the Mac, without the group
  private var legacyQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
    ]
  }

  /// The data-protection keychain in the group the app shares with its extension, as the app's other keys: on the
  /// Mac the legacy keychain asks for the login password whenever another build of the app or extension reads it
  private var baseQuery: [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
      kSecUseDataProtectionKeychain as String: true,
    ]
    // Explicit shared group so app and extension resolve the same item on
    // both platforms (same pattern as NativeJoinKeychainStorage).
    if let group = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String,
       !group.isEmpty {
      query[kSecAttrAccessGroup as String] = group
    }
    return query
  }
#else
  // The Keychain stand-in (the Secret Service on Linux) through HubService
  private var item: KeyChain.KeychainConfiguration { .init(service: Self.service, account: Self.account) }
  private func load() throws -> Data? { try KeyChain.loadData(keychain: item) }
  private func save(_ data: Data) throws { try KeyChain.replaceData(data, keychain: item) }
#endif
}

enum HubNetworkWireGuardKeyStoreError: Error, Equatable {
  case keychain(Int32)
}
