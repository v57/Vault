import CryptoKit
import Foundation

/// The accounts' vault keys (`VaultAccount`): each account has keys of its own, apart from Personal's, so it can be
/// shared or deleted without touching Personal.
public protocol VaultAccountKeychain: Sendable {
  /// The keys an account's store seals with. It makes none: until the account's key arrives, writes fail.
  func keys(forAccount id: String) -> VaultKeyProvider
  /// Makes a new account's key; returns its id.
  func createKey(forAccount id: String, label: String) throws -> String
  /// Removes every key of the account (on every device: the items are synced).
  func deleteKeys(forAccount id: String) throws
}

/// The accounts' keys as synced items in the vault's keychain group, beside Personal's: `accountKey.<account>.<key>`,
/// a prefix Personal's `key.<id>` items never match.
public struct KeychainAccountKeychain: VaultAccountKeychain {
  public let keychain: VaultKeychain

  public init(keychain: VaultKeychain = VaultKeychain()) {
    self.keychain = keychain
  }

  static func prefix(_ account: String) -> String { "accountKey.\(account)." }

  public func keys(forAccount id: String) -> VaultKeyProvider {
    KeychainKeyProvider(keychain: keychain, prefix: Self.prefix(id), createsKeyLabelled: nil)
  }

  public func createKey(forAccount id: String, label: String) throws -> String {
    let keyID = KeychainKeyProvider.newKeyID()
    let key = SymmetricKey(size: .bits256)
    try keychain.addNew(
      key.withUnsafeBytes { Data($0) }, account: Self.prefix(id) + keyID,
      options: .init(synchronizable: true, label: "v57 Vault key: \(label)"))
    return keyID
  }

  public func deleteKeys(forAccount id: String) throws {
    for item in try keychain.readAll(options: .synced) where item.account.hasPrefix(Self.prefix(id)) {
      try keychain.delete(item.account, options: .synced)
    }
  }
}

/// Account keys in memory, for tests and previews. One instance shared by several simulated devices acts as iCloud
/// Keychain: a key made on one is on all of them.
public final class MemoryAccountKeychain: VaultAccountKeychain, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: [String: SymmetricKey]] = [:]

  public init() {}

  public func keys(forAccount id: String) -> VaultKeyProvider { AccountKeys(owner: self, account: id) }

  public func createKey(forAccount id: String, label: String) throws -> String {
    let keyID = KeychainKeyProvider.newKeyID()
    lock.withLock { keys[id, default: [:]][keyID] = SymmetricKey(size: .bits256) }
    return keyID
  }

  public func deleteKeys(forAccount id: String) throws {
    lock.withLock { _ = keys.removeValue(forKey: id) }
  }

  /// Whether any key of the account is left.
  public func hasKeys(forAccount id: String) -> Bool {
    lock.withLock { keys[id]?.isEmpty == false }
  }

  fileprivate func all(_ account: String) -> [String: SymmetricKey] {
    lock.withLock { keys[account] ?? [:] }
  }

  /// Reads the shared keys on every call, as `KeychainKeyProvider` reloads the keychain.
  private struct AccountKeys: VaultKeyProvider {
    let owner: MemoryAccountKeychain
    let account: String

    func primary() throws -> (id: String, key: SymmetricKey) {
      let keys = owner.all(account)
      guard let id = keys.keys.min() else { throw VaultCrypto.CryptoError.missingKey(account) }
      return (id, keys[id]!)
    }

    func key(id: String) throws -> SymmetricKey? { owner.all(account)[id] }

    var allKeys: [String: SymmetricKey] { owner.all(account) }
  }
}
