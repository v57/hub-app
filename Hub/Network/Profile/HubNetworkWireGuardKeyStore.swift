import CryptoKit
import Foundation
import Security

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
    SecItemDelete(baseQuery as CFDictionary)
    try save(key.rawRepresentation)
  }

  private func load() throws -> Data? {
    var query = baseQuery
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

  private var baseQuery: [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
    ]
    // Explicit shared group so app and extension resolve the same item on
    // both platforms (same pattern as NativeJoinKeychainStorage).
    if let group = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String,
       !group.isEmpty {
      query[kSecAttrAccessGroup as String] = group
    }
    return query
  }
}

enum HubNetworkWireGuardKeyStoreError: Error, Equatable {
  case keychain(OSStatus)
}
