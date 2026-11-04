import Foundation

/// Passwords and tokens, kept apart from the items: iCloud Keychain items named after the item they belong to. They sync
/// end to end encrypted, so a connection added on the Mac opens on the iPad without typing the password again.
///
/// **Two groups** (`VaultSecretTiers`). What the user thinks of as their passwords (a login's password, one-time codes,
/// cards, passkeys) is readable only by Vault and its AutoFill extension. A password the apps themselves log in with (a
/// host's, a database's, a remote's) and an imported SSH key stay in the group every app lists, because those apps need
/// them. An app outside the secrets group simply gets nil for the first kind; it never means "there's none".
///
/// A demo run or a test calls `useInMemoryStore()` first: from then on, secrets and the personal identity
/// (`VaultPersonalIdentity`) live in memory for the rest of the process and the user's keychain is never read
/// or written.
public enum VaultSecrets {
  static let keychain = VaultKeychain(service: "dev.v57.vault.secrets")
  /// A service of its own, not just a group, so items of the two can't be one item where groups don't exist (a file
  /// keychain, off Apple platforms).
  static let vaultOnlyKeychain = VaultKeychain(service: "dev.v57.secrets", accessGroup: VaultConfiguration.secretsGroup)

  private static let lock = NSLock()
  nonisolated(unsafe) private static var _backing: any VaultSecretBacking = VaultSecretTiers.forThisApp(
    shared: keychain, vaultOnly: vaultOnlyKeychain)

  /// Where secrets are kept: the keychain, or memory after `useInMemoryStore()`.
  public static var backing: any VaultSecretBacking {
    get { lock.withLock { _backing } }
    set { lock.withLock { _backing = newValue } }
  }

  /// Told of every secret set (with its value) or deleted (nil) through this type: the recovery kit keeps up
  /// (`VaultStore.shared` installs it).
  public static var didChange: (@Sendable (_ name: String, _ value: Data?) -> Void)? {
    get { lock.withLock { _didChange } }
    set { lock.withLock { _didChange = newValue } }
  }
  nonisolated(unsafe) private static var _didChange: (@Sendable (String, Data?) -> Void)?

  /// Whether secrets live in memory (a demo run or a test).
  public static var isInMemory: Bool { backing is MemorySecretBacking }

  /// Whether this app can read every secret: only Vault and its AutoFill extension. Elsewhere a login's password, a code,
  /// a card or a passkey reads as nil whether it exists or not, so nothing may conclude from that that it's gone.
  public static var seesEverySecret: Bool { backing.seesEverySecret }

  /// Keeps secrets and the personal identity in memory for the rest of the process, so a demo or a test never
  /// touches the user's keychain. Calling it again keeps what the memory store already holds.
  public static func useInMemoryStore() {
    lock.withLock {
      if !(_backing is MemorySecretBacking) { _backing = MemorySecretBacking() }
    }
    VaultPersonalIdentity.useInMemoryStore()
  }

  /// The password saved for what an app logs in to: a host, a database, a remote. A login's is `loginPassword(for:)`.
  public static func password(for id: String) -> String? {
    (try? backing.read("password.\(id)")).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
  }

  /// Saves the password, or deletes it for nil.
  public static func setPassword(_ password: String?, for id: String) throws {
    if let password, !password.isEmpty {
      try backing.write(Data(password.utf8), named: "password.\(id)", label: "v57 password")
      didChange?("password.\(id)", Data(password.utf8))
    } else {
      try backing.delete("password.\(id)")
      didChange?("password.\(id)", nil)
    }
  }

  /// A login's password, in Vault and its AutoFill extension. Until `VaultSecretMove` has moved it, it's still in the
  /// shared group under the name it had there; no other app reads it from there through this.
  public static func loginPassword(for id: String) -> String? {
    if let password = secretText(loginSecret(id)) { return password }
    return seesEverySecret ? password(for: id) : nil
  }

  /// Saves a login's password, or deletes it for nil, along with any copy from before the move.
  public static func setLoginPassword(_ password: String?, for id: String) throws {
    try setSecretText(password, named: loginSecret(id))
    if (try? backing.read("password.\(id)")) != nil { try setPassword(nil, for: id) }
  }

  /// The name of a login's password.
  public static func loginSecret(_ id: String) -> String { "login.\(id)" }

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
    didChange?(name, data)
  }

  /// Deletes every secret kept for an item: its password, a login's one-time-code secret, a card's number and code,
  /// a passkey's private key.
  public static func deleteSecrets(forItem id: String) throws {
    try setPassword(nil, for: id)
    for name in [loginSecret(id), "otp.\(id)", "card.number.\(id)", "card.code.\(id)", "passkey.\(id)"] {
      try setSecret(nil, named: name)
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
  /// Every secret this app can read, for the recovery kit to seal.
  func all() throws -> [(name: String, data: Data)]
  /// When the secret last changed, if that's known.
  func modified(_ name: String) throws -> Date?
  /// Whether `all()` is every secret there is: false in an app outside the secrets group.
  var seesEverySecret: Bool { get }
}

extension VaultSecretBacking {
  public func modified(_ name: String) throws -> Date? { nil }
  public var seesEverySecret: Bool { true }
}

/// Secrets in two places: `shared`, in the keychain group every app lists, and `vaultOnly`, in the group only Vault and
/// its AutoFill extension list (`VaultConfiguration.secretsGroup`). An app outside that group has no `vaultOnly`.
///
/// Names decide where a secret goes, so nothing has to look at a record to know: `isVaultOnly`. `password.<id>` is what
/// an app logs in with (a host, a database, a remote), `login.<id>` a login's. A login's password from before the split
/// is `password.<id>` in the shared group until `VaultSecretMove` moves it.
///
/// In an app outside the group a vault-only secret reads as nil and can't be written (`vaultOnlyHere`). A delete takes
/// out what the app can reach and doesn't fail: `VaultSecretCleanup` carries what it can't to Vault.
public struct VaultSecretTiers: VaultSecretBacking {
  public let shared: any VaultSecretBacking
  public let vaultOnly: (any VaultSecretBacking)?
  private let decides: @Sendable (String) -> Bool

  public init(shared: any VaultSecretBacking, vaultOnly: (any VaultSecretBacking)?) {
    self.init(shared: shared, vaultOnly: vaultOnly, isVaultOnly: Self.isVaultOnly)
  }

  init(shared: any VaultSecretBacking, vaultOnly: (any VaultSecretBacking)?, isVaultOnly: @escaping @Sendable (String) -> Bool) {
    self.shared = shared
    self.vaultOnly = vaultOnly
    decides = isVaultOnly
  }

  public enum TierError: LocalizedError, Equatable {
    case vaultOnlyHere(String)

    public var errorDescription: String? {
      switch self {
      case .vaultOnlyHere: "Only the Vault app can change this."
      }
    }
  }

  /// A build outside the team's keychain shares nothing with anyone, so it keeps everything itself.
  static func forThisApp(shared: VaultKeychain, vaultOnly: VaultKeychain) -> VaultSecretTiers {
    let holds = VaultKeychain.isEntitled(to: VaultConfiguration.secretsGroup) || !VaultKeychain.isShared
    return VaultSecretTiers(
      shared: KeychainSecretBacking(keychain: shared), vaultOnly: holds ? KeychainSecretBacking(keychain: vaultOnly) : nil)
  }

  /// A login's password, a one-time code, a card, a passkey, and what the recovery kit keys its digests with (it tells
  /// whoever holds the vault key whether a guess at a secret is right).
  public static func isVaultOnly(_ name: String) -> Bool {
    name == VaultRecovery.digestSecret
      || ["login.", "otp.", "card.number.", "card.code.", "passkey.", VaultSecretMove.supersededPrefix].contains { name.hasPrefix($0) }
  }

  public var seesEverySecret: Bool { vaultOnly != nil }

  public func read(_ name: String) throws -> Data? {
    guard decides(name) else { return try shared.read(name) }
    guard let vaultOnly else { return nil }
    return try vaultOnly.read(name) ?? shared.read(name)
  }

  public func write(_ data: Data, named name: String, label: String) throws {
    guard decides(name) else { return try shared.write(data, named: name, label: label) }
    guard let vaultOnly else { throw TierError.vaultOnlyHere(name) }
    try vaultOnly.write(data, named: name, label: label)
    try shared.delete(name)
  }

  public func addNew(_ data: Data, named name: String, label: String) throws -> Bool {
    guard decides(name) else { return try shared.addNew(data, named: name, label: label) }
    guard let vaultOnly else { throw TierError.vaultOnlyHere(name) }
    if try shared.read(name) != nil { return false }
    return try vaultOnly.addNew(data, named: name, label: label)
  }

  public func delete(_ name: String) throws {
    if decides(name) { try vaultOnly?.delete(name) }
    try shared.delete(name)
  }

  public func all() throws -> [(name: String, data: Data)] {
    guard let vaultOnly else { return try shared.all().filter { !decides($0.name) } }
    let own = try vaultOnly.all()
    let names = Set(own.map(\.name))
    return try own + shared.all().filter { !names.contains($0.name) }
  }

  public func modified(_ name: String) throws -> Date? {
    if decides(name), let date = try vaultOnly?.modified(name) { return date }
    return try shared.modified(name)
  }
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

  public func all() throws -> [(name: String, data: Data)] {
    try keychain.readAll(options: .synced).map { ($0.account, $0.data) }
  }

  public func modified(_ name: String) throws -> Date? {
    try keychain.attributes(of: name, options: .synced)?.modified
  }
}

/// Secrets in memory, gone when the process ends: for demo runs, previews and tests.
public final class MemorySecretBacking: VaultSecretBacking, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data]
  private var dates: [String: Date] = [:]

  public init(_ items: [String: Data] = [:]) {
    self.items = items
  }

  public func modified(_ name: String) throws -> Date? {
    lock.withLock { dates[name] }
  }

  /// Sets when a secret last changed, as the keychain would say.
  public func setModified(_ date: Date, of name: String) {
    lock.withLock { dates[name] = date }
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

  public func all() throws -> [(name: String, data: Data)] {
    lock.withLock { items.map { ($0.key, $0.value) } }
  }

  /// Every secret's name.
  public var names: [String] {
    lock.withLock { Array(items.keys) }
  }
}
