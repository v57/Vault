import CryptoKit
import Foundation

/// An encrypted backup of the whole vault in one file the user keeps where they choose, off iCloud: every record of
/// Personal and of each account, the vault keys with their rotations and id keys, the passwords and other secrets of
/// both keychain groups, the personal identity, and this device's own keys (its id, its SSH key's blob, its Hub keys).
///
/// The recovery kit (`VaultRecovery`) keeps its copies in iCloud; this one is for when iCloud loses something: the
/// store, the keychain or both. Restoring it into an empty store and keychain brings everything back
/// (`VaultBackupTests`); restoring it over a vault that's there merges by clock, as a device's edits would, and never
/// replaces a secret, a key or a field that changed since.
///
/// **The file:** `V57-VAULT-BACKUP 1`, a line of JSON (the key derivation's salt and rounds, and when it was made), then
/// the contents sealed with AES-256-GCM, its key derived from the passphrase with PBKDF2-HMAC-SHA256, both lines
/// authenticated with it. Nothing in it is readable without the passphrase, and a changed byte makes it fail to open.
public enum VaultBackup {
  /// What the files are called: `Vault Backup 2026-11-08.v57backup`.
  public static let fileExtension = "v57backup"
  /// The shortest passphrase the app accepts.
  public static let minimumPassphraseLength = 12
  /// PBKDF2 rounds: OWASP's 2023 figure for HMAC-SHA256, about half a second on an Apple chip.
  public static let defaultRounds = 600_000

  static let magic = Data("V57-VAULT-BACKUP 1\n".utf8)

  public enum BackupError: LocalizedError, Equatable {
    case notABackup
    case newerFormat
    case wrongPassphrase
    case shortPassphrase
    case noKeys

    public var errorDescription: String? {
      switch self {
      case .notABackup: "This file isn’t a Vault backup."
      case .newerFormat: "This backup was made by a newer Vault. Update Vault to restore it."
      case .wrongPassphrase: "The passphrase doesn’t open this backup, or the file was changed."
      case .shortPassphrase: "Use a passphrase of at least \(VaultBackup.minimumPassphraseLength) characters."
      case .noKeys: "This device has no vault keys yet, so there’s nothing to back up."
      }
    }
  }

  /// The line before the sealed contents.
  struct Header: Codable, Equatable {
    var version = 1
    var kdf = "PBKDF2-HMAC-SHA256"
    var rounds: Int
    var salt: Data
    var created: Date
  }

  // MARK: Making one

  /// What a backup takes, by default this app's: `stores` are Personal's and the accounts', Personal's first.
  public struct Sources {
    public var stores: [VaultStore]
    public var keys: any VaultKeyProvider
    public var secrets: any VaultSecretBacking
    public var identity: any VaultSecretBacking
    public var deviceID: String
    public var deviceName: String

    public init(
      stores: [VaultStore], keys: (any VaultKeyProvider)? = nil, secrets: (any VaultSecretBacking)? = nil,
      identity: (any VaultSecretBacking)? = nil, deviceID: String? = nil, deviceName: String = ""
    ) {
      self.stores = stores
      self.keys = keys ?? stores.first?.keys ?? VaultStore.defaultKeys()
      self.secrets = secrets ?? VaultSecrets.backing
      self.identity = identity ?? VaultPersonalIdentity.backing
      self.deviceID = deviceID ?? stores.first?.deviceID ?? VaultDevice.id
      self.deviceName = deviceName
    }
  }

  /// Reads everything and seals it: the file's bytes. Throws `shortPassphrase` for a passphrase under
  /// `minimumPassphraseLength`, and `noKeys` on a device that has none.
  public static func make(from sources: Sources, passphrase: String, rounds: Int = defaultRounds) throws -> Data {
    guard passphrase.count >= minimumPassphraseLength else { throw BackupError.shortPassphrase }
    let contents = try contents(of: sources)
    guard !contents.keyItems.isEmpty else { throw BackupError.noKeys }
    return try seal(contents, passphrase: passphrase, rounds: rounds)
  }

  /// What `make` seals.
  static func contents(of sources: Sources) throws -> VaultBackupContents {
    var contents = VaultBackupContents(
      created: .now, deviceID: sources.deviceID, deviceName: sources.deviceName,
      app: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    contents.keyItems = try sources.keys.backupItems(synced: true)
    contents.deviceItems = try sources.keys.backupItems(synced: false).filter { VaultBackupContents.deviceItemNames.contains($0.name) }
    (contents.sharedSecrets, contents.vaultOnlySecrets) = try items(of: sources.secrets)
    (contents.sharedIdentity, contents.vaultOnlyIdentity) = try items(of: sources.identity)
    for store in sources.stores {
      let (items, leftOut) = try store.backupItems()
      contents.stores.append(
        .init(account: store.accountID, items: items.map(VaultBackupContents.Item.init), leftOut: leftOut))
    }
    return contents
  }

  /// A secrets backing's items, by group where it has two.
  private static func items(of backing: any VaultSecretBacking) throws -> (shared: [VaultKeyBackupItem], vaultOnly: [VaultKeyBackupItem]?) {
    func list(_ backing: any VaultSecretBacking) throws -> [VaultKeyBackupItem] {
      try backing.all().sorted { $0.name < $1.name }.map { VaultKeyBackupItem(name: $0.name, data: $0.data) }
    }
    guard let tiers = backing as? VaultSecretTiers else { return (try list(backing), nil) }
    return (try list(tiers.shared), try tiers.vaultOnly.map(list))
  }

  static func seal(_ contents: VaultBackupContents, passphrase: String, rounds: Int) throws -> Data {
    let header = Header(rounds: rounds, salt: randomBytes(32), created: contents.created)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    let headerLine = try encoder.encode(header) + Data("\n".utf8)
    let plaintext = try encoder.encode(contents)
    let key = derivedKey(passphrase, header: header)
    let box = try AES.GCM.seal(plaintext, using: key, authenticating: magic + headerLine)
    guard let combined = box.combined else { throw BackupError.notABackup }
    return magic + headerLine + combined
  }

  // MARK: Opening one

  /// When a file was made, read without the passphrase; nil for a file that isn't a backup.
  public static func created(_ file: Data) -> Date? {
    try? parse(file).header.created
  }

  /// Opens the file with the passphrase.
  public static func open(_ file: Data, passphrase: String) throws -> VaultBackupContents {
    let (header, headerLine, sealed) = try parse(file)
    let key = derivedKey(passphrase, header: header)
    let plaintext: Data
    do {
      plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: magic + headerLine)
    } catch {
      throw BackupError.wrongPassphrase
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(VaultBackupContents.self, from: plaintext)
  }

  private static func parse(_ file: Data) throws -> (header: Header, headerLine: Data, sealed: Data) {
    guard file.starts(with: magic) else { throw BackupError.notABackup }
    let rest = file.dropFirst(magic.count)
    guard let newline = rest.firstIndex(of: UInt8(ascii: "\n")) else { throw BackupError.notABackup }
    let headerLine = Data(rest[rest.startIndex...newline])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let header = try? decoder.decode(Header.self, from: headerLine.dropLast()) else { throw BackupError.notABackup }
    guard header.version == 1, header.kdf == "PBKDF2-HMAC-SHA256" else { throw BackupError.newerFormat }
    guard header.rounds > 0, header.rounds <= 50_000_000, header.salt.count >= 16 else { throw BackupError.notABackup }
    return (header, headerLine, Data(rest[rest.index(after: newline)...]))
  }

  static func derivedKey(_ passphrase: String, header: Header) -> SymmetricKey {
    // The same characters typed on any system give the same bytes.
    let password = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
    return SymmetricKey(data: PBKDF2.sha256(password: password, salt: header.salt, iterations: header.rounds))
  }

  private static func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
  }

  // MARK: Restoring

  /// Where a backup goes back to, by default this app's.
  public struct Targets {
    public var keys: any VaultKeyProvider
    public var secrets: any VaultSecretBacking
    public var identity: any VaultSecretBacking
    /// The store for Personal (nil) or an account, asked once Personal's records are back: an account's store opens only
    /// once its record is there. Nil leaves that account out.
    public var store: (_ account: String?) throws -> VaultStore?

    public init(
      keys: (any VaultKeyProvider)? = nil, secrets: (any VaultSecretBacking)? = nil,
      identity: (any VaultSecretBacking)? = nil, store: @escaping (_ account: String?) throws -> VaultStore?
    ) {
      self.keys = keys ?? VaultStore.defaultKeys()
      self.secrets = secrets ?? VaultSecrets.backing
      self.identity = identity ?? VaultPersonalIdentity.backing
      self.store = store
    }
  }

  /// Puts the backup back: the keys first, then the identity and the secrets, then Personal's records and each account's.
  ///
  /// Nothing here replaces what this device has: a key, secret or identity that's here stays, and a secret of Vault's
  /// own whose value differs is kept as a replaced value (`VaultSecretMove.superseded()`); records merge field by field.
  /// `devicesOwnKeys` also puts back this device's id, SSH key and Hub keys, over what's here: only for the device the
  /// backup was made on, after its keychain was lost (another device can't use the SSH key, and would pass for this one
  /// on a Hub). An SSH key blob this device's Secure Enclave can't open is left out either way.
  @discardableResult
  public static func restore(
    _ contents: VaultBackupContents, to targets: Targets, devicesOwnKeys: Bool = false
  ) throws -> VaultBackupRestoreResult {
    var result = VaultBackupRestoreResult()
    for item in contents.keyItems {
      if try targets.keys.restoreBackupItem(item, synced: true, replacing: false) { result.keys += 1 } else { result.keptKeys += 1 }
    }
    if devicesOwnKeys {
      for item in contents.deviceItems where VaultBackupContents.deviceItemNames.contains(item.name) {
        if item.name == VaultIdentity.account, !deviceKeyOpensHere(item.data) { continue }
        if try targets.keys.restoreBackupItem(item, synced: false, replacing: true) { result.deviceItems += 1 }
      }
    }
    try restoreSecrets(contents.sharedIdentity, contents.vaultOnlyIdentity, into: targets.identity, result: &result)
    try restoreSecrets(contents.sharedSecrets, contents.vaultOnlySecrets, into: targets.secrets, result: &result)
    // Personal first: it holds the accounts.
    for backup in contents.stores.sorted(by: { ($0.account ?? "") < ($1.account ?? "") }) {
      guard let store = try targets.store(backup.account) else {
        result.storesLeftOut.append(backup.account ?? "")
        continue
      }
      for item in backup.items {
        switch try store.restoreFromBackup(item.item) {
        case .restored: result.records += 1
        case .unchanged: result.unchangedRecords += 1
        case .refused: result.refusedRecords += 1
        }
      }
    }
    return result
  }

  /// Whether this device's Secure Enclave opens an SSH key blob (`VaultIdentity.opensHere`); tests replace it.
  nonisolated(unsafe) static var deviceKeyOpensHere: (Data) -> Bool = { VaultIdentity.opensHere($0) }

  private static func restoreSecrets(
    _ shared: [VaultKeyBackupItem], _ vaultOnly: [VaultKeyBackupItem]?, into backing: any VaultSecretBacking,
    result: inout VaultBackupRestoreResult
  ) throws {
    let tiers = backing as? VaultSecretTiers
    func put(_ item: VaultKeyBackupItem, in target: any VaultSecretBacking, keepsReplaced: Bool) throws {
      if try target.addNew(item.data, named: item.name, label: item.label ?? "v57 secret") {
        result.secrets += 1
      } else if try target.read(item.name) == item.data {
        result.unchangedSecrets += 1
      } else {
        result.keptSecrets += 1
        if keepsReplaced, !item.name.hasPrefix(VaultSecretMove.supersededPrefix) {
          try VaultSecretMove.keepSuperseded(item.data, of: item.name, in: target)
        }
      }
    }
    for item in shared { try put(item, in: tiers?.shared ?? backing, keepsReplaced: false) }
    for item in vaultOnly ?? [] {
      guard let target = tiers.map({ $0.vaultOnly }) ?? backing else {
        // An app outside the secrets group can't write them: only Vault restores a backup.
        result.secretsLeftOut += 1
        continue
      }
      try put(item, in: target, keepsReplaced: tiers != nil)
    }
  }
}

/// What a backup holds, once opened.
public struct VaultBackupContents: Codable, Sendable {
  public var created: Date
  /// The device it was made on.
  public var deviceID: String
  public var deviceName: String
  /// The app that made it.
  public var app: String
  /// The vault keys' items: `key.`, `keyepoch.`, `idkey`, `mark.`.
  public var keyItems: [VaultKeyBackupItem] = []
  /// This device's own items beside them, `deviceItemNames`.
  public var deviceItems: [VaultKeyBackupItem] = []
  /// Passwords and other secrets in the group every v57 app lists.
  public var sharedSecrets: [VaultKeyBackupItem] = []
  /// Those only Vault reads (logins' passwords, codes, cards, passkeys); nil when the app that made it couldn't.
  public var vaultOnlySecrets: [VaultKeyBackupItem]?
  public var sharedIdentity: [VaultKeyBackupItem] = []
  public var vaultOnlyIdentity: [VaultKeyBackupItem]?
  public var stores: [Store] = []

  /// This device's own items a backup takes: its id, its SSH key's blob and its Hub keys.
  public static let deviceItemNames: Set<String> = ["device-id", VaultIdentity.account, "hub.device-key", "hub.client-key"]

  public struct Store: Codable, Sendable {
    /// Nil for Personal.
    public var account: String?
    public var items: [Item]
    /// Rows that didn't open on the device that made it, so aren't here.
    public var leftOut: Int
  }

  /// An item with its fields' clocks, so it merges back as it was.
  public struct Item: Codable, Sendable {
    public var id: String
    public var kind: String
    public var fields: ItemFields

    init(_ item: VaultItem) {
      id = item.id
      kind = item.kind
      fields = item.fields
    }

    var item: VaultItem { VaultItem(id: id, kind: kind, fields: fields) }
  }

  init(created: Date, deviceID: String, deviceName: String, app: String) {
    self.created = created
    self.deviceID = deviceID
    self.deviceName = deviceName
    self.app = app
  }

  /// Records, deleted ones left out.
  public var recordCount: Int { stores.reduce(0) { $0 + $1.items.filter { !$0.fields.isDeleted }.count } }
  /// Secrets of both groups and the identity's items.
  public var secretCount: Int { sharedSecrets.count + (vaultOnlySecrets?.count ?? 0) }
  /// Vault keys (not their rotations or marks).
  public var keyCount: Int { keyItems.filter { $0.name.hasPrefix(VaultKeyRing.keyPrefix) }.count }
  public var accountCount: Int { stores.filter { $0.account != nil }.count }
  /// Rows that didn't open on the device that made it.
  public var leftOut: Int { stores.reduce(0) { $0 + $1.leftOut } }
  /// Whether it holds the secrets only Vault reads.
  public var hasVaultOnlySecrets: Bool { vaultOnlySecrets != nil }
}

/// What `VaultBackup.restore` did.
public struct VaultBackupRestoreResult: Sendable, Equatable {
  /// Key items written (keys, rotations, id keys, marks); those already here are `keptKeys`.
  public var keys = 0
  public var keptKeys = 0
  /// This device's own items written over (`devicesOwnKeys`).
  public var deviceItems = 0
  public var secrets = 0
  /// Secrets here with the same value.
  public var unchangedSecrets = 0
  /// Secrets here with another value: those stay, and Vault's own keep the backup's as a replaced value.
  public var keptSecrets = 0
  /// Secrets only Vault can write, left out by another app.
  public var secretsLeftOut = 0
  public var records = 0
  public var unchangedRecords = 0
  /// Records dropped here since the backup was made.
  public var refusedRecords = 0
  /// Accounts whose store didn't open.
  public var storesLeftOut: [String] = []

  public init() {}
}
