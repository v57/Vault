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
  /// What `VaultCrypto.derivedID` hashes with: comes from the vault's first key and stays across rotations, so ids never
  /// change. Throws `CryptoError.idKeyNotHere` when this device has only a later key and hasn't heard of the first.
  func stableIDKey() throws -> SymmetricKey
  /// The first key `stableIDKey` comes from, here or not; nil when it was put back by `restoreStableIDKey`, or nothing
  /// says yet.
  func stableIDKeySource() throws -> String?
  /// Puts the id key back (`VaultRecovery.restore`, on a device whose keychain lost it and made another).
  func restoreStableIDKey(_ key: SymmetricKey) throws
  /// Small items beside the keys, out of reach of CloudKit and of whoever can edit the store's file. `synced` ones reach
  /// the user's other devices; the others stay on this one. Names are the caller's; a name that's there stays as it is.
  func marks(prefix: String, synced: Bool) throws -> [(name: String, data: Data)]
  func setMark(_ name: String, data: Data, synced: Bool) throws
  func removeMark(_ name: String, synced: Bool) throws
  /// Every item the keys are kept in, for an encrypted backup (`VaultBackup`): with `synced` the keys, their rotations,
  /// the id keys and the marks; without, this device's own items beside them (its id, its SSH key's blob, its Hub keys).
  func backupItems(synced: Bool) throws -> [VaultKeyBackupItem]
  /// Puts an item from a backup back: added where there's none, or written over what's there with `replacing`. Returns
  /// whether it wrote.
  @discardableResult
  func restoreBackupItem(_ item: VaultKeyBackupItem, synced: Bool, replacing: Bool) throws -> Bool
}

/// A keychain item of the vault's keys, as an encrypted backup holds it (`VaultBackup`).
public struct VaultKeyBackupItem: Codable, Sendable, Equatable {
  public var name: String
  public var data: Data
  public var label: String?

  public init(name: String, data: Data, label: String? = nil) {
    self.name = name
    self.data = data
    self.label = label
  }
}

extension VaultKeyProvider {
  /// For a provider that keeps only keys: those, as `key.<id>`.
  public func backupItems(synced: Bool) throws -> [VaultKeyBackupItem] {
    guard synced else { return [] }
    return try allKeys.sorted { $0.key < $1.key }.map {
      VaultKeyBackupItem(name: VaultKeyRing.keyPrefix + $0.key, data: $0.value.withUnsafeBytes { Data($0) })
    }
  }

  @discardableResult
  public func restoreBackupItem(_ item: VaultKeyBackupItem, synced: Bool, replacing: Bool) throws -> Bool {
    guard synced, item.name.hasPrefix(VaultKeyRing.keyPrefix), item.data.count == 32 else { return false }
    let id = String(item.name.dropFirst(VaultKeyRing.keyPrefix.count))
    guard try key(id: id) == nil else { return false }
    try addKeys([id: SymmetricKey(data: item.data)])
    return true
  }
}

/// Where the keys and their marks are kept: the keychain, or memory for tests.
protocol VaultKeyItems: Sendable {
  func all(synced: Bool) throws -> [(name: String, data: Data)]
  func read(_ name: String, synced: Bool) throws -> Data?
  /// Adds the item unless one exists; returns whether it was added.
  func add(_ data: Data, named name: String, synced: Bool, label: String) throws -> Bool
  func replace(_ data: Data, named name: String, synced: Bool, label: String) throws
  func delete(_ name: String, synced: Bool) throws
  /// The item's label, where the store keeps one.
  func label(of name: String, synced: Bool) throws -> String?
}

extension VaultKeyItems {
  func label(of name: String, synced: Bool) throws -> String? { nil }
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

  func delete(_ name: String, synced: Bool) throws {
    try keychain.delete(name, options: options(synced))
  }

  func label(of name: String, synced: Bool) throws -> String? {
    try keychain.attributes(of: name, options: options(synced))?.label
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

  func delete(_ name: String, synced isSynced: Bool) throws {
    lock.withLock {
      if isSynced { synced[name] = nil } else { local[name] = nil }
    }
  }

  /// What another device's iCloud Keychain delivers: every synced item the other has.
  func receive(from other: MemoryKeyItems) {
    let theirs = other.lock.withLock { other.synced }
    lock.withLock { synced.merge(theirs) { mine, _ in mine } }
  }
}

/// A rotation refused while iCloud is off on this device.
public enum VaultKeyRotationError: LocalizedError, Equatable {
  case iCloudOff

  public var errorDescription: String? {
    switch self {
    case .iCloudOff:
      "iCloud is off on this device, so a new vault key would stay here and your other devices couldn’t read what’s "
        + "sealed with it. Turn iCloud on in Settings › Privacy first."
    }
  }
}

/// The keys, their rotations and the id key, over `VaultKeyItems`. Item names:
///
/// - `key.<id>`: a key. Old builds read every item with this prefix and nothing else.
/// - `keyepoch.<epoch>.<id>`: a rotation made `id` current; its data (`Claim`) names the keys it retired, and the
///   recovery kit it's tied to, if any.
/// - `idkey.<first key's id>`: what ids are hashed with, made from that key. It's the same bytes whoever makes it. Every
///   device goes by the smallest first key it knows of, so two devices that made different ones converge.
/// - `idkey`: an id key `VaultRecovery.restore` put back, which goes first.
/// - `mark.<name>`: `VaultKeyProvider.setMark`.
///
/// **Key ids say where they came from**, because their items arrive one by one, in any order, and a key alone has to say
/// whether ids may come from it. Ids from before this are plain hex. A key made because the keychain was empty is `n`,
/// then the time, so it sorts after all of those and after older `n` keys: a device that made one before the vault's real
/// key arrived neither moves the current key nor ids anywhere else. A rotation's key is `r`: never where ids come from,
/// and never current before the rotation's own item says so.
final class VaultKeyRing: @unchecked Sendable {
  static let keyPrefix = "key."
  static let epochPrefix = "keyepoch."
  static let idKeyName = "idkey"
  static let idKeyPrefix = "idkey."
  static let markPrefix = "mark."
  static let rotationKeyPrefix = "r"

  struct Claim: Codable {
    var kit: String?
    var retired: [String]
  }

  let items: any VaultKeyItems
  /// How long what was read stays good: another device's rotation shows up within this.
  private let staleAfter: TimeInterval
  /// Whether a rotation would stay on this device: iCloud off (`VaultICloud`) for keys in the keychain.
  let rotationStaysHere: @Sendable () -> Bool
  private let lock = NSRecursiveLock()
  private var keys: [String: SymmetricKey] = [:]
  private var epochs: [VaultKeyEpoch: Claim] = [:]
  /// An id key put back by a restore.
  private var restoredIDKey: SymmetricKey?
  /// Id keys by the first key they come from.
  private var idKeys: [String: SymmetricKey] = [:]
  private var loaded: Date?

  init(items: any VaultKeyItems, staleAfter: TimeInterval, rotationStaysHere: @escaping @Sendable () -> Bool = { false }) {
    self.items = items
    self.staleAfter = staleAfter
    self.rotationStaysHere = rotationStaysHere
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
      } else if item.name == Self.idKeyName {
        restoredIDKey = SymmetricKey(data: item.data)
      } else if item.name.hasPrefix(Self.idKeyPrefix) {
        idKeys[String(item.name.dropFirst(Self.idKeyPrefix.count))] = SymmetricKey(data: item.data)
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
        let id = Self.newFirstKeyID()
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
    // With iCloud off the key and its epoch would be this device's alone (security audit H3): the user's other devices
    // would keep sealing with the old key, and refuse nothing.
    guard !rotationStaysHere() else { throw VaultKeyRotationError.iCloudOff }
    return try lock.withLock {
      try load()
      // Before the current key changes, so ids keep coming from the key they always came from. A device that only has a
      // later key can still rotate: whoever has the first key makes it.
      _ = try? stableIDKey()
      let id = Self.newRotationKeyID()
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
      try loadIfStale()
      if let restoredIDKey { return restoredIDKey }
      // No key at all: this may be the vault's first device, or one whose keychain hasn't arrived, and nothing can tell
      // which. The key made here sorts after any real key, so if it's the second, ids here are wrong until the real key
      // arrives and no other device's ever change (`newFirstKeyID`).
      if keys.isEmpty, idKeys.isEmpty { _ = try primary() }
      guard let source = idKeySource else { throw VaultCrypto.CryptoError.idKeyNotHere }
      if let stored = idKeys[source] { return stored }
      guard let key = keys[source] else { throw VaultCrypto.CryptoError.idKeyNotHere }
      let made = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("dev.v57.vault.ids".utf8), outputByteCount: 32)
      _ = try items.add(data(of: made), named: Self.idKeyPrefix + source, synced: true, label: "v57 Vault id key")
      idKeys[source] = made
      return made
    }
  }

  func stableIDKeySource() throws -> String? {
    try lock.withLock {
      try loadIfStale()
      return restoredIDKey == nil ? idKeySource : nil
    }
  }

  /// The smallest first key anything here names: a key, an id key made from one, or what a rotation says it retired.
  private var idKeySource: String? {
    let rotated = Set(epochs.keys.map(\.keyID))
    let known = Array(keys.keys) + Array(idKeys.keys) + epochs.values.flatMap(\.retired)
    return known.filter { !rotated.contains($0) && !$0.hasPrefix(Self.rotationKeyPrefix) }.min()
  }

  func restoreStableIDKey(_ key: SymmetricKey) throws {
    try lock.withLock {
      try items.replace(data(of: key), named: Self.idKeyName, synced: true, label: "v57 Vault id key")
      restoredIDKey = key
    }
  }

  func marks(prefix: String, synced: Bool) throws -> [(name: String, data: Data)] {
    let full = Self.markPrefix + prefix
    return try items.all(synced: synced).filter { $0.name.hasPrefix(full) }.map {
      (String($0.name.dropFirst(Self.markPrefix.count)), $0.data)
    }
  }

  func setMark(_ name: String, data: Data, synced: Bool) throws {
    _ = try items.add(data, named: Self.markPrefix + name, synced: synced, label: "v57 Vault mark")
  }

  func removeMark(_ name: String, synced: Bool) throws {
    try items.delete(Self.markPrefix + name, synced: synced)
  }

  func backupItems(synced: Bool) throws -> [VaultKeyBackupItem] {
    try lock.withLock {
      try items.all(synced: synced).sorted { $0.name < $1.name }.map {
        VaultKeyBackupItem(name: $0.name, data: $0.data, label: try items.label(of: $0.name, synced: synced))
      }
    }
  }

  func restoreBackupItem(_ item: VaultKeyBackupItem, synced: Bool, replacing: Bool) throws -> Bool {
    try lock.withLock {
      let label = item.label ?? Self.label(of: item.name)
      var wrote: Bool
      if replacing, let existing = try items.read(item.name, synced: synced) {
        wrote = existing != item.data
        if wrote { try items.replace(item.data, named: item.name, synced: synced, label: label) }
      } else {
        wrote = try items.add(item.data, named: item.name, synced: synced, label: label)
      }
      if synced { try load() }
      return wrote
    }
  }

  /// The label an item of this name gets when it's made.
  static func label(of name: String) -> String {
    if name.hasPrefix(keyPrefix) { return "v57 Vault key" }
    if name.hasPrefix(epochPrefix) { return "v57 Vault key epoch" }
    if name.hasPrefix(idKeyName) { return "v57 Vault id key" }
    if name.hasPrefix(markPrefix) { return "v57 Vault mark" }
    return "v57 Vault"
  }

  private func data(of key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

  private static func randomHex(_ bytes: Int) -> String {
    (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }

  /// A key made because the keychain was empty: `n`, the time, then something random. Of two first keys the earlier wins.
  static func newFirstKeyID(now: Date = .now) -> String {
    "n" + String(format: "%012llx", Int64(now.timeIntervalSince1970 * 1000)) + randomHex(4)
  }

  static func newRotationKeyID() -> String { rotationKeyPrefix + randomHex(8) }
}

/// The keys in the shared keychain group, synced by iCloud Keychain.
public final class KeychainKeyProvider: VaultKeyProvider, @unchecked Sendable {
  private let ring: VaultKeyRing

  public init(keychain: VaultKeychain = VaultKeychain()) {
    ring = VaultKeyRing(items: KeychainKeyItems(keychain: keychain), staleAfter: 15, rotationStaysHere: { VaultICloud.isOff })
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
  public func stableIDKeySource() throws -> String? { try ring.stableIDKeySource() }
  public func restoreStableIDKey(_ key: SymmetricKey) throws { try ring.restoreStableIDKey(key) }
  public func marks(prefix: String, synced: Bool) throws -> [(name: String, data: Data)] {
    try ring.marks(prefix: prefix, synced: synced)
  }
  public func setMark(_ name: String, data: Data, synced: Bool) throws { try ring.setMark(name, data: data, synced: synced) }
  public func removeMark(_ name: String, synced: Bool) throws { try ring.removeMark(name, synced: synced) }
  public func backupItems(synced: Bool) throws -> [VaultKeyBackupItem] { try ring.backupItems(synced: synced) }
  @discardableResult
  public func restoreBackupItem(_ item: VaultKeyBackupItem, synced: Bool, replacing: Bool) throws -> Bool {
    try ring.restoreBackupItem(item, synced: synced, replacing: replacing)
  }
}

/// Keys held in memory, for tests and previews.
public final class MemoryKeyProvider: VaultKeyProvider, @unchecked Sendable {
  let ring: VaultKeyRing
  let items: MemoryKeyItems

  public convenience init(keys: [String: SymmetricKey] = ["0000000000000001": SymmetricKey(size: .bits256)]) {
    self.init(keys: keys, rotationStaysHere: { false })
  }

  /// `rotationStaysHere` stands in for iCloud being off.
  init(keys: [String: SymmetricKey] = ["0000000000000001": SymmetricKey(size: .bits256)], rotationStaysHere: @escaping @Sendable () -> Bool) {
    items = MemoryKeyItems(
      synced: Dictionary(
        uniqueKeysWithValues: keys.map { (VaultKeyRing.keyPrefix + $0.key, $0.value.withUnsafeBytes { Data($0) }) }))
    ring = VaultKeyRing(items: items, staleAfter: 0, rotationStaysHere: rotationStaysHere)
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
  public func stableIDKeySource() throws -> String? { try ring.stableIDKeySource() }
  public func restoreStableIDKey(_ key: SymmetricKey) throws { try ring.restoreStableIDKey(key) }
  public func marks(prefix: String, synced: Bool) throws -> [(name: String, data: Data)] {
    try ring.marks(prefix: prefix, synced: synced)
  }
  public func setMark(_ name: String, data: Data, synced: Bool) throws { try ring.setMark(name, data: data, synced: synced) }
  public func removeMark(_ name: String, synced: Bool) throws { try ring.removeMark(name, synced: synced) }
  public func backupItems(synced: Bool) throws -> [VaultKeyBackupItem] { try ring.backupItems(synced: synced) }
  @discardableResult
  public func restoreBackupItem(_ item: VaultKeyBackupItem, synced: Bool, replacing: Bool) throws -> Bool {
    try ring.restoreBackupItem(item, synced: synced, replacing: replacing)
  }
}

/// AES-GCM sealing with the vault keys.
public enum VaultCrypto {
  public enum CryptoError: LocalizedError {
    case missingKey(String)
    case damaged
    /// It opens, or could, but this store doesn't take it: the old format, a retired key, or the wrong place.
    case refused
    /// This device hasn't got what ids are hashed with yet, and won't make up another: try again once the keychain has
    /// caught up.
    case idKeyNotHere

    public var errorDescription: String? {
      switch self {
      case .missingKey: "This device doesn't have the key for this data yet. It arrives through iCloud Keychain."
      case .damaged: "The encrypted data is damaged."
      case .refused: "This data was refused: it's in an old format, under a retired key, or was moved from another record."
      case .idKeyNotHere: "This device doesn't have the vault's id key yet. It arrives through iCloud Keychain."
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
  /// After a first-key race a few ids may differ between devices until they've seen each other's keys, which `VaultStore`
  /// folds together by content. Throws `idKeyNotHere` rather than make an id that'd be wrong.
  public static func derivedID(_ text: String, keys: VaultKeyProvider) throws -> String {
    let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: try keys.stableIDKey())
    return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}
