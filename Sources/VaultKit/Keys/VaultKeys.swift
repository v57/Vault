import CryptoKit
import Foundation

/// A key's place in the order of rotations: the highest epoch is current, and the higher id breaks a tie, so two
/// devices that rotated at once settle on the same key. Epoch 0 is every key made before any rotation; it has no
/// keychain item of its own, so a vault that never rotated needs nothing new.
public struct VaultKeyEpoch: Sendable, Hashable, Comparable {
  public let epoch: Int
  public let keyID: String

  public init(epoch: Int, keyID: String) {
    self.epoch = epoch
    self.keyID = keyID
  }

  public static func < (a: VaultKeyEpoch, b: VaultKeyEpoch) -> Bool { (a.epoch, a.keyID) < (b.epoch, b.keyID) }
}

/// The AES-256 keys that encrypt the vault, by id.
///
/// Every item names the key it was sealed with, so a device can hold several: if two devices create the first key at
/// the same moment (both offline, or before iCloud Keychain synced), both keys end up on both devices and everything
/// stays readable. New writes use the `primary` key: the one rotation last made current, else the one with the smallest
/// id, so devices settle on the same key once they've seen each other's.
///
/// **Which key is current lives in the keychain, beside the keys, never in a record:** a record is something CloudKit
/// or a lost device can write. Each rotation adds one synced item (`keyepoch.<epoch>.<id>`), so two rotations at once
/// can't overwrite each other: every device ends with both, and picks the same one.
public protocol VaultKeyProvider: Sendable {
  /// The key new writes are sealed with.
  func primary() throws -> (id: String, key: SymmetricKey)
  /// A key by id; nil when this device doesn't have it (yet).
  func key(id: String) throws -> SymmetricKey?
  /// Every key this device has, by id (the recovery key wraps them all).
  var allKeys: [String: SymmetricKey] { get throws }
  /// Every rotation this device has heard of, its key here or not.
  var keyEpochs: [VaultKeyEpoch] { get throws }
  /// Makes a new key and makes it current. `kitCheck` names the recovery kit the key may be sealed to, when this
  /// rotation replaces the kit (`VaultRecovery.replace`): a device that hasn't heard of the new kit yet leaves it alone.
  @discardableResult
  func rotate(kitCheck: String?) throws -> VaultKeyEpoch
  /// The recovery kit a rotation tied its key to.
  func kitCheck(forKey id: String) throws -> String?
  /// Whether a rotation left this key behind: records sealed with it are refused when they arrive from elsewhere. Never
  /// true in a vault that never rotated. A key no rotation has heard of isn't retired: it may be the next rotation's,
  /// whose keychain items are still arriving one by one.
  func isRetired(_ id: String) throws -> Bool
  /// Adds keys brought back from elsewhere (`VaultRecovery.restore`). One with an id that's here isn't replaced.
  func addKeys(_ keys: [String: SymmetricKey]) throws
  /// What `VaultCrypto.derivedID` hashes with: made once and kept across rotations, so ids never change.
  func stableIDKey() throws -> SymmetricKey
  /// Puts the id key back (`VaultRecovery.restore`, on a device whose keychain lost it and made another).
  func restoreStableIDKey(_ key: SymmetricKey) throws
  /// A small flag beside the keys, out of reach of whoever can edit the store's file. `synced` ones reach the user's
  /// other devices; the others stay on this one.
  func hasMark(_ name: String, synced: Bool) throws -> Bool
  func setMark(_ name: String, synced: Bool) throws
}

/// Where the keys and their marks are kept: the keychain, or memory for tests.
protocol VaultKeyItems: Sendable {
  func all(synced: Bool) throws -> [(name: String, data: Data)]
  func read(_ name: String, synced: Bool) throws -> Data?
  /// Adds the item unless one exists; returns whether it was added.
  func add(_ data: Data, named name: String, synced: Bool, label: String) throws -> Bool
  func replace(_ data: Data, named name: String, synced: Bool, label: String) throws
}

/// The items of `KeychainKeyProvider`, in the keychain.
struct KeychainKeyItems: VaultKeyItems {
  let keychain: VaultKeychain

  private func options(_ synced: Bool, label: String? = nil) -> VaultKeychain.Options {
    .init(synchronizable: synced, label: label)
  }

  func all(synced: Bool) throws -> [(name: String, data: Data)] {
    try keychain.readAll(options: options(synced)).map { ($0.account, $0.data) }
  }

  func read(_ name: String, synced: Bool) throws -> Data? {
    try keychain.read(name, options: options(synced))
  }

  func add(_ data: Data, named name: String, synced: Bool, label: String) throws -> Bool {
    do {
      try keychain.addNew(data, account: name, options: options(synced, label: label))
      return true
    } catch VaultKeychain.KeychainError.status(errSecDuplicateItem) {
      return false
    }
  }

  func replace(_ data: Data, named name: String, synced: Bool, label: String) throws {
    try keychain.write(data, account: name, options: options(synced, label: label))
  }
}

/// Items in memory; `synced` ones may be shared between rings, as iCloud Keychain would.
final class MemoryKeyItems: VaultKeyItems, @unchecked Sendable {
  private let lock = NSLock()
  private var synced: [String: Data] = [:]
  private var local: [String: Data] = [:]

  init(synced: [String: Data] = [:]) {
    self.synced = synced
  }

  func all(synced isSynced: Bool) throws -> [(name: String, data: Data)] {
    lock.withLock { (isSynced ? synced : local).map { ($0.key, $0.value) } }
  }

  func read(_ name: String, synced isSynced: Bool) throws -> Data? {
    lock.withLock { isSynced ? synced[name] : local[name] }
  }

  func add(_ data: Data, named name: String, synced isSynced: Bool, label: String) throws -> Bool {
    lock.withLock {
      if isSynced {
        guard synced[name] == nil else { return false }
        synced[name] = data
      } else {
        guard local[name] == nil else { return false }
        local[name] = data
      }
      return true
    }
  }

  func replace(_ data: Data, named name: String, synced isSynced: Bool, label: String) throws {
    lock.withLock {
      if isSynced { synced[name] = data } else { local[name] = data }
    }
  }

  /// What another device's iCloud Keychain delivers: every synced item the other has.
  func receive(from other: MemoryKeyItems) {
    let theirs = other.lock.withLock { other.synced }
    lock.withLock { synced.merge(theirs) { mine, _ in mine } }
  }
}

/// The keys, their rotations and the id key, over `VaultKeyItems`. Item names:
///
/// - `key.<id>`: a key. Old builds read every item with this prefix and nothing else.
/// - `keyepoch.<epoch>.<id>`: a rotation made `id` current; its data (`Claim`) names the keys it retired, and the
///   recovery kit it's tied to, if any.
/// - `idkey`: what ids are hashed with.
/// - `mark.<name>`: `VaultKeyProvider.setMark`.
final class VaultKeyRing: @unchecked Sendable {
  static let keyPrefix = "key."
  static let epochPrefix = "keyepoch."
  static let idKeyName = "idkey"
  static let markPrefix = "mark."

  struct Claim: Codable {
    var kit: String?
    var retired: [String]
  }

  let items: any VaultKeyItems
  /// How long what was read stays good: another device's rotation shows up within this.
  private let staleAfter: TimeInterval
  private let lock = NSRecursiveLock()
  private var keys: [String: SymmetricKey] = [:]
  private var epochs: [VaultKeyEpoch: Claim] = [:]
  private var idKey: SymmetricKey?
  private var loaded: Date?

  init(items: any VaultKeyItems, staleAfter: TimeInterval) {
    self.items = items
    self.staleAfter = staleAfter
  }

  static func epochName(_ epoch: VaultKeyEpoch) -> String { "\(epochPrefix)\(epoch.epoch).\(epoch.keyID)" }

  private func load() throws {
    for item in try items.all(synced: true) {
      if item.name.hasPrefix(Self.keyPrefix) {
        keys[String(item.name.dropFirst(Self.keyPrefix.count))] = SymmetricKey(data: item.data)
      } else if item.name.hasPrefix(Self.epochPrefix) {
        let parts = item.name.dropFirst(Self.epochPrefix.count).split(separator: ".", maxSplits: 1)
        if parts.count == 2, let epoch = Int(parts[0]) {
          let claim = (try? JSONDecoder().decode(Claim.self, from: item.data)) ?? Claim(kit: nil, retired: [])
          epochs[VaultKeyEpoch(epoch: epoch, keyID: String(parts[1]))] = claim
        }
      }
    }
    loaded = .now
  }

  private func loadIfStale() throws {
    if let loaded, Date.now.timeIntervalSince(loaded) < staleAfter { return }
    do {
      try load()
    } catch {
      // The keychain can be out of reach for a moment; what was read before is still good.
      if keys.isEmpty { throw error }
    }
  }

  /// The highest rotation whose key is here, else the smallest id.
  private var currentID: String? {
    epochs.keys.filter { keys[$0.keyID] != nil }.max()?.keyID ?? keys.keys.min()
  }

  func primary() throws -> (id: String, key: SymmetricKey) {
    try lock.withLock {
      try loadIfStale()
      if keys.isEmpty {
        let id = Self.newKeyID()
        let key = SymmetricKey(size: .bits256)
        _ = try items.add(data(of: key), named: Self.keyPrefix + id, synced: true, label: "v57 Vault key")
        keys[id] = key
      }
      let id = currentID!
      return (id, keys[id]!)
    }
  }

  func key(id: String) throws -> SymmetricKey? {
    try lock.withLock {
      if let key = keys[id] { return key }
      // It may have arrived through iCloud Keychain since the last look.
      try load()
      return keys[id]
    }
  }

  var allKeys: [String: SymmetricKey] {
    get throws {
      try lock.withLock {
        try load()
        return keys
      }
    }
  }

  var keyEpochs: [VaultKeyEpoch] {
    get throws {
      try lock.withLock {
        try loadIfStale()
        return epochs.keys.sorted()
      }
    }
  }

  func kitCheck(forKey id: String) throws -> String? {
    try lock.withLock {
      try loadIfStale()
      return epochs.first { $0.key.keyID == id }?.value.kit
    }
  }

  func isRetired(_ id: String) throws -> Bool {
    try lock.withLock {
      try loadIfStale()
      guard let top = epochs.keys.map(\.epoch).max() else { return false }
      if let own = epochs.keys.first(where: { $0.keyID == id }) { return own.epoch < top }
      return epochs.values.contains { $0.retired.contains(id) }
    }
  }

  func addKeys(_ added: [String: SymmetricKey]) throws {
    try lock.withLock {
      for (id, key) in added.sorted(by: { $0.key < $1.key }) {
        _ = try items.add(data(of: key), named: Self.keyPrefix + id, synced: true, label: "v57 Vault key")
      }
      try load()
    }
  }

  func rotate(kitCheck: String?) throws -> VaultKeyEpoch {
    try lock.withLock {
      try load()
      // Before the current key changes, so ids keep coming from the key they always came from.
      _ = try stableIDKey()
      let id = Self.newKeyID()
      let key = SymmetricKey(size: .bits256)
      let epoch = VaultKeyEpoch(epoch: (epochs.keys.map(\.epoch).max() ?? 0) + 1, keyID: id)
      let claim = Claim(kit: kitCheck, retired: keys.keys.sorted())
      // The key first: killed in between, it's a spare key no rotation names, which changes nothing.
      _ = try items.add(data(of: key), named: Self.keyPrefix + id, synced: true, label: "v57 Vault key")
      _ = try items.add(
        try JSONEncoder().encode(claim), named: Self.epochName(epoch), synced: true, label: "v57 Vault key epoch")
      keys[id] = key
      epochs[epoch] = claim
      return epoch
    }
  }

  func stableIDKey() throws -> SymmetricKey {
    try lock.withLock {
      if let idKey { return idKey }
      if let stored = try items.read(Self.idKeyName, synced: true) {
        let key = SymmetricKey(data: stored)
        idKey = key
        return key
      }
      // The first use: what ids were hashed with until now, the smallest key from before any rotation, so no id changes
      // and it's the same whichever items of a rotation have arrived. Two devices with different keys here (a first-key
      // race) made different ids before too, and iCloud Keychain keeps one of the two items.
      let (primaryID, primaryKey) = try primary()
      let rotated = Set(epochs.keys.map(\.keyID))
      let key = keys.filter { !rotated.contains($0.key) }.min { $0.key < $1.key }?.value ?? keys[primaryID] ?? primaryKey
      let made = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: key, info: Data("dev.v57.vault.ids".utf8), outputByteCount: 32)
      if try !items.add(data(of: made), named: Self.idKeyName, synced: true, label: "v57 Vault id key"),
        let stored = try items.read(Self.idKeyName, synced: true)
      {
        let key = SymmetricKey(data: stored)
        idKey = key
        return key
      }
      idKey = made
      return made
    }
  }

  func restoreStableIDKey(_ key: SymmetricKey) throws {
    try lock.withLock {
      try items.replace(data(of: key), named: Self.idKeyName, synced: true, label: "v57 Vault id key")
      idKey = key
    }
  }

  func hasMark(_ name: String, synced: Bool) throws -> Bool {
    try items.read(Self.markPrefix + name, synced: synced) != nil
  }

  func setMark(_ name: String, synced: Bool) throws {
    _ = try items.add(Data("1".utf8), named: Self.markPrefix + name, synced: synced, label: "v57 Vault mark")
  }

  private func data(of key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

  static func newKeyID() -> String {
    (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }
}

/// The keys in the shared keychain group, synced by iCloud Keychain.
public final class KeychainKeyProvider: VaultKeyProvider, @unchecked Sendable {
  private let ring: VaultKeyRing

  public init(keychain: VaultKeychain = VaultKeychain()) {
    ring = VaultKeyRing(items: KeychainKeyItems(keychain: keychain), staleAfter: 15)
  }

  /// Keychain items are named `key.<id>`.
  static let prefix = VaultKeyRing.keyPrefix

  public func primary() throws -> (id: String, key: SymmetricKey) { try ring.primary() }
  public func key(id: String) throws -> SymmetricKey? { try ring.key(id: id) }
  public var allKeys: [String: SymmetricKey] { get throws { try ring.allKeys } }
  public var keyEpochs: [VaultKeyEpoch] { get throws { try ring.keyEpochs } }
  public func rotate(kitCheck: String?) throws -> VaultKeyEpoch { try ring.rotate(kitCheck: kitCheck) }
  public func kitCheck(forKey id: String) throws -> String? { try ring.kitCheck(forKey: id) }
  public func isRetired(_ id: String) throws -> Bool { try ring.isRetired(id) }
  public func addKeys(_ keys: [String: SymmetricKey]) throws { try ring.addKeys(keys) }
  public func stableIDKey() throws -> SymmetricKey { try ring.stableIDKey() }
  public func restoreStableIDKey(_ key: SymmetricKey) throws { try ring.restoreStableIDKey(key) }
  public func hasMark(_ name: String, synced: Bool) throws -> Bool { try ring.hasMark(name, synced: synced) }
  public func setMark(_ name: String, synced: Bool) throws { try ring.setMark(name, synced: synced) }

  static func newKeyID() -> String { VaultKeyRing.newKeyID() }
}

/// Keys held in memory, for tests and previews.
public final class MemoryKeyProvider: VaultKeyProvider, @unchecked Sendable {
  let ring: VaultKeyRing
  let items: MemoryKeyItems

  public init(keys: [String: SymmetricKey] = ["0000000000000001": SymmetricKey(size: .bits256)]) {
    items = MemoryKeyItems(
      synced: Dictionary(
        uniqueKeysWithValues: keys.map { (VaultKeyRing.keyPrefix + $0.key, $0.value.withUnsafeBytes { Data($0) }) }))
    ring = VaultKeyRing(items: items, staleAfter: 0)
  }

  public func primary() throws -> (id: String, key: SymmetricKey) { try ring.primary() }
  public func key(id: String) throws -> SymmetricKey? { try ring.key(id: id) }

  /// Adds a key, as iCloud Keychain delivering another device's key would.
  public func add(_ key: SymmetricKey, id: String) {
    _ = try? items.add(key.withUnsafeBytes { Data($0) }, named: VaultKeyRing.keyPrefix + id, synced: true, label: "")
  }

  public var allKeys: [String: SymmetricKey] { (try? ring.allKeys) ?? [:] }
  public var keyEpochs: [VaultKeyEpoch] { get throws { try ring.keyEpochs } }
  public func rotate(kitCheck: String?) throws -> VaultKeyEpoch { try ring.rotate(kitCheck: kitCheck) }
  public func kitCheck(forKey id: String) throws -> String? { try ring.kitCheck(forKey: id) }
  public func isRetired(_ id: String) throws -> Bool { try ring.isRetired(id) }
  public func addKeys(_ keys: [String: SymmetricKey]) throws { try ring.addKeys(keys) }
  public func stableIDKey() throws -> SymmetricKey { try ring.stableIDKey() }
  public func restoreStableIDKey(_ key: SymmetricKey) throws { try ring.restoreStableIDKey(key) }
  public func hasMark(_ name: String, synced: Bool) throws -> Bool { try ring.hasMark(name, synced: synced) }
  public func setMark(_ name: String, synced: Bool) throws { try ring.setMark(name, synced: synced) }
}

/// AES-GCM sealing with the vault keys.
public enum VaultCrypto {
  public enum CryptoError: LocalizedError {
    case missingKey(String)
    case damaged
    /// It opens, or could, but this store doesn't take it: the old format, a retired key, or the wrong place.
    case refused

    public var errorDescription: String? {
      switch self {
      case .missingKey: "This device doesn't have the key for this data yet. It arrives through iCloud Keychain."
      case .damaged: "The encrypted data is damaged."
      case .refused: "This data was refused: it's in an old format, under a retired key, or was moved from another record."
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

  /// A keyed hash for ids derived from content (a project's remote URL), so CloudKit sees the id but not what it was
  /// made from. Keyed with the id key, which stays when the current key changes (`VaultKeyProvider.stableIDKey`).
  /// After a first-key race a few ids may differ between devices, which `VaultStore` folds together by content.
  public static func derivedID(_ text: String, keys: VaultKeyProvider) throws -> String {
    let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: try keys.stableIDKey())
    return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}
