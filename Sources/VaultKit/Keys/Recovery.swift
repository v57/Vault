import CryptoKit
import Foundation

/// The optional recovery key: if iCloud Keychain loses the keys, it brings back the vault keys, the personal
/// identity and every folder key.
///
/// - `create` makes a random secret (`RecoverySecret`), keeps only its public key (`VaultRecoveryKey`), seals every
///   key there is to it (`VaultRecoveryBlob`) and returns the kit, the only time the secret is shown.
/// - Any device then seals new keys to the public key without the secret: call the `wrap` hooks when a vault key,
///   the identity or a folder key appears, or `wrapMissing` (cheap, idempotent) after a sync.
/// - `check` tells whether typed words are the current key; `replace` makes a new kit and deletes the old blobs;
///   `turnOff` deletes every blob, in the store (and so in CloudKit) and on the remotes given.
/// - `recover` opens every blob with the secret, from the synced records and from folders' remotes; the caller
///   writes the keys back (`RecoveredKeys.restore`).
///
/// Off until the user creates it. Nothing here prompts, schedules or reminds: `isOn` is all the state there is.
public struct VaultRecovery: Sendable {
  public let store: VaultStore
  /// The vault keys to wrap (the store's own by default).
  public let keys: any VaultKeyProvider
  /// Where the personal identity is read from (`VaultPersonalIdentity.backing` by default).
  public let identityBacking: any VaultSecretBacking

  public init(
    store: VaultStore, keys: (any VaultKeyProvider)? = nil, identity: (any VaultSecretBacking)? = nil
  ) {
    self.store = store
    self.keys = keys ?? store.keys
    identityBacking = identity ?? VaultPersonalIdentity.backing
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

  /// A new kit, for a lost or leaked one: re-wraps everything to the new key, deletes the old key's blobs from the
  /// store and rewrites the blob files on `remotes`.
  public func replace(folderKeys: [RecoveryFolderKey] = [], remotes: [RecoveryRemoteFolder] = []) async throws
    -> RecoveryKit
  {
    guard try current() != nil else { throw RecoveryKeyError.off }
    let kit = try start(folderKeys: folderKeys)
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
      try store.delete(id: blob.id)
    }
  }

  // MARK: Wrapping new keys

  /// Seals a vault key to the recovery key, unless it is off or the key is sealed already. Returns whether it
  /// wrote a blob.
  @discardableResult
  public func wrap(vaultKey: SymmetricKey, id: String) throws -> Bool {
    guard let key = try current() else { return false }
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

  /// Seals every vault key this device has, the identity and `folderKeys`, skipping those sealed already.
  /// Returns how many it sealed; 0 when the recovery key is off.
  @discardableResult
  public func wrapMissing(folderKeys: [RecoveryFolderKey] = []) throws -> Int {
    guard let key = try current() else { return 0 }
    var count = 0
    for (id, vaultKey) in try keys.allKeys.sorted(by: { $0.key < $1.key }) {
      if try wrap(vaultKey.withUnsafeBytes { Data($0) }, content: .vaultKey, keyID: id, folderID: nil, to: key) {
        count += 1
      }
    }
    if let identity = try identityBacking.read(VaultPersonalIdentity.account).map(PersonalIdentity.init),
      try wrap(identity.rawRepresentation, content: .identity, keyID: Self.keyID(of: identity), folderID: nil, to: key)
    {
      count += 1
    }
    for folderKey in folderKeys
    where try wrap(folderKey.keyData, content: .folderKey, keyID: folderKey.keyID, folderID: folderKey.folderID, to: key) {
      count += 1
    }
    return count
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
  /// Blobs sealed to this key that didn't open (damaged or changed); the others still did.
  public var damaged = 0

  public init() {}

  /// Where `KeychainKeyProvider` keeps the vault keys: synchronizable items `key.<id>` of the shared keychain group.
  public static var keychainVaultKeys: any VaultSecretBacking { KeychainSecretBacking(keychain: VaultKeychain()) }

  /// Writes the vault keys and the identity back, to iCloud Keychain by default, from where they sync to the
  /// user's other devices. Folder keys aren't written: they are in their folders' records, sealed by the vault key,
  /// and the caller uses `folderKeys` only for a folder whose record is gone. Tests pass memory backings.
  public func restore(
    vaultKeys vaultKeyBacking: any VaultSecretBacking = RecoveredKeys.keychainVaultKeys,
    identity identityBacking: any VaultSecretBacking = VaultPersonalIdentity.backing
  ) throws {
    for (id, key) in vaultKeys.sorted(by: { $0.key < $1.key }) {
      try vaultKeyBacking.write(
        key.withUnsafeBytes { Data($0) }, named: KeychainKeyProvider.prefix + id, label: "v57 Vault key")
    }
    if let identity {
      try identityBacking.write(
        identity.rawRepresentation, named: VaultPersonalIdentity.account, label: "v57 identity (sharing keys)")
    }
  }
}
