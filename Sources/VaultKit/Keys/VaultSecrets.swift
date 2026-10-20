import Foundation

/// Passwords and tokens, kept apart from the items: iCloud Keychain items in the shared group, named after the
/// item they belong to. They sync end to end encrypted, so a connection added on the Mac opens on the iPad
/// without typing the password again.
///
/// A demo run or a test calls `useInMemoryStore()` first: from then on, secrets and the personal identity
/// (`VaultPersonalIdentity`) live in memory for the rest of the process and the user's keychain is never read
/// or written.
public enum VaultSecrets {
  static let keychain = VaultKeychain(service: "dev.v57.vault.secrets")

  private static let lock = NSLock()
  nonisolated(unsafe) private static var _backing: any VaultSecretBacking = KeychainSecretBacking(keychain: keychain)

  /// Where secrets are kept: the keychain, or memory after `useInMemoryStore()`.
  public static var backing: any VaultSecretBacking {
    get { lock.withLock { _backing } }
    set { lock.withLock { _backing = newValue } }
  }

  /// Whether secrets live in memory (a demo run or a test).
  public static var isInMemory: Bool { backing is MemorySecretBacking }

  /// Keeps secrets and the personal identity in memory for the rest of the process, so a demo or a test never
  /// touches the user's keychain. Calling it again keeps what the memory store already holds.
  public static func useInMemoryStore() {
    lock.withLock {
      if !(_backing is MemorySecretBacking) { _backing = MemorySecretBacking() }
    }
    VaultPersonalIdentity.useInMemoryStore()
  }

  /// The password saved for an item (a host, a database, a login).
  public static func password(for id: String) -> String? {
    (try? backing.read("password.\(id)")).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
  }

  /// Saves the password, or deletes it for nil.
  public static func setPassword(_ password: String?, for id: String) throws {
    if let password, !password.isEmpty {
      try backing.write(Data(password.utf8), named: "password.\(id)", label: "v57 password")
    } else {
      try backing.delete("password.\(id)")
    }
  }

  /// Any other secret by name (an API key, a login's one-time-code secret `otp.<id>`).
  public static func secret(_ name: String) -> Data? {
    (try? backing.read(name)).flatMap { $0 }
  }

  public static func setSecret(_ data: Data?, named name: String) throws {
    if let data {
      try backing.write(data, named: name, label: "v57 secret")
    } else {
      try backing.delete(name)
    }
  }

  /// A secret kept as UTF-8 text.
  public static func secretText(_ name: String) -> String? {
    secret(name).flatMap { String(data: $0, encoding: .utf8) }
  }

  public static func setSecretText(_ text: String?, named name: String) throws {
    try setSecret(text.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, named: name)
  }
}

/// Where secrets are kept: synced keychain items, or memory for demos and tests.
public protocol VaultSecretBacking: Sendable {
  /// The secret, nil when there is none.
  func read(_ name: String) throws -> Data?
  /// Adds the secret or replaces it.
  func write(_ data: Data, named name: String, label: String) throws
  /// Adds the secret unless one exists; returns whether it was added.
  func addNew(_ data: Data, named name: String, label: String) throws -> Bool
  func delete(_ name: String) throws
}

/// Synchronizable items of a keychain service.
public struct KeychainSecretBacking: VaultSecretBacking {
  public let keychain: VaultKeychain

  public init(keychain: VaultKeychain) {
    self.keychain = keychain
  }

  public func read(_ name: String) throws -> Data? {
    try keychain.read(name, options: .synced)
  }

  public func write(_ data: Data, named name: String, label: String) throws {
    try keychain.write(data, account: name, options: .init(synchronizable: true, label: label))
  }

  public func addNew(_ data: Data, named name: String, label: String) throws -> Bool {
    do {
      try keychain.addNew(data, account: name, options: .init(synchronizable: true, label: label))
      return true
    } catch VaultKeychain.KeychainError.status(errSecDuplicateItem) {
      return false
    }
  }

  public func delete(_ name: String) throws {
    try keychain.delete(name, options: .synced)
  }
}

/// Secrets in memory, gone when the process ends: for demo runs, previews and tests.
public final class MemorySecretBacking: VaultSecretBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data]

  public init(_ items: [String: Data] = [:]) {
    self.items = items
  }

  public func read(_ name: String) throws -> Data? {
    lock.withLock { items[name] }
  }

  public func write(_ data: Data, named name: String, label: String) throws {
    lock.withLock { items[name] = data }
  }

  public func addNew(_ data: Data, named name: String, label: String) throws -> Bool {
    lock.withLock {
      guard items[name] == nil else { return false }
      items[name] = data
      return true
    }
  }

  public func delete(_ name: String) throws {
    _ = lock.withLock { items.removeValue(forKey: name) }
  }

  /// Every secret's name.
  public var names: [String] {
    lock.withLock { Array(items.keys) }
  }
}
