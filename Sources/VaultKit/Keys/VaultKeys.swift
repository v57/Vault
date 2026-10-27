import CryptoKit
import Foundation

/// The AES-256 keys that encrypt the vault, by id.
///
/// Every item names the key it was sealed with, so a device can hold several: if two devices create the
/// first key at the same moment (both offline, or before iCloud Keychain synced), both keys end up on both
/// devices and everything stays readable. New writes use the `primary` key, the one with the smallest id,
/// so devices settle on the same key once they've seen each other's.
public protocol VaultKeyProvider: Sendable {
  /// The key new writes are sealed with.
  func primary() throws -> (id: String, key: SymmetricKey)
  /// A key by id; nil when this device doesn't have it (yet).
  func key(id: String) throws -> SymmetricKey?
  /// Every key this device has, by id (the recovery key wraps them all).
  var allKeys: [String: SymmetricKey] { get throws }
}

extension VaultKeyProvider {
  public var allKeys: [String: SymmetricKey] {
    get throws {
      let primary = try primary()
      return [primary.id: primary.key]
    }
  }
}

/// The keys in the shared keychain group, synced by iCloud Keychain.
public final class KeychainKeyProvider: VaultKeyProvider, @unchecked Sendable {
  private let keychain: VaultKeychain
  private let prefix: String
  /// Made when there is none yet (Personal); an account's key is made with the account, so a device it hasn't
  /// reached yet waits for it instead of starting a key of its own.
  private let label: String?
  private let lock = NSLock()
  private var cache: [String: SymmetricKey] = [:]

  /// Personal's keys.
  public convenience init(keychain: VaultKeychain = VaultKeychain()) {
    self.init(keychain: keychain, prefix: Self.prefix, createsKeyLabelled: "v57 Vault key")
  }

  /// The keys named `<prefix><id>`; `label` names the key made when there is none, nil to make none.
  init(keychain: VaultKeychain, prefix: String, createsKeyLabelled label: String?) {
    self.keychain = keychain
    self.prefix = prefix
    self.label = label
  }

  /// Personal's keychain items are named `key.<id>`.
  static let prefix = "key."

  public func primary() throws -> (id: String, key: SymmetricKey) {
    lock.lock()
    defer { lock.unlock() }
    if cache.isEmpty { try reload() }
    if cache.isEmpty {
      guard let label else { throw VaultCrypto.CryptoError.missingKey(prefix) }
      let id = Self.newKeyID()
      let key = SymmetricKey(size: .bits256)
      try keychain.addNew(
        key.withUnsafeBytes { Data($0) }, account: prefix + id, options: .init(synchronizable: true, label: label))
      cache[id] = key
    }
    let id = cache.keys.min()!
    return (id, cache[id]!)
  }

  public func key(id: String) throws -> SymmetricKey? {
    lock.lock()
    defer { lock.unlock() }
    if let key = cache[id] { return key }
    // It may have arrived through iCloud Keychain since the last look.
    try reload()
    return cache[id]
  }

  public var allKeys: [String: SymmetricKey] {
    get throws {
      lock.lock()
      defer { lock.unlock() }
      try reload()
      return cache
    }
  }

  private func reload() throws {
    for item in try keychain.readAll(options: .synced) where item.account.hasPrefix(prefix) {
      cache[String(item.account.dropFirst(prefix.count))] = SymmetricKey(data: item.data)
    }
  }

  static func newKeyID() -> String {
    (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }
}

/// Keys held in memory, for tests and previews.
public final class MemoryKeyProvider: VaultKeyProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: SymmetricKey]

  public init(keys: [String: SymmetricKey] = ["0000000000000001": SymmetricKey(size: .bits256)]) {
    self.keys = keys
  }

  public func primary() throws -> (id: String, key: SymmetricKey) {
    lock.lock()
    defer { lock.unlock() }
    let id = keys.keys.min()!
    return (id, keys[id]!)
  }

  public func key(id: String) throws -> SymmetricKey? {
    lock.lock()
    defer { lock.unlock() }
    return keys[id]
  }

  /// Adds a key, as iCloud Keychain delivering another device's key would.
  public func add(_ key: SymmetricKey, id: String) {
    lock.lock()
    keys[id] = key
    lock.unlock()
  }

  public var allKeys: [String: SymmetricKey] {
    lock.lock()
    defer { lock.unlock() }
    return keys
  }
}

/// AES-GCM sealing with the vault keys.
public enum VaultCrypto {
  public enum CryptoError: LocalizedError {
    case missingKey(String)
    case damaged

    public var errorDescription: String? {
      switch self {
      case .missingKey: "This device doesn't have the key for this data yet. It arrives through iCloud Keychain."
      case .damaged: "The encrypted data is damaged."
      }
    }
  }

  public static func seal(_ plaintext: Data, keys: VaultKeyProvider) throws -> (keyID: String, ciphertext: Data) {
    let (id, key) = try keys.primary()
    guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw CryptoError.damaged }
    return (id, combined)
  }

  public static func open(_ ciphertext: Data, keyID: String, keys: VaultKeyProvider) throws -> Data {
    guard let key = try keys.key(id: keyID) else { throw CryptoError.missingKey(keyID) }
    return try open(ciphertext, key: key)
  }

  static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
    guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw CryptoError.damaged }
    return combined
  }

  static func open(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
    do {
      return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
    } catch {
      throw CryptoError.damaged
    }
  }

  /// A keyed hash for ids derived from content (a project's remote URL), so CloudKit sees the id but not
  /// what it was made from. Keyed with the primary key: after a first-key race a few ids may differ between
  /// devices, which `VaultStore` folds together by content.
  public static func derivedID(_ text: String, keys: VaultKeyProvider) throws -> String {
    let (_, key) = try keys.primary()
    let idKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, info: Data("dev.v57.vault.ids".utf8), outputByteCount: 32)
    let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: idKey)
    return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}
