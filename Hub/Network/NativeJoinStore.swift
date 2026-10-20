import CryptoKit
import Foundation
import HubService
import Security

enum NativeJoinStage: String, Codable, Sendable {
  case staged
  case enrollmentRecorded
  case committed
}

struct NativeJoinEnrollment: Codable, Equatable, Sendable {
  let hubKey: String
  let hubNetworkId: String
  let profile: AgentProfile
}

struct NativeJoinRecord: Codable, Equatable, Sendable {
  static let version = 1

  let version: Int
  let transactionId: String
  let tokenDigest: String
  let profilePublicKey: String
  let wireGuardPublicKey: String
  let createdAt: Date
  var updatedAt: Date
  var stage: NativeJoinStage
  var enrollment: NativeJoinEnrollment?
}

struct NativeJoinIdentity: Equatable, Sendable {
  let transactionId: String
  let profilePublicKey: String
  let wireGuardPublicKey: String
}

enum NativeJoinStoreError: Error, Equatable {
  case invalidToken
  case incompatibleVersion(Int)
  case corruptRecord
  case transactionConflict
  case invalidTransition
  case keychain(OSStatus)
}

protocol NativeJoinSecretStorage: Sendable {
  func load(account: String) throws -> Data?
  func insert(_ data: Data, account: String) throws
  func delete(account: String) throws
}

struct NativeJoinKeychainStorage: NativeJoinSecretStorage {
  static let service = "dev.v57.Hub.network.native-join.v1"

  static func serviceKeychain(
    account: String
  ) -> KeyChain.KeychainConfiguration {
    var group: String?
    if let configured = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String,
       !configured.isEmpty {
      group = configured
    }
    return KeyChain.KeychainConfiguration(
      service: service,
      account: account,
      accessGroup: group,
      useDataProtectionKeychain: true
    )
  }

  func load(account: String) throws -> Data? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw NativeJoinStoreError.keychain(status)
    }
    return data
  }

  func insert(_ data: Data, account: String) throws {
    var query = baseQuery(account: account)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw NativeJoinStoreError.keychain(status) }
  }

  func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NativeJoinStoreError.keychain(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
    ]
    if let group = Bundle.main.object(forInfoDictionaryKey: "HubKeychainAccessGroup") as? String,
       !group.isEmpty {
      query[kSecAttrAccessGroup as String] = group
    }
    return query
  }
}

actor NativeJoinStore {
  static let main = NativeJoinStore()

  private let directory: URL
  private let secrets: any NativeJoinSecretStorage
  private let now: @Sendable () -> Date
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  private let appIdentity: @Sendable () -> KeyChain

  init(
    directory: URL? = nil,
    secrets: any NativeJoinSecretStorage = NativeJoinKeychainStorage(),
    appIdentity: @escaping @Sendable () -> KeyChain = { KeyChain.main },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.directory = directory ?? Self.defaultDirectory()
    self.secrets = secrets
    self.appIdentity = appIdentity
    self.now = now
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func stage(tokenId: String) throws -> NativeJoinRecord {
    guard !tokenId.isEmpty, tokenId.utf8.count <= 512 else {
      throw NativeJoinStoreError.invalidToken
    }
    if let existing = try load(transactionId: tokenId) {
      _ = try identity(for: existing)
      return existing
    }

    try rejectDifferentUnfinishedTransaction(tokenId)
    // The joiner is the app's own service key (identity.v1) on the app's device; the invitation approves the
    // device instead of replacing the identity, so the app keeps its key and owner rights on other hubs.
    let profile = appIdentity()
    let wireGuard = Curve25519.KeyAgreement.PrivateKey()
    let accounts = secretAccounts(tokenId)
    do {
      try secrets.insert(wireGuard.rawRepresentation, account: accounts.wireGuard)
      let timestamp = now()
      let record = NativeJoinRecord(
        version: NativeJoinRecord.version,
        transactionId: tokenId,
        tokenDigest: Self.digest(tokenId),
        profilePublicKey: profile.data.base64EncodedString(),
        wireGuardPublicKey: wireGuard.publicKey.rawRepresentation.base64EncodedString(),
        createdAt: timestamp,
        updatedAt: timestamp,
        stage: .staged,
        enrollment: nil
      )
      try persist(record)
      return record
    } catch {
      try? secrets.delete(account: accounts.profile)
      try? secrets.delete(account: accounts.wireGuard)
      throw error
    }
  }

  func resume(tokenId: String) throws -> NativeJoinRecord? {
    guard !tokenId.isEmpty else { throw NativeJoinStoreError.invalidToken }
    guard let record = try load(transactionId: tokenId) else { return nil }
    _ = try identity(for: record)
    return record
  }

  /// The staged per-transaction WireGuard private key — the identity the
  /// extension's adapter must use for the bootstrap tunnel (the adapter
  /// reads the device key from `wireguard.v1`; the coordinator installs this
  /// key there before the tunnel starts).
  func wireGuardPrivateKey(transactionId: String) throws -> Data? {
    guard let record = try load(transactionId: transactionId) else { return nil }
    let accounts = secretAccounts(transactionId)
    guard let data = try secrets.load(account: accounts.wireGuard),
          let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data),
          key.publicKey.rawRepresentation.base64EncodedString() == record.wireGuardPublicKey
    else { return nil }
    return data
  }

  /// Whether the transaction has its own joiner service key. Transactions staged before the device layer did;
  /// new ones join with the app's identity (`identity.v1`) and have none.
  func hasStagedProfileKey(transactionId: String) throws -> Bool {
    try secrets.load(account: secretAccounts(transactionId).profile) != nil
  }

  func identity(transactionId: String) throws -> NativeJoinIdentity {
    guard let record = try load(transactionId: transactionId) else {
      throw NativeJoinStoreError.corruptRecord
    }
    return try identity(for: record)
  }

  func recordEnrollment(
    transactionId: String,
    enrollment: NativeJoinEnrollment
  ) throws -> NativeJoinRecord {
    var record = try requiredRecord(transactionId)
    if record.stage == .enrollmentRecorded, record.enrollment == enrollment { return record }
    guard record.stage == .staged, record.enrollment == nil else {
      throw NativeJoinStoreError.invalidTransition
    }
    record.stage = .enrollmentRecorded
    record.enrollment = enrollment
    record.updatedAt = now()
    try persist(record)
    return record
  }

  func markCommitted(transactionId: String) throws -> NativeJoinRecord {
    var record = try requiredRecord(transactionId)
    if record.stage == .committed { return record }
    guard record.stage == .enrollmentRecorded, record.enrollment != nil else {
      throw NativeJoinStoreError.invalidTransition
    }
    record.stage = .committed
    record.updatedAt = now()
    try persist(record)
    return record
  }

  /// Keeps a staged joiner key (legacy transactions) as the membership's own identity
  func promoteProfileIdentity(
    transactionId: String,
    keychainTag: String
  ) throws {
    let record = try requiredRecord(transactionId)
    guard record.stage == .enrollmentRecorded,
          let data = try secrets.load(account: secretAccounts(transactionId).profile),
          try KeyChain(.keychain(keychainTag), rawRepresentation: data).publicKey()
            == Self.derPublicKey(fromRawBase64: record.profilePublicKey)
    else { throw NativeJoinStoreError.corruptRecord }
  }

  /// The joiner service identity, so callers can build an authenticated Hub
  /// client for `hub/net/bind` and later connections: the app's identity, or
  /// the transaction's own key for transactions staged before the device layer.
  func serviceKey(
    transactionId: String,
    profilePublicKey: String
  ) throws -> KeyChain {
    let record = try requiredRecord(transactionId)
    guard try hasStagedProfileKey(transactionId: transactionId) else {
      let identity = appIdentity()
      guard record.profilePublicKey == profilePublicKey,
            identity.data.base64EncodedString() == profilePublicKey
      else { throw NativeJoinStoreError.corruptRecord }
      return identity
    }
    let key = try KeyChain(
      keychain: NativeJoinKeychainStorage.serviceKeychain(
        account: secretAccounts(transactionId).profile
      ),
      createIfMissing: false
    )
    // KeyChain.publicKey() returns the canonical SPKI form (ed25519 prefix
    // + raw); the staged record stores the raw 32-byte form. Normalize
    // before comparing — this is the same encoding trap as the readiness
    // assertion and joinerServiceKey checks (see skill pitfall #12).
    let expectedSPKI = KeyChain.spkiPublicKey(rawBase64: profilePublicKey) ?? profilePublicKey
    guard record.profilePublicKey == profilePublicKey,
          key.publicKey() == expectedSPKI
    else { throw NativeJoinStoreError.corruptRecord }
    return key
  }

  func cancel(transactionId: String) throws {
    let record = try requiredRecord(transactionId)
    guard record.stage == .staged else { throw NativeJoinStoreError.invalidTransition }
    try cleanup(transactionId: transactionId)
  }

  func cleanup(transactionId: String) throws {
    let accounts = secretAccounts(transactionId)
    try secrets.delete(account: accounts.profile)
    try secrets.delete(account: accounts.wireGuard)
    let url = recordURL(transactionId)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private func identity(for record: NativeJoinRecord) throws -> NativeJoinIdentity {
    let accounts = secretAccounts(record.transactionId)
    let profilePublicKey: String
    if let profileData = try secrets.load(account: accounts.profile) {
      guard let profile = try? Curve25519.Signing.PrivateKey(rawRepresentation: profileData) else {
        throw NativeJoinStoreError.corruptRecord
      }
      profilePublicKey = profile.publicKey.rawRepresentation.base64EncodedString()
    } else {
      profilePublicKey = appIdentity().data.base64EncodedString()
    }
    guard let wireGuardData = try secrets.load(account: accounts.wireGuard),
          let wireGuard = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: wireGuardData),
          profilePublicKey == record.profilePublicKey,
          wireGuard.publicKey.rawRepresentation.base64EncodedString() == record.wireGuardPublicKey
    else { throw NativeJoinStoreError.corruptRecord }
    return NativeJoinIdentity(
      transactionId: record.transactionId,
      profilePublicKey: record.profilePublicKey,
      wireGuardPublicKey: record.wireGuardPublicKey
    )
  }

  private func requiredRecord(_ transactionId: String) throws -> NativeJoinRecord {
    guard let record = try load(transactionId: transactionId) else {
      throw NativeJoinStoreError.corruptRecord
    }
    return record
  }

  private func load(transactionId: String) throws -> NativeJoinRecord? {
    let url = recordURL(transactionId)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let record = try decoder.decode(NativeJoinRecord.self, from: Data(contentsOf: url))
    guard record.version == NativeJoinRecord.version else {
      throw NativeJoinStoreError.incompatibleVersion(record.version)
    }
    guard record.transactionId == transactionId,
          record.tokenDigest == Self.digest(transactionId),
          (record.stage == .staged) == (record.enrollment == nil)
    else { throw NativeJoinStoreError.corruptRecord }
    return record
  }

  private func persist(_ record: NativeJoinRecord) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encoder.encode(record).write(to: recordURL(record.transactionId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  private func rejectDifferentUnfinishedTransaction(_ transactionId: String) throws {
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ) else { return }
    for url in urls where url.pathExtension == "json" {
      guard let data = try? Data(contentsOf: url),
            let record = try? decoder.decode(NativeJoinRecord.self, from: data) else { continue }
      if record.transactionId != transactionId, record.stage != .committed {
        throw NativeJoinStoreError.transactionConflict
      }
    }
  }

  private func recordURL(_ transactionId: String) -> URL {
    directory.appendingPathComponent(Self.digest(transactionId)).appendingPathExtension("json")
  }

  private func secretAccounts(_ transactionId: String) -> (profile: String, wireGuard: String) {
    let digest = Self.digest(transactionId)
    return ("\(digest).profile", "\(digest).wireguard")
  }

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func derPublicKey(fromRawBase64 value: String) -> String? {
    KeyChain.spkiPublicKey(rawBase64: value)
  }

  private static func defaultDirectory() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("Hub/NativeNetworkJoins/v1", isDirectory: true)
  }
}
