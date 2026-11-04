import CryptoKit
import Foundation

/// The optional recovery key: if iCloud Keychain loses the keys, it brings back the vault keys, the personal
/// identity, every folder key and the secrets kept in the keychain.
///
/// - `create` makes a random secret (`RecoverySecret`), keeps only its public key (`VaultRecoveryKey`), seals every
///   key there is to it (`VaultRecoveryBlob`) and returns the kit, the only time the secret is shown.
/// - Any device then seals new keys to the public key without the secret: call the `wrap` hooks when a vault key,
///   the identity or a folder key appears, or `wrapMissing` (cheap, idempotent) after a sync.
/// - `check` tells whether typed words are the current key; `replace` makes a new kit, rotates the vault key so an old
///   kit doesn't give the current one, and deletes the old blobs; `turnOff` deletes every blob, in the store (and so in
///   CloudKit) and on the remotes given.
/// - `recover` opens every blob with the secret, from the synced records and from folders' remotes; `restore` writes
///   back the keys that open records here, and makes a new key current.
/// - A secret's blob follows it: `VaultSecrets.didChange` (from `VaultStore.shared`) and `wrapMissing` seal a new value,
///   and a deleted secret's blob is emptied before it's deleted.
///
/// What it covers: `VaultSecrets` (logins, one-time codes, cards, passkeys, connection passwords, imported SSH keys kept
/// by Database as `database.sshkey.<uuid>`). What it doesn't: a device's own key (it stays on the device), Hub keys and
/// the GitHub sign-in (kept elsewhere; signing in again replaces them), and what Shell keeps in its own keychain service.
///
/// Off until the user creates it. Nothing here prompts, schedules or reminds: `isOn` is all the state there is.
public struct VaultRecovery: Sendable {
  public let store: VaultStore
  /// The vault keys to wrap (the store's own by default).
  public let keys: any VaultKeyProvider
  /// Where the personal identity is read from (`VaultPersonalIdentity.backing` by default).
  public let identityBacking: any VaultSecretBacking
  /// Where the secrets to seal are (`VaultSecrets.backing` by default).
  public let secretBacking: any VaultSecretBacking

  public init(
    store: VaultStore, keys: (any VaultKeyProvider)? = nil, identity: (any VaultSecretBacking)? = nil,
    secrets: (any VaultSecretBacking)? = nil
  ) {
    self.store = store
    self.keys = keys ?? store.keys
    identityBacking = identity ?? VaultPersonalIdentity.backing
    secretBacking = secrets ?? VaultSecrets.backing
  }

  // MARK: State

  /// The current recovery key's public part; nil when it is off.
  public var key: VaultRecoveryKey? { try? current() }

  public var isOn: Bool { key != nil }

  /// The current key, after telling the store how its blobs are sealed.
  @discardableResult
  func current() throws -> VaultRecoveryKey? {
    guard let key = try store.record(VaultRecoveryKey.self, id: VaultRecoveryKey.recordID), key.publicKey.count == 32
    else { return nil }
    let recordKey = key.recordKey
    store.useKey(recordKey.key, id: recordKey.id, sealing: VaultRecoveryBlob.kind)
    return key
  }

  /// The blob records this device can read (those of the current key, and of any key `recover` was given).
  public func blobs() throws -> [VaultRecoveryBlob] {
    try current()
    return try store.records(VaultRecoveryBlob.self)
  }

  // MARK: Lifecycle

  /// Makes the recovery key and seals every vault key, the identity and `folderKeys` to it. Returns the kit: show
  /// it once, it can't be shown again.
  public func create(folderKeys: [RecoveryFolderKey] = []) throws -> RecoveryKit {
    guard try current() == nil else { throw RecoveryKeyError.alreadyOn }
    return try start(folderKeys: folderKeys)
  }

  /// A new kit, for a lost or leaked one: makes a new current vault key tied to the new kit and seals every record again
  /// under it (`others`: the account stores beside Personal), re-wraps everything to the new kit, deletes the old
  /// kit's blobs from the store and rewrites the blob files on `remotes`.
  ///
  /// An old kit, with blobs copied before this, no longer gives the current key, and no device seals the new key to it,
  /// even one that hasn't heard of the new kit yet. It still opens what those blobs held then: old vault keys, the
  /// identity, folder keys and the secrets as they were. If a kit leaked, those secrets have to change too.
  public func replace(
    folderKeys: [RecoveryFolderKey] = [], remotes: [RecoveryRemoteFolder] = [], alongWith others: [VaultStore] = []
  ) async throws -> RecoveryKit {
    guard try current() != nil else { throw RecoveryKeyError.off }
    let secret = RecoverySecret.random()
    let key = VaultRecoveryKey(publicKey: secret.publicKey)
    // The record first: killed after it, the new kit was never shown, and the user replaces it again.
    try store.save(key)
    try current()
    try store.rotateKeys(kitCheck: key.check, alongWith: others)
    try wrapMissing(folderKeys: folderKeys)
    let kit = RecoveryKit(secret: secret, created: key.created ?? .now)
    try deleteBlobs(except: kit.check)
    for folder in remotes { try await writeBlobs(to: folder) }
    return kit
  }

  /// Turns the recovery key off: deletes the public key and every blob, in the store (and so in CloudKit) and in
  /// the `recovery/` folder of each remote folder given.
  public func turnOff(remotes: [RecoveryRemoteFolder] = []) async throws {
    let key = try current()
    try deleteBlobs(except: nil)
    if key != nil { try store.delete(id: VaultRecoveryKey.recordID) }
    for folder in remotes { try await removeBlobs(from: folder) }
  }

  /// Whether the typed or scanned kit is the current recovery key. Throws for text that isn't a recovery key
  /// (unknown words, a wrong checksum: `RecoveryKeyError`) and when there is none (`off`).
  public func check(_ text: String) throws -> Bool {
    try check(RecoverySecret(parsing: text))
  }

  public func check(_ secret: RecoverySecret) throws -> Bool {
    guard let key = try current() else { throw RecoveryKeyError.off }
    return secret.publicKey == key.publicKey
  }

  private func start(folderKeys: [RecoveryFolderKey]) throws -> RecoveryKit {
    let secret = RecoverySecret.random()
    let key = VaultRecoveryKey(publicKey: secret.publicKey)
    try store.save(key)
    try current()
    try wrapMissing(folderKeys: folderKeys)
    return RecoveryKit(secret: secret, created: key.created ?? .now)
  }

  private func deleteBlobs(except check: String?) throws {
    for blob in try store.records(VaultRecoveryBlob.self) where blob.recoveryKey != check {
      try scrub(blob)
    }
  }

  /// Deletes a blob with nothing in it: a tombstone keeps its fields and syncs, and the box must not outlive the record.
  private func scrub(_ blob: VaultRecoveryBlob) throws {
    try store.save(id: blob.id, kind: VaultRecoveryBlob.kind, changes: ["sealed": .null, "digest": .null])
    try store.delete(id: blob.id)
  }

  // MARK: Wrapping new keys

  /// Seals a vault key to the recovery key, unless it is off or the key is sealed already. Returns whether it
  /// wrote a blob.
  @discardableResult
  public func wrap(vaultKey: SymmetricKey, id: String) throws -> Bool {
    guard let key = try current() else { return false }
    return try wrapVaultKey(vaultKey, id: id, to: key)
  }

  /// A key a kit's replacement made is sealed to that kit alone, so a device still on the old kit leaves it out.
  private func wrapVaultKey(_ vaultKey: SymmetricKey, id: String, to key: VaultRecoveryKey) throws -> Bool {
    if let bound = try keys.kitCheck(forKey: id), bound != key.check { return false }
    return try wrap(vaultKey.withUnsafeBytes { Data($0) }, content: .vaultKey, keyID: id, folderID: nil, to: key)
  }

  /// Seals the personal identity (when it is made, or arrives on a device that had none).
  @discardableResult
  public func wrap(identity: PersonalIdentity) throws -> Bool {
    guard let key = try current() else { return false }
    return try wrap(identity.rawRepresentation, content: .identity, keyID: Self.keyID(of: identity), folderID: nil, to: key)
  }

  /// Seals a folder key (a new folder, or a rotated key). Call `writeBlobs(to:)` after it for a folder on a remote.
  @discardableResult
  public func wrap(folderKey: RecoveryFolderKey) throws -> Bool {
    guard let key = try current() else { return false }
    return try wrap(folderKey.keyData, content: .folderKey, keyID: folderKey.keyID, folderID: folderKey.folderID, to: key)
  }

  private func stableIDKeyIfHere() throws -> Data? {
    do {
      return try keys.stableIDKey().withUnsafeBytes { Data($0) }
    } catch VaultCrypto.CryptoError.idKeyNotHere {
      return nil
    }
  }

  /// Seals every vault key this device has, the identity, `folderKeys` and the secrets, skipping those sealed already.
  /// A secret whose value changed is sealed again; one that's gone goes, once its record is deleted (one missing while
  /// its record lives may simply not have arrived here). Reads the keychain only with a kit on. Returns how many it
  /// sealed; 0 when the recovery key is off.
  @discardableResult
  public func wrapMissing(folderKeys: [RecoveryFolderKey] = []) throws -> Int {
    guard let key = try current() else { return 0 }
    var count = 0
    for (id, vaultKey) in try keys.allKeys.sorted(by: { $0.key < $1.key }) {
      if try wrapVaultKey(vaultKey, id: id, to: key) { count += 1 }
    }
    // Without it here yet, a device that has it seals it.
    if let idKey = try stableIDKeyIfHere(), try wrap(idKey, content: .idKey, keyID: "id", folderID: nil, to: key) { count += 1 }
    if let identity = try identityBacking.read(VaultPersonalIdentity.account).map(PersonalIdentity.init),
      try wrap(identity.rawRepresentation, content: .identity, keyID: Self.keyID(of: identity), folderID: nil, to: key)
    {
      count += 1
    }
    for folderKey in folderKeys
    where try wrap(folderKey.keyData, content: .folderKey, keyID: folderKey.keyID, folderID: folderKey.folderID, to: key) {
      count += 1
    }
    // Only where every secret can be read: Vault and its AutoFill extension. Elsewhere there'd be no telling a secret
    // that's gone from one out of reach. What another app changes it seals itself (`secretChanged`).
    guard secretBacking.seesEverySecret else { return count }
    let secrets = try secretBacking.all().filter { Self.isCovered(secret: $0.name) }
    for secret in secrets.sorted(by: { $0.name < $1.name }) where try wrap(secret: secret.data, name: secret.name, to: key) {
      count += 1
    }
    let names = Set(secrets.map(\.name))
    for blob in try store.records(VaultRecoveryBlob.self)
    where blob.recoveryKey == key.check && blob.content == .secret && !names.contains(blob.keyID) {
      // A login's password that moved (`VaultSecretMove`) has its blob under the new name by now: the old box goes.
      if blob.keyID.hasPrefix("password."), names.contains(VaultSecrets.loginSecret(String(blob.keyID.dropFirst("password.".count)))) {
        try scrub(blob)
      } else if let owner = Self.owner(ofSecret: blob.keyID), try store.item(id: owner)?.isDeleted == true {
        try scrub(blob)
      }
    }
    return count
  }

  /// Keeps a secret's blob up to date when it's set, or empties and deletes it when it's gone. Does nothing with the
  /// recovery key off.
  public func secretChanged(_ name: String, value: Data?) throws {
    guard Self.isCovered(secret: name), let key = try current() else { return }
    if let value {
      try wrap(secret: value, name: name, to: key)
    } else {
      let id = VaultRecoveryBlob.id(publicKey: key.publicKey, content: .secret, keyID: name, folderID: nil)
      if let blob = try store.record(VaultRecoveryBlob.self, id: id) { try scrub(blob) }
    }
  }

  /// The secret that keys the digests: in the keychain with the secrets, not under the vault key, so the digest says
  /// nothing to whoever has the vault key but not the secrets.
  static let digestSecret = "recovery.digest"

  /// Whether a keychain item is one of the secrets the kit covers. The identity has a blob of its own.
  static func isCovered(secret name: String) -> Bool {
    name != digestSecret && name != VaultPersonalIdentity.account && !name.hasPrefix(VaultSecretMove.supersededPrefix)
  }

  /// The record a secret belongs to, for those named after one.
  static func owner(ofSecret name: String) -> String? {
    for prefix in ["password.", "login.", "otp.", "card.number.", "card.code.", "passkey."] where name.hasPrefix(prefix) {
      return String(name.dropFirst(prefix.count))
    }
    return nil
  }

  private func digestKey() throws -> SymmetricKey {
    if let stored = try secretBacking.read(Self.digestSecret) { return SymmetricKey(data: stored) }
    let made = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    if try secretBacking.addNew(made, named: Self.digestSecret, label: "v57 recovery digest") { return SymmetricKey(data: made) }
    return SymmetricKey(data: try secretBacking.read(Self.digestSecret) ?? made)
  }

  /// Seals a secret unless the blob already holds this value. Returns whether it wrote.
  ///
  /// An app outside the secrets group can't read the digests' key. It seals what it changed anyway, since that takes only
  /// the public key, and leaves the digest out; Vault adds it the next time it looks, by sealing the value once more.
  @discardableResult
  private func wrap(secret value: Data, name: String, to key: VaultRecoveryKey) throws -> Bool {
    let digest = try secretBacking.seesEverySecret
      ? Data(HMAC<SHA256>.authenticationCode(for: Data(name.utf8) + [0] + value, using: digestKey()))
        .map { String(format: "%02x", $0) }.joined()
      : nil
    let id = VaultRecoveryBlob.id(publicKey: key.publicKey, content: .secret, keyID: name, folderID: nil)
    if let digest, try store.record(VaultRecoveryBlob.self, id: id)?.digest == digest { return false }
    var blob = try VaultRecoveryBlob.seal(value, publicKey: key.publicKey, content: .secret, keyID: name, folderID: nil)
    blob.digest = digest
    try store.save(blob)
    return true
  }

  private func wrap(
    _ plaintext: Data, content: VaultRecoveryBlob.Content, keyID: String, folderID: String?, to key: VaultRecoveryKey
  ) throws -> Bool {
    let id = VaultRecoveryBlob.id(publicKey: key.publicKey, content: content, keyID: keyID, folderID: folderID)
    if try store.record(VaultRecoveryBlob.self, id: id) != nil { return false }
    let blob = try VaultRecoveryBlob.seal(
      plaintext, publicKey: key.publicKey, content: content, keyID: keyID, folderID: folderID)
    try store.save(blob)
    return true
  }

  /// The identity's blob id part: its agreement key's fingerprint, so a different identity gets its own blob.
  static func keyID(of identity: PersonalIdentity) -> String {
    SHA256.hash(data: identity.agreementKey.publicKey.rawRepresentation).prefix(8)
      .map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Remotes

  /// Writes the folder's key blobs into `<folder>/recovery/` on its remote, next to `members`, so the folder can
  /// be recovered with just the remote and the kit, and deletes blob files of older keys there. Writes nothing
  /// while the recovery key is off.
  public func writeBlobs(to folder: RecoveryRemoteFolder) async throws {
    guard let key = try current() else { return }
    let blobs = try store.records(VaultRecoveryBlob.self).filter {
      $0.recoveryKey == key.check && $0.content == .folderKey && $0.folderID == folder.folderID
    }
    for blob in blobs {
      try await folder.remote.write(blob.fileData, to: RemotePath.join(folder.directory, blob.id))
    }
    let keep = Set(blobs.map(\.id))
    for file in try await folder.files() where !keep.contains(file.name) {
      try await folder.remote.delete(file.path)
    }
  }

  /// Deletes the folder's `recovery/` folder on its remote.
  public func removeBlobs(from folder: RecoveryRemoteFolder) async throws {
    guard try await folder.remote.stat(folder.directory)?.isDirectory == true else { return }
    for file in try await folder.files() { try await folder.remote.delete(file.path) }
    if try await folder.remote.list(folder.directory).isEmpty { try await folder.remote.delete(folder.directory) }
  }

  /// The blob files in the folder's `recovery/` folder on its remote (damaged ones left out).
  public func readBlobs(from folder: RecoveryRemoteFolder) async throws -> [VaultRecoveryBlob] {
    var blobs: [VaultRecoveryBlob] = []
    for file in try await folder.files() {
      if let blob = try? VaultRecoveryBlob(id: file.name, fileData: try await folder.remote.read(file.path)) {
        blobs.append(blob)
      }
    }
    return blobs
  }

  // MARK: Recovering

  /// Opens every blob sealed to the typed or scanned kit: the synced records, and the blob files of `remotes`
  /// (for folders whose records are gone with the Apple ID). Works without the vault keys. Throws
  /// `doesNotMatch` when nothing was sealed to this key.
  public func recover(_ text: String, remotes: [RecoveryRemoteFolder] = []) async throws -> RecoveredKeys {
    let secret = try RecoverySecret(parsing: text)
    var blobs = try storedBlobs(for: secret)
    for folder in remotes { blobs += try await readBlobs(from: folder).filter { $0.recoveryKey == secret.check } }
    return try open(blobs, with: secret)
  }

  /// `recover` from the synced records only.
  public func recover(_ secret: RecoverySecret) throws -> RecoveredKeys {
    try open(storedBlobs(for: secret), with: secret)
  }

  private func storedBlobs(for secret: RecoverySecret) throws -> [VaultRecoveryBlob] {
    // The blob records open with a key derived from the public key, which the secret gives without the record.
    let recordKey = VaultRecoveryKey(publicKey: secret.publicKey).recordKey
    store.useKey(recordKey.key, id: recordKey.id, sealing: nil)
    try current()
    return try store.records(VaultRecoveryBlob.self).filter { $0.recoveryKey == secret.check }
  }

  private func open(_ blobs: [VaultRecoveryBlob], with secret: RecoverySecret) throws -> RecoveredKeys {
    guard !blobs.isEmpty else { throw RecoveryKeyError.doesNotMatch }
    var result = RecoveredKeys()
    var identityDate: Date?
    var opened = 0
    for blob in blobs {
      guard let plaintext = try? blob.open(with: secret) else {
        result.damaged += 1
        continue
      }
      opened += 1
      switch blob.content {
      case .vaultKey where plaintext.count == 32:
        result.vaultKeys[blob.keyID] = SymmetricKey(data: plaintext)
      case .identity:
        guard let identity = try? PersonalIdentity(rawRepresentation: plaintext) else {
          result.damaged += 1
          continue
        }
        // Newest wins, if the identity was ever made again.
        if result.identity == nil || (blob.created ?? .distantPast) > (identityDate ?? .distantPast) {
          result.identity = identity
          identityDate = blob.created
        }
      case .folderKey where plaintext.count == 32:
        let key = RecoveryFolderKey(folderID: blob.folderID ?? "", keyID: blob.keyID, keyData: plaintext)
        if !result.folderKeys.contains(key) { result.folderKeys.append(key) }
      case .secret:
        result.secrets[blob.keyID] = plaintext
      case .idKey where plaintext.count == 32:
        result.idKey = SymmetricKey(data: plaintext)
      case .idKey:
        result.damaged += 1
      case .vaultKey, .folderKey:
        result.damaged += 1
      case nil:
        break  // a kind of key a newer build wraps
      }
    }
    guard opened > 0 else { throw RecoveryKeyError.damaged }
    result.folderKeys.sort { ($0.folderID, $0.keyID) < ($1.folderID, $1.keyID) }
    return result
  }

  // MARK: Restoring

  /// Writes back what `recover` opened, to iCloud Keychain by default, from where it syncs to the user's other devices.
  ///
  /// A blob is sealed with the public key alone, so anyone who has that key could add one naming a key of their own. So:
  /// - A vault key comes back only if it opens a record that's here, in this store or `others` (the account stores), or
  ///   if a key that does vouches for it (a rotation's history: files may still be under a retired key). It's counted in
  ///   `refusedKeys` otherwise.
  /// - Nothing recovered becomes current: a new key is made and rotated to, which retires every restored key. Records
  ///   here under a restored key are sealed again under it, and new ones under a restored key are refused.
  /// - An identity or secret is written only where there's none: it can't replace what this device has.
  ///
  /// Folder keys aren't written: they are in their folders' records, sealed by the vault key, and the caller uses
  /// `folderKeys` only for a folder whose record is gone.
  ///
  /// What's left: someone who kept the public key and can write to CloudKit can add a blob *and* a record under the same
  /// made-up key. That record then opens, as the kit can't tell who sealed a blob. It doesn't become current, and it
  /// needs the public key, which only the user's devices and their copies of the kit have.
  @discardableResult
  public func restore(_ recovered: RecoveredKeys, alongWith others: [VaultStore] = []) throws -> VaultRestoreResult {
    let stores = [store] + others
    var result = VaultRestoreResult()
    var adding: [String: SymmetricKey] = [:]
    for (id, key) in recovered.vaultKeys.sorted(by: { $0.key < $1.key }) {
      if let existing = try keys.key(id: id) {
        if existing == key { result.restoredKeys.append(id) } else { result.refusedKeys.append(id) }
      } else if try stores.contains(where: { try $0.opensARecord(key: key, id: id) }) {
        adding[id] = key
        result.restoredKeys.append(id)
      } else {
        result.refusedKeys.append(id)
      }
    }
    try keys.addKeys(adding)
    // A device that had none of the keys lost its id key too, and may have made another by now.
    if let idKey = recovered.idKey, !adding.isEmpty, adding.count == result.restoredKeys.count {
      try keys.restoreStableIDKey(idKey)
    }
    // Now the history opens, as the keys above read it, placeholder or not.
    _ = try store.resealRows(sealedWith: Set(adding.keys), adopting: true)
    let vouched = try store.keysInHistory(among: recovered.vaultKeys.filter { result.refusedKeys.contains($0.key) })
      .filter { try keys.key(id: $0.key) == nil }
    try keys.addKeys(vouched)
    result.refusedKeys.removeAll { vouched[$0] != nil }
    result.restoredKeys = (result.restoredKeys + vouched.keys).sorted()
    let epoch = try keys.rotate(kitCheck: nil)
    result.currentKey = epoch.keyID
    for store in stores {
      _ = try store.resealRows(sealedWith: Set(adding.keys), adopting: true)
      try store.catchUp()
    }
    if let identity = recovered.identity, try identityBacking.read(VaultPersonalIdentity.account) == nil {
      try identityBacking.write(
        identity.rawRepresentation, named: VaultPersonalIdentity.account, label: "v57 identity (sharing keys)")
      result.identityRestored = true
    }
    for (name, value) in recovered.secrets.sorted(by: { $0.key < $1.key }) where Self.isCovered(secret: name) {
      if try secretBacking.addNew(value, named: name, label: "v57 secret") {
        result.restoredSecrets.append(name)
      } else {
        result.keptSecrets += 1
      }
    }
    try wrapMissing()
    return result
  }
}

/// What `VaultRecovery.restore` did.
public struct VaultRestoreResult: Sendable, Equatable {
  /// The vault keys that are back, by id.
  public var restoredKeys: [String] = []
  /// Vault keys left out: they open no record here, or an id here names another key.
  public var refusedKeys: [String] = []
  /// The new key, current now.
  public var currentKey = ""
  public var identityRestored = false
  public var restoredSecrets: [String] = []
  /// Secrets left as they are: this device has its own.
  public var keptSecrets = 0

  public init() {}
}

/// A folder key for the recovery key, as `VaultFiles` holds it: the `VaultFolder` it belongs to, the key's own id
/// (`FolderKey.id`, named in the folder's files) and its 32 bytes.
public struct RecoveryFolderKey: Sendable, Hashable {
  public var folderID: String
  public var keyID: String
  public var keyData: Data

  public init(folderID: String, keyID: String, keyData: Data) {
    self.folderID = folderID
    self.keyID = keyID
    self.keyData = keyData
  }
}

/// A synced folder on its remote: the blob files of its keys go in `<path>/recovery/`, next to `members`.
public struct RecoveryRemoteFolder: Sendable {
  public var remote: any RemoteFileSystem
  /// The folder's path on the remote.
  public var path: String
  /// The `VaultFolder`'s id.
  public var folderID: String

  public init(remote: any RemoteFileSystem, path: String, folderID: String) {
    self.remote = remote
    self.path = path
    self.folderID = folderID
  }

  public var directory: String { RemotePath.join(path, "recovery") }

  func files() async throws -> [RemoteFileInfo] {
    guard try await remote.stat(directory)?.isDirectory == true else { return [] }
    return try await remote.list(directory).filter { !$0.isDirectory }
  }
}

/// What `VaultRecovery.recover` opened.
public struct RecoveredKeys: Sendable {
  /// The vault's AES keys by id.
  public var vaultKeys: [String: SymmetricKey] = [:]
  public var identity: PersonalIdentity?
  public var folderKeys: [RecoveryFolderKey] = []
  /// The secrets from the keychain, by name.
  public var secrets: [String: Data] = [:]
  /// What ids are hashed with.
  public var idKey: SymmetricKey?
  /// Blobs sealed to this key that didn't open (damaged or changed); the others still did.
  public var damaged = 0

  public init() {}
}
