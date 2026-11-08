import CryptoKit
import Foundation

/// An item as the apps see it: decrypted fields of one kind.
public struct VaultItem: Sendable, Identifiable, Equatable {
  public let id: String
  public let kind: String
  public let fields: ItemFields

  public var values: [String: JSONValue] { fields.values }
  public var isDeleted: Bool { fields.isDeleted }
  /// When any field last changed, on whichever device.
  public var modified: Date {
    Date(timeIntervalSince1970: Double(fields.latestClock.millis) / 1000)
  }
}

/// A record as CloudKit holds it: the encrypted payload, the key it was sealed with, and CloudKit's own
/// bookkeeping (the change tag and the archived system fields).
public struct RemoteRecord: Sendable, Equatable {
  public var id: String
  public var keyID: String
  public var payload: Data
  public var changeTag: String?
  public var systemFields: Data?

  public init(id: String, keyID: String, payload: Data, changeTag: String?, systemFields: Data?) {
    self.id = id
    self.keyID = keyID
    self.payload = payload
    self.changeTag = changeTag
    self.systemFields = systemFields
  }
}

/// A local change on its way to CloudKit.
public struct OutgoingRecord: Sendable, Equatable {
  public var id: String
  public var keyID: String
  public var payload: Data
  public var systemFields: Data?
  /// The item's version when the record was built: a send only clears the outbox when nothing changed since.
  public var version: Int64
}

/// The shared store: one SQLite file in the app group container that every v57 app on the device opens.
///
/// - Every item is one row: id, kind, and its fields sealed with AES-GCM under a vault key, bound to the store, the
///   id and the kind (`VaultItemSeal`, format 2). Format 2 has a file of its own, which a store builds once, on open, from
///   the file old builds use and leave alone (`VaultStore+Format`). The tables never change; new fields live inside the
///   payload.
/// - Each write stamps the changed fields with a `HybridClock` and puts the item in the `outbox`. The app
///   that wrote sends it (it leases the outbox row); if it quits first, the lease runs out and any other app
///   sends it, so nothing is lost and nothing is sent twice.
/// - Records from CloudKit merge field by field with the local copy (`ItemFields.merged`). A record whose
///   change tag the store already has is skipped, so every app on the device can fetch the same changes.
/// - After every write the store posts a Darwin notification; the other apps reload.
///
/// Thread-safe: calls are serialized, and SQLite's lock serializes the apps.
public final class VaultStore: @unchecked Sendable {
  public let directory: URL
  public let deviceID: String
  /// Who leases outbox rows: this process.
  public let owner: String
  let keys: VaultKeyProvider

  /// The new file, or the old file while the store waits to build it (`_isWaiting`).
  var database: SQLiteConnection
  private let lock = NSRecursiveLock()
  let notifier: VaultChangeNotifier?
  /// Keys that seal one kind of item instead of the vault key, and open items that name them: the recovery
  /// blobs, which a device that lost the vault keys reads with a key derived from the recovery key
  /// (`VaultRecovery`). Kept in memory only; the rows look like any other.
  private var kindKeys: [String: (id: String, key: SymmetricKey)] = [:]
  var extraKeys: [String: SymmetricKey] = [:]

  /// See `VaultStore+Format.swift`.
  var _formatFinished = false
  var _formatError: String?
  /// The store reads the old file, read-only, until it can build the new one.
  var _isWaiting = false
  var _legacyAllowed: [String: Data]?
  var _legacyAllowedSource: String?
  var _lastCatchUp: Date?
  var _vaultMark: Date?
  /// The old file as the last import saw it.
  var _oldFileSeen: String?
  /// Set when this build's CloudKit environment isn't the one the vault syncs in (`VaultStore+Environment`).
  var _writeRefusal: VaultEnvironmentMismatch?
  /// While a sweep runs: `withKeySweep`.
  private var _sweepDepth = 0
  private var _sweepKeys: [String: SymmetricKey]?
  let formatTesting: FormatTesting

  /// Set when this process runs a sync engine: its own writes are then leased to it right away, so other
  /// apps leave them alone.
  public var sendsOwnWrites: Bool {
    get { withLock { _sendsOwnWrites } }
    set { withLock { _sendsOwnWrites = newValue } }
  }
  private var _sendsOwnWrites = false

  /// Called after this process wrote (not for changes from CloudKit): the sync engine queues the send.
  public var didWriteLocally: (@Sendable ([String]) -> Void)? {
    get { withLock { _didWriteLocally } }
    set { withLock { _didWriteLocally = newValue } }
  }
  private var _didWriteLocally: (@Sendable ([String]) -> Void)?

  /// Fields merged line by line when two devices changed them (`ItemFields.merged(with:base:textKeys:)`),
  /// by kind.
  public static let textFields: [String: Set<String>] = ["note": ["text"]]

  /// How long a lease on an outbox row lasts before another app may send it.
  public var lease: TimeInterval = 120

  /// Personal's file; an account's is `<account id>.v2.sqlite` beside it.
  public static let fileName = "Vault.v2.sqlite"

  /// What this device's clock says. A test sets a wrong one.
  var wallClock: @Sendable () -> Date = { .now }

  /// The SQLite file.
  public let fileURL: URL
  /// The file old builds use, which this store only reads (`VaultStore+Format`).
  public let legacyFileURL: URL
  /// The account whose records the store holds (`VaultAccount`); nil for Personal.
  public let accountID: String?

  /// The keychain's keys, or keys of the process's own while the secrets are in memory (tests, demo and in-memory
  /// runs): those never touch the keychain.
  public static func defaultKeys() -> VaultKeyProvider {
    VaultSecrets.isInMemory ? MemoryKeyProvider() : KeychainKeyProvider()
  }

  public convenience init(
    directory: URL = VaultConfiguration.defaultDirectory(),
    fileName: String = VaultStore.fileName,
    accountID: String? = nil,
    keys: VaultKeyProvider = VaultStore.defaultKeys(),
    deviceID: String = VaultDevice.id,
    notifier: VaultChangeNotifier? = SystemChangeNotifier(),
    owner: String = VaultStore.processOwner
  ) throws {
    try self.init(
      directory: directory, fileName: fileName, accountID: accountID, keys: keys, deviceID: deviceID, notifier: notifier,
      owner: owner, formatTesting: FormatTesting())
  }

  init(
    directory: URL,
    fileName: String,
    accountID: String?,
    keys: VaultKeyProvider,
    deviceID: String,
    notifier: VaultChangeNotifier?,
    owner: String,
    formatTesting: FormatTesting
  ) throws {
    self.formatTesting = formatTesting
    self.directory = directory
    let name = Self.format2Name(of: fileName)
    fileURL = directory.appendingPathComponent(name)
    legacyFileURL = directory.appendingPathComponent(Self.format1Name(of: name))
    self.accountID = accountID
    self.keys = keys
    self.deviceID = deviceID
    self.notifier = notifier
    self.owner = owner
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: fileURL.path), try Self.hasRows(legacyFileURL) {
      database = try SQLiteConnection(url: legacyFileURL, mode: .readOnly)
      _isWaiting = true
    } else {
      database = try SQLiteConnection(url: fileURL)
      try Self.createTables(in: database)
    }
    prepareFormat()
  }

  /// The process's store at the default location (the app group container), opened on first use; nil when
  /// it can't open. `Vault.shared` uses it, and code off the main actor (an SSH engine checking a host key)
  /// can too.
  public static let shared: VaultStore? = {
    guard let store = try? VaultStore() else { return nil }
    store.checkCloudEnvironment(VaultCloudEnvironment.current)
    // The kit follows the secrets, whichever app changes them. Touches the keychain only with a kit on.
    VaultSecrets.didChange = { name, value in
      try? VaultRecovery(store: store).secretChanged(name, value: value)
    }
    VaultPersonalIdentity.existsElsewhere = { (try? VaultRecovery(store: store).holdsIdentity()) ?? true }
    return store
  }()

  /// Removes a store's file, the old file it came from, SQLite's journals beside them and what a killed build left. A
  /// connection still open keeps reading the removed file until it closes.
  public static func removeFiles(at url: URL) {
    let manager = FileManager.default
    let folder = url.deletingLastPathComponent()
    let name = format2Name(of: url.lastPathComponent)
    for base in [name, format1Name(of: name)] {
      for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(at: folder.appendingPathComponent(base + suffix)) }
    }
    for file in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasPrefix(name + ".") && file.contains(".tmp") {
      try? manager.removeItem(at: folder.appendingPathComponent(file))
    }
  }

  /// This process, as the owner of outbox leases.
  public static let processOwner: String = {
    let bundle = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    return "\(bundle):\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString.prefix(8))"
  }()

  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  /// A vault key by id. Inside a sweep, a key this device lacks costs one read of the keychain in all, not one per row: a
  /// sweep runs under SQLite's write lock, and other apps' opens are waiting on it.
  func vaultKey(id: String) throws -> SymmetricKey? {
    guard _sweepDepth > 0 else { return try keys.key(id: id) }
    if let snapshot = _sweepKeys { return snapshot[id] }
    if let key = try keys.key(id: id) { return key }
    _sweepKeys = try keys.allKeys
    return _sweepKeys?[id]
  }

  func withKeySweep<T>(_ body: () throws -> T) rethrows -> T {
    _sweepDepth += 1
    defer {
      _sweepDepth -= 1
      if _sweepDepth == 0 { _sweepKeys = nil }
    }
    return try body()
  }

  // MARK: Reading

  /// The live (not deleted) items of a kind that this device can decrypt.
  public func items(kind: String) throws -> [VaultItem] {
    try withLock {
      try withKeySweep {
      // Rows with no kind arrived before this device had their key; read them again, it may be here now.
      let rows = try database.query(
        "SELECT id, kind, key_id, payload FROM items WHERE (kind = ? AND deleted = 0) OR kind = ''", [.text(kind)])
      var items: [VaultItem] = []
      for row in rows {
        let origin: PayloadOrigin = row[1].text == "" ? .waiting : .local
        guard let item = try decodeIfItOpens(id: row[0].text!, keyID: row[2].text!, payload: row[3].blob ?? Data(), from: origin)
        else { continue }
        if row[1].text == "", !_isWaiting {
          try database.query(
            "UPDATE items SET kind = ?, deleted = ?, modified = ? WHERE id = ?",
            [
              .text(item.kind), .int(item.isDeleted ? 1 : 0), .double(Self.seconds(item.fields.latestClock)),
              .text(item.id),
            ])
        }
        if item.kind == kind && !item.isDeleted { items.append(item) }
      }
      return items
      }
    }
  }

  /// Every item's id, deleted ones and placeholders too.
  public func allIDs() throws -> [String] {
    try withLock { try database.query("SELECT id FROM items").compactMap { $0[0].text } }
  }

  /// An item by id, deleted or not; nil when missing or not decryptable here. A keychain out of reach throws: nil says
  /// something about the item.
  public func item(id: String) throws -> VaultItem? {
    try withLock { try loadRow(id: id)?.item }
  }

  /// Whether there's a row for this id that doesn't open here: most likely its key hasn't arrived. It counts as there, so
  /// that nothing treats it as deleted.
  public func holdsUnreadableRow(id: String) throws -> Bool {
    try withLock {
      guard let row = try loadRow(id: id) else { return false }
      return row.item == nil
    }
  }

  /// Bumped by every change from any app or from CloudKit: observers compare it to skip needless reloads.
  public var revision: Int64 {
    withLock { (try? meta("revision")).flatMap { Int64($0) } ?? 0 }
  }

  // MARK: Writing

  /// Writes the changed fields of an item, creating it if needed. Fields not in `changes` are kept, so an app
  /// that only knows some of an item's fields never drops the others. Returns whether anything changed.
  @discardableResult
  public func save(id: String, kind: String, changes: [String: JSONValue]) throws -> Bool {
    let changed: Bool = try withLock {
      try openForWriting()
      importOldEditsIfChanged()
      return try database.transaction {
        var fields = ItemFields()
        if let row = try loadRow(id: id) {
          if let item = row.item {
            fields = item.fields
          } else if !row.isRefused {
            throw VaultCrypto.CryptoError.missingKey(row.keyID)
          }
          // A row this store refuses (an old build's write after the migration) opens for nobody: it's replaced.
        }
        let wasDeleted = fields.isDeleted
        var clock = try nextClock()
        // Bringing a deleted item back takes a write later than its delete, whatever the delete's clock says.
        if wasDeleted, let deleted = fields.stamped[ItemFields.deletedKey] { clock = clock.after(deleted.clock) }
        // And so does an id whose row was dropped: everyone who dropped it refuses anything up to that clock.
        if let water = try highWater(id: id) { clock = clock.after(water) }
        var changed = fields.apply(changes, clock: clock)
        // Saving a deleted item brings it back: the new writes are later than the delete.
        if wasDeleted && !changed, !changes.isEmpty {
          fields.stamped[ItemFields.deletedKey] = StampedValue(false, clock: clock)
          changed = true
        }
        guard changed else { return false }
        try clearHighWater(id: id)
        try writeRow(id: id, kind: kind, fields: fields, queue: true)
        try foldDuplicates(of: id, kind: kind)
        try bumpRevision()
        return true
      }
    }
    if changed { didChange(locally: [id]) }
    return changed
  }

  /// Marks an item deleted. The deletion syncs like any write; the row is purged later.
  public func delete(id: String) throws {
    let deleted: Bool = try withLock {
      try openForWriting()
      importOldEditsIfChanged()
      return try database.transaction {
        guard let row = try loadRow(id: id), let item = row.item, !item.isDeleted else { return false }
        var fields = item.fields
        fields.stamped[ItemFields.deletedKey] = StampedValue(true, clock: try nextClock().after(fields.latestClock))
        try writeRow(id: id, kind: item.kind, fields: fields, queue: true)
        try bumpRevision()
        return true
      }
    }
    if deleted { didChange(locally: [id]) }
  }

  /// The vault's mailbox id on a Hub (`HubSync`): `hub-vault` derived for Personal, `hub-vault:<account id>` for an
  /// account, so each has a mailbox of its own under the shared keys.
  public func hubVaultID() throws -> String {
    try derivedID(accountID.map { "hub-vault:\($0)" } ?? "hub-vault")
  }

  /// An id derived from content (a project's remote URL), the same on every device with the same keys.
  public func derivedID(_ text: String) throws -> String {
    try withLock {
      if try idKeyCouldBeWrong() { throw VaultCrypto.CryptoError.idKeyNotHere }
      return try VaultCrypto.derivedID(text, keys: keys)
    }
  }

  // MARK: Outbox (used by the sync engine)

  /// Leases up to `limit` outbox rows that nobody holds (or whose lease ran out), and returns them with the
  /// ones this process already holds. A lease is renewed only by a send attempt (`outgoing`), so an app whose
  /// sync is stuck lets go of its writes after `lease`, and another app sends them.
  public func claimOutbox(limit: Int = 200, now: Date = .now) throws -> [String] {
    try withLock {
      guard !_isWaiting else { return [] }
      return try database.transaction {
        let time = now.timeIntervalSince1970
        let held = try database.query(
          "SELECT id FROM outbox WHERE owner = ? AND until >= ? ORDER BY queued LIMIT ?",
          [.text(owner), .double(time), .int(Int64(limit))]
        ).compactMap { $0[0].text }
        let free = try database.query(
          "SELECT id FROM outbox WHERE owner IS NULL OR until < ? ORDER BY queued LIMIT ?",
          [.double(time), .int(Int64(max(limit - held.count, 0)))]
        ).compactMap { $0[0].text }
        for id in free {
          try database.query(
            "UPDATE outbox SET owner = ?, until = ? WHERE id = ?", [.text(owner), .double(time + lease), .text(id)])
        }
        return held + free
      }
    }
  }

  /// The record to send for an item, if this process holds its outbox lease.
  public func outgoing(id: String, now: Date = .now) throws -> OutgoingRecord? {
    try withLock {
      guard !_isWaiting else { return nil }
      return try database.transaction {
        guard
          let lease = try database.query("SELECT owner, until FROM outbox WHERE id = ?", [.text(id)]).first,
          lease[0].text == owner || (lease[1].double ?? 0) < now.timeIntervalSince1970,
          let row = try database.query(
            "SELECT key_id, payload, system_fields, version FROM items WHERE id = ?", [.text(id)]
          ).first,
          // A row that came over unopened goes up once it's format 2 (`catchUp`): nothing here ever sends format 1.
          VaultItemSeal.parse(row[1].blob ?? Data()) != nil
        else { return nil }
        // Take (or extend) the lease: the record is on its way.
        try database.query(
          "UPDATE outbox SET owner = ?, until = ? WHERE id = ?",
          [.text(owner), .double(now.timeIntervalSince1970 + self.lease), .text(id)])
        return OutgoingRecord(
          id: id, keyID: row[0].text!, payload: row[1].blob ?? Data(), systemFields: row[2].blob,
          version: row[3].int ?? 0)
      }
    }
  }

  /// Records a successful send. Returns true when the item changed while it was on its way, so it must be
  /// sent again.
  ///
  /// `sent` is the payload that went up: the server's copy now, kept as the base of the next text merge.
  @discardableResult
  public func markSent(
    id: String, version: Int64, changeTag: String?, systemFields: Data?, sent: (keyID: String, payload: Data)? = nil
  ) throws -> Bool {
    try withLock {
      try database.transaction {
        try database.query(
          "UPDATE items SET change_tag = ?, system_fields = ? WHERE id = ?",
          [.init(changeTag), .init(systemFields), .text(id)])
        if let sent {
          try setServerCopy(id: id, keyID: sent.keyID, payload: sent.payload)
          try clearRefused(id: id)
        }
        try database.query("DELETE FROM outbox WHERE id = ? AND version <= ?", [.text(id), .int(version)])
        return try !database.query("SELECT 1 FROM outbox WHERE id = ?", [.text(id)]).isEmpty
      }
    }
  }

  /// Gives up this process's lease, so another app can send the row.
  public func releaseLease(id: String) throws {
    try withLock {
      _ = try database.query("UPDATE outbox SET owner = NULL, until = 0 WHERE id = ? AND owner = ?", [.text(id), .text(owner)])
    }
  }

  /// Forgets CloudKit's copy of an item (the server says it doesn't exist): the next send creates it.
  public func forgetServerRecord(id: String) throws {
    try withLock {
      _ = try database.query("UPDATE items SET change_tag = NULL, system_fields = NULL WHERE id = ?", [.text(id)])
    }
  }

  /// Ids waiting in the outbox, whoever holds them.
  public func pendingIDs() throws -> Set<String> {
    try withLock { Set(try database.query("SELECT id FROM outbox").compactMap { $0[0].text }) }
  }

  public func pendingCount() throws -> Int {
    try withLock { Int(try database.query("SELECT COUNT(*) FROM outbox")[0][0].int ?? 0) }
  }

  // MARK: Records from CloudKit

  public enum ApplyResult: Equatable, Sendable {
    /// The store already had this version.
    case unchanged
    /// The record was merged in; `needsSend` when the local copy had newer fields that now go up.
    case merged(needsSend: Bool)
    /// This device doesn't have the record's key yet; it's kept until the key arrives.
    case undecryptable
    /// The keychain or the disk failed, which says nothing about the record: nothing changed, and `catchUp` applies it
    /// again.
    case deferred
    /// This store doesn't take the record: it's in the old format or under a retired key, or it was moved from another
    /// record or changed. Nothing of it was kept, and it's counted (`VaultFormatStatus`). With `needsSend`, the local copy
    /// goes up over it.
    ///
    /// A record in the old format stays where it is unless a local edit is waiting: it's its writer's copy, which it
    /// merges when it migrates. A record that was moved or changed is replaced by the readable copy, so the next device
    /// doesn't meet it either, and a device that wrote under a retired key still has its fields, which come back once it
    /// hears of the rotation.
    case refused(needsSend: Bool)
  }

  /// Merges a record fetched from CloudKit (or the server's copy after a conflict) into the store.
  @discardableResult
  public func apply(_ record: RemoteRecord) throws -> ApplyResult {
    let result: ApplyResult = try withLock {
      do {
        try requireOpen()
        return try database.transaction {
          // In this order: a store with a fetch behind it finishes once nothing is deferred, which needs this record read.
          let result = try applyInTransaction(record)
          try forgetDeferred(id: record.id)
          return result
        }
      } catch where !_isWaiting {
        // Thrown when this can't be written either, for the sync engine to hold on to.
        try deferRecord(DeferredRecord(record))
        return .deferred
      }
    }
    if case .merged = result { notifier?.post() }
    return result
  }

  private func applyInTransaction(_ record: RemoteRecord) throws -> ApplyResult {
    let row = try loadRow(id: record.id)
    if let row, let tag = record.changeTag, row.changeTag == tag { return .unchanged }
    let hasPending = try !database.query("SELECT 1 FROM outbox WHERE id = ?", [.text(record.id)]).isEmpty

    let isOldFormat = VaultItemSeal.parse(record.payload) == nil
    let keyID = VaultItemSeal.parse(record.payload)?.keyID ?? record.keyID
    let remote: VaultItem
    var opened: VaultItem?
    do {
      remote = try decode(id: record.id, keyID: keyID, payload: record.payload, from: .network)
      opened = remote
      try checkHighWater(id: record.id, remote)
    } catch VaultCrypto.CryptoError.missingKey {
      // Keep the server's copy until the key arrives. A row stays as it is, whether this device can read it or it's
      // waiting for a key of its own, and the copy waits beside it (`catchUp` merges it): whoever can write to CloudKit
      // doesn't get to blank a record by naming a key this device lacks, and an edit waiting here goes up with the
      // server's tag.
      if row != nil {
        try setServerCopy(id: record.id, keyID: keyID, payload: record.payload)
        try setServerFields(id: record.id, changeTag: record.changeTag, systemFields: record.systemFields)
        try addWaitingServerCopy(record.id)
      } else {
        try database.query(
          """
          INSERT INTO items(id, kind, key_id, payload, version, deleted, modified, change_tag, system_fields)
          VALUES(?, '', ?, ?, 0, 0, 0, ?, ?)
          """,
          [.text(record.id), .text(keyID), .blob(record.payload), .init(record.changeTag), .init(record.systemFields)])
        if isOldFormat { try addLegacyAllowed(id: record.id, payload: record.payload) }
      }
      return .undecryptable
    } catch where Self.payloadIsWrong(error) {
      // A tombstone this store purged, still on the server until the delete lands, isn't anything to tell the user about.
      if opened?.isDeleted == true { return .refused(needsSend: false) }
      try noteRefused(id: record.id, tag: record.changeTag, isOldFormat: isOldFormat)
      guard let local = row?.item else { return .refused(needsSend: false) }
      // The writer's copy, which it merges when it migrates: only an edit waiting here goes up over it, as a normal
      // conflict, and with the record's tag so that it lands.
      if isOldFormat {
        guard hasPending else { return .refused(needsSend: false) }
        try setServerFields(id: record.id, changeTag: record.changeTag, systemFields: record.systemFields)
        return .refused(needsSend: true)
      }
      // The readable copy goes up over the refused one, so the next device doesn't meet it either.
      try setServerFields(id: record.id, changeTag: record.changeTag, systemFields: record.systemFields)
      try writeRow(id: record.id, kind: local.kind, fields: local.fields, queue: true)
      return .refused(needsSend: true)
    }

    try clearRefused(id: record.id)
    try clearHighWater(id: record.id)
    try observe(remote.fields.latestClock)
    let local = row?.item
    let kind = local?.kind.isEmpty == false ? local!.kind : remote.kind
    let base = try serverCopy(id: record.id)
    let merged =
      local.map { $0.fields.merged(with: remote.fields, base: base, textKeys: Self.textFields[kind] ?? []) }
      ?? remote.fields
    var needsSend = false
    if isOldFormat {
      // It's read, and from here on it's this store's: format 2 here, and format 2 on the server.
      let copy = try sealed(kind: remote.kind, fields: remote.fields, id: record.id)
      try setServerCopy(id: record.id, keyID: copy.keyID, payload: copy.payload)
      try writeRow(id: record.id, kind: kind, fields: merged, queue: true)
      try setServerFields(id: record.id, changeTag: record.changeTag, systemFields: record.systemFields)
      needsSend = true
    } else if merged == remote.fields {
      try setServerCopy(id: record.id, keyID: keyID, payload: record.payload)
      // The server's copy has everything: keep its payload as it is.
      try database.query(
        """
        INSERT INTO items(id, kind, key_id, payload, version, deleted, modified, change_tag, system_fields)
        VALUES(?, ?, ?, ?, 1, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, key_id = excluded.key_id, payload = excluded.payload,
          version = items.version + 1, deleted = excluded.deleted, modified = excluded.modified,
          change_tag = excluded.change_tag, system_fields = excluded.system_fields
        """,
        [
          .text(record.id), .text(kind), .text(keyID), .blob(record.payload),
          .int(merged.isDeleted ? 1 : 0), .double(Self.seconds(merged.latestClock)),
          .init(record.changeTag), .init(record.systemFields),
        ])
      // Anything waiting to go up is already on the server.
      try database.query("DELETE FROM outbox WHERE id = ?", [.text(record.id)])
    } else {
      try setServerCopy(id: record.id, keyID: keyID, payload: record.payload)
      // The local copy has newer fields: keep the merge and send it, on top of the server's version.
      try writeRow(id: record.id, kind: kind, fields: merged, queue: true)
      try setServerFields(id: record.id, changeTag: record.changeTag, systemFields: record.systemFields)
      needsSend = true
    }
    _ = hasPending
    if try foldDuplicates(of: record.id, kind: kind) { needsSend = true }
    if local?.fields != merged { try bumpRevision() }
    return .merged(needsSend: needsSend)
  }

  /// CloudKit deleted a record (a purged tombstone): drop it, unless a local edit is waiting to bring it back.
  public func applyDeletion(id: String) throws {
    let changed: Bool = try withLock {
      do {
        try requireOpen()
        return try database.transaction {
          try forgetDeferred(id: id)
          return try applyDeletionInTransaction(id: id)
        }
      } catch where !_isWaiting {
        try deferRecord(DeferredRecord(deletionOf: id))
        return false
      }
    }
    if changed { notifier?.post() }
  }

  private func applyDeletionInTransaction(id: String) throws -> Bool {
        if try !database.query("SELECT 1 FROM outbox WHERE id = ?", [.text(id)]).isEmpty {
          try setServerFields(id: id, changeTag: nil, systemFields: nil)
          return false
        }
        let row = try loadRow(id: id)
        if let item = row?.item { try raiseHighWater(id: id, from: item.fields) }
        let existed = row != nil
        try database.query("DELETE FROM items WHERE id = ?", [.text(id)])
        try database.query("DELETE FROM server_copies WHERE id = ?", [.text(id)])
        if existed { try bumpRevision() }
        return existed
  }

  // MARK: Records from other devices directly (Hub)

  /// Every item as it is sealed, for a transport that keeps its own account of what it sent (`HubSync`): id,
  /// key, ciphertext and version. Placeholders for records this device can't open yet are left out.
  public func sealedRecords() throws -> [OutgoingRecord] {
    try withLock {
      try database.query("SELECT id, key_id, payload, version FROM items WHERE kind != '' AND \(Self.format2Rows)").compactMap { row in
        guard let id = row[0].text, let keyID = row[1].text else { return nil }
        return OutgoingRecord(id: id, keyID: keyID, payload: row[2].blob ?? Data(), systemFields: nil, version: row[3].int ?? 0)
      }
    }
  }

  public enum PeerApplyResult: Equatable, Sendable {
    /// The store had every field already; its version.
    case unchanged(version: Int64)
    /// Fields merged in; the item's new version, and whether the local copy had newer fields the sender lacks.
    case merged(version: Int64, hasNewerFields: Bool)
    /// This device doesn't have the record's key: nothing was stored.
    case undecryptable
    /// This store doesn't take the record (`ApplyResult.refused`): nothing was stored.
    case refused
  }

  /// Merges a record another device sent directly (through a Hub) instead of through CloudKit. Fields merge by
  /// their clocks, so every device ends with the same item whichever order changes arrive in (concurrent edits of
  /// a note's text keep the later one: the three-way text merge needs CloudKit's server copy). CloudKit's
  /// bookkeeping stays as it is, and a change goes into the outbox, so a device with both carries it to iCloud.
  @discardableResult
  public func applyFromPeer(id: String, keyID: String, payload: Data) throws -> PeerApplyResult {
    let result: PeerApplyResult = try withLock {
      try requireOpen()
      return try database.transaction {
        let remote: VaultItem
        var opened: VaultItem?
        do {
          remote = try decode(id: id, keyID: keyID, payload: payload, from: .network)
          opened = remote
          try checkHighWater(id: id, remote)
        } catch VaultCrypto.CryptoError.missingKey {
          return .undecryptable
        } catch where Self.payloadIsWrong(error) {
          if opened?.isDeleted == true { return .refused }
          try noteRefused(id: id, tag: nil, isOldFormat: VaultItemSeal.parse(payload) == nil)
          return .refused
        }
        try clearRefused(id: id)
        try clearHighWater(id: id)
        try observe(remote.fields.latestClock)
        let local = try loadRow(id: id)?.item
        let kind = local?.kind.isEmpty == false ? local!.kind : remote.kind
        let merged = local.map { $0.fields.merged(with: remote.fields) } ?? remote.fields
        let versionNow = { try self.database.query("SELECT version FROM items WHERE id = ?", [.text(id)]).first?[0].int ?? 0 }
        if let local, merged == local.fields { return .unchanged(version: try versionNow()) }
        try writeRow(id: id, kind: kind, fields: merged, queue: true)
        _ = try foldDuplicates(of: id, kind: kind)
        try bumpRevision()
        return .merged(version: try versionNow(), hasNewerFields: merged != remote.fields)
      }
    }
    if case .merged = result { notifier?.post() }
    return result
  }

  // MARK: Backups

  /// Every item this device can open, deleted ones too, for an encrypted backup (`VaultBackup`), and how many rows don't
  /// open here (their key hasn't arrived, or the store refuses them): those aren't in it.
  public func backupItems() throws -> (items: [VaultItem], leftOut: Int) {
    try withLock {
      try withKeySweep {
        var items: [VaultItem] = []
        var leftOut = 0
        for id in try database.query("SELECT id FROM items ORDER BY id").compactMap({ $0[0].text }) {
          if let item = try loadRow(id: id)?.item, !item.kind.isEmpty { items.append(item) } else { leftOut += 1 }
        }
        return (items, leftOut)
      }
    }
  }

  public enum BackupRestoreResult: Equatable, Sendable {
    /// The store had every field already.
    case unchanged
    /// Fields came back, and go up with the next sync.
    case restored
    /// A row was dropped here later than this copy was made (`checkHighWater`): it stays dropped.
    case refused
  }

  /// Puts an item from an encrypted backup back. Its fields merge with the row here by their clocks, as another device's
  /// would, so a later edit made here wins and a deletion made since stays. It's sealed afresh under the current key, the
  /// row's own, and goes into the outbox, so iCloud gets it too. A row here that doesn't open is replaced: the backup's
  /// copy is the one this device can read.
  @discardableResult
  public func restoreFromBackup(_ item: VaultItem) throws -> BackupRestoreResult {
    let result: BackupRestoreResult = try withLock {
      try openForWriting()
      return try database.transaction {
        let local = try loadRow(id: item.id)?.item
        if local == nil {
          do {
            try checkHighWater(id: item.id, item)
          } catch VaultCrypto.CryptoError.refused {
            return .refused
          }
        }
        try observe(item.fields.latestClock)
        let kind = local?.kind.isEmpty == false ? local!.kind : item.kind
        let merged = local.map { $0.fields.merged(with: item.fields) } ?? item.fields
        if let local, merged == local.fields { return .unchanged }
        try clearRefused(id: item.id)
        try writeRow(id: item.id, kind: kind, fields: merged, queue: true)
        _ = try foldDuplicates(of: item.id, kind: kind)
        try bumpRevision()
        return .restored
      }
    }
    if result == .restored { notifier?.post() }
    return result
  }

  /// Forgets everything CloudKit knew and queues every item to go up again (the iCloud data was reset, or another account
  /// signed in). What was fetched and is still to be read stays, as it's the user's data whichever server it came from,
  /// without what it said about that server: a deletion, or a record with nothing read of it, says nothing here.
  ///
  /// With `forAnotherAccount`, this store hasn't seen that server, so it goes back to reading format 1 there during its next
  /// complete fetch, if the vault's month is still on, rather than refusing a device's edits and writing over them. Only
  /// CloudKit's own account change says so. A zone being deleted doesn't, as anyone who can write to CloudKit can do that.
  public func resetServerState(forAnotherAccount: Bool = false) throws {
    try withLock {
      try database.transaction {
        try database.execute(
          "UPDATE items SET change_tag = NULL, system_fields = NULL; DELETE FROM engines WHERE name NOT LIKE 'retry:%'; DELETE FROM server_copies;")
        let now = Date.now.timeIntervalSince1970
        try database.query(
          "INSERT OR REPLACE INTO outbox(id, version, queued, owner, until) SELECT id, version, ?, NULL, 0 FROM items WHERE \(Self.format2Rows)",
          [.double(now)])
        try keepDeferredForAnotherServer()
        // The copies that waited for a key are gone with the rest.
        try database.query("DELETE FROM meta WHERE key = 'format.waiting'")
        if forAnotherAccount {
          try database.query("DELETE FROM meta WHERE key IN ('format', 'format.fetched')")
          _formatFinished = false
        }
      }
    }
  }

  /// Deletes every item (the user deleted the app's iCloud data).
  public func deleteAll() throws {
    try withLock {
      try database.transaction {
        try database.execute("DELETE FROM items; DELETE FROM outbox; DELETE FROM engines; DELETE FROM server_copies;")
        try bumpRevision()
      }
    }
    notifier?.post()
  }

  /// Removes tombstones older than `age` that nothing waits to send, and returns their ids so the sync engine
  /// deletes CloudKit's copies too. A delete goes by id, whatever is on the server, so nothing goes before this store has
  /// seen what's there, and nothing whose record there this store refused: that's another device's edit, which would go
  /// with it.
  public func purgeTombstones(olderThan age: TimeInterval = 30 * 24 * 3600, now: Date = .now) throws -> [String] {
    try withLock {
      guard !_isWaiting, formatIsFinished else { return [] }
      return try database.transaction {
        let cutoff = now.timeIntervalSince1970 - age
        let candidates = try database.query(
          "SELECT id FROM items WHERE deleted = 1 AND modified < ? AND id NOT IN (SELECT id FROM outbox)",
          [.double(cutoff)]
        ).compactMap { $0[0].text }
        var ids: [String] = []
        for id in candidates where try !hasRefused(id: id) { ids.append(id) }
        for id in ids {
          if let item = try loadRow(id: id)?.item { try raiseHighWater(id: id, from: item.fields) }
          try database.query("DELETE FROM items WHERE id = ?", [.text(id)])
          try database.query("DELETE FROM server_copies WHERE id = ?", [.text(id)])
        }
        return ids
      }
    }
  }

  // MARK: Sync engine state

  /// Each app's CloudKit sync engine keeps its own state (what it fetched last), under its bundle id.
  public func engineState(_ name: String) throws -> Data? {
    try withLock { try database.query("SELECT state FROM engines WHERE name = ?", [.text(name)]).first?[0].blob }
  }

  public func setEngineState(_ state: Data?, for name: String) throws {
    try withLock {
      _ = try database.query("INSERT OR REPLACE INTO engines(name, state) VALUES(?, ?)", [.text(name), .init(state)])
    }
  }

  // MARK: Internals

  struct Row {
    let id: String
    let keyID: String
    let changeTag: String?
    let item: VaultItem?
    /// It didn't open because the store refuses it, not for want of a key.
    let isRefused: Bool
  }

  /// What says that a payload itself is wrong. Nothing else does: a keychain out of reach or a busy database says nothing
  /// about it, so those go on being thrown, and a row and its change tag stay as they are until it can be read.
  static func payloadIsWrong(_ error: Error) -> Bool {
    switch error {
    case VaultCrypto.CryptoError.damaged, VaultCrypto.CryptoError.refused, is DecodingError: true
    default: false
    }
  }

  /// A payload's item, or nil when it doesn't open here.
  func decodeIfItOpens(id: String, keyID: String, payload: Data, from origin: PayloadOrigin = .local) throws -> VaultItem? {
    do {
      return try decode(id: id, keyID: keyID, payload: payload, from: origin)
    } catch VaultCrypto.CryptoError.missingKey {
      return nil
    } catch where Self.payloadIsWrong(error) {
      return nil
    }
  }

  func loadRow(id: String) throws -> Row? {
    guard
      let row = try database.query(
        "SELECT key_id, payload, change_tag, kind FROM items WHERE id = ?", [.text(id)]
      ).first
    else { return nil }
    let keyID = row[0].text ?? ""
    var item: VaultItem?
    var isRefused = false
    do {
      item = try decode(id: id, keyID: keyID, payload: row[1].blob ?? Data(), from: row[3].text == "" ? .waiting : .local)
    } catch VaultCrypto.CryptoError.refused {
      isRefused = true
    } catch VaultCrypto.CryptoError.missingKey {
    } catch where Self.payloadIsWrong(error) {
    }
    return Row(id: id, keyID: keyID, changeTag: row[2].text, item: item, isRefused: isRefused)
  }

  // MARK: Dropped rows

  /// A row dropped because CloudKit deleted its record leaves the highest clock it held. CloudKit deletions aren't
  /// authenticated, so without this anyone who can write there could delete a record and then put back any older payload
  /// of it, under a key that isn't retired, which would be taken as new: a host pin rolled back. A row that's there
  /// doesn't need it, as its fields win by clock. The row goes in `meta`, one per dropped id, until a later record or save.
  ///
  /// A clock past `clockSkewBound` doesn't count, for the reason `observe` ignores it: a mark there would refuse every
  /// device's ordinary write to that id until wall time caught up, and a store that never held the row would go on writing,
  /// so they'd never converge. What the mark protects stays protected by the record's other fields. A payload put back
  /// that itself carries such a clock gets past, and it can't be told from a real write by a device whose clock is wrong.
  private func highWater(id: String) throws -> HybridClock? {
    guard let water = try meta("hw.\(id)").flatMap(HybridClock.init), isWithinBound(water) else { return nil }
    return water
  }

  private func isWithinBound(_ clock: HybridClock) -> Bool {
    clock.millis <= Self.millis(wallClock().addingTimeInterval(Self.clockSkewBound))
  }

  /// A row with these fields was dropped.
  private func raiseHighWater(id: String, from fields: ItemFields) throws {
    guard let clock = fields.stamped.values.map(\.clock).filter(isWithinBound).max() else { return }
    if let water = try highWater(id: id), water >= clock { return }
    try setMeta("hw.\(id)", clock.description)
    try observe(clock)
  }

  private func clearHighWater(id: String) throws {
    try database.query("DELETE FROM meta WHERE key = ?", [.text("hw.\(id)")])
  }

  /// Throws when what arrived is no later than what was dropped.
  func checkHighWater(id: String, _ item: VaultItem) throws {
    if let water = try highWater(id: id), item.fields.latestClock <= water { throw VaultCrypto.CryptoError.refused }
  }

  /// Format 1's plaintext.
  struct Payload: Codable {
    var kind: String
    var fields: ItemFields

    enum CodingKeys: String, CodingKey {
      case kind = "k"
      case fields = "f"
    }
  }

  /// Items naming `id` open with `key`, and from now on items of `sealing` (if given) are sealed with it.
  func useKey(_ key: SymmetricKey, id: String, sealing kind: String?) {
    withLock {
      extraKeys[id] = key
      if let kind { kindKeys[kind] = (id, key) }
    }
  }

  /// Where a payload comes from, which decides what it may be.
  enum PayloadOrigin {
    /// A row this device wrote or accepted.
    case local
    /// A placeholder: it arrived before its key did, and was never checked.
    case waiting
    /// CloudKit, a Hub or another device.
    case network
  }

  func decode(id: String, keyID: String, payload: Data, from origin: PayloadOrigin = .local) throws -> VaultItem {
    if let parsed = VaultItemSeal.parse(payload) {
      do {
        return try openFormat2(parsed, id: id, from: origin)
      } catch VaultCrypto.CryptoError.damaged {
        // Format 1 starts with a random nonce, which can look like format 2's header once in 2^40.
        let couldBeFormat1 =
          try _isWaiting || (origin == .network ? !formatIsFinished : isAllowedFormat1(id: id, payload: payload))
        guard couldBeFormat1 else { throw VaultCrypto.CryptoError.damaged }
      }
    }
    if !_isWaiting {
      if origin == .network {
        guard try readsFormat1FromElsewhere() else { throw VaultCrypto.CryptoError.refused }
        if extraKeys[keyID] == nil, try keys.isRetired(keyID) { throw VaultCrypto.CryptoError.refused }
      } else {
        guard try isAllowedFormat1(id: id, payload: payload) else { throw VaultCrypto.CryptoError.refused }
      }
    }
    return try openFormat1(id: id, keyID: keyID, payload: payload)
  }

  /// A format 2 payload. The header's key id is the only one that counts: the column and the record's field are copies.
  func openFormat2(_ parsed: VaultItemSeal.Parsed, id: String, from origin: PayloadOrigin) throws -> VaultItem {
    let kindKey = extraKeys[parsed.keyID]
    let key: SymmetricKey
    if let kindKey {
      key = kindKey
    } else {
      guard let vaultKey = try vaultKey(id: parsed.keyID) else { throw VaultCrypto.CryptoError.missingKey(parsed.keyID) }
      if origin != .local, try keys.isRetired(parsed.keyID) { throw VaultCrypto.CryptoError.refused }
      key = vaultKey
    }
    let opened = try VaultItemSeal.open(parsed, id: id, account: accountBinding, key: key)
    // A key made from the recovery public key seals recovery blobs and nothing else: whoever kept the public key can
    // make it, and must not be able to write anything that matters with it.
    if kindKey != nil, opened.kind != VaultRecoveryBlob.kind { throw VaultCrypto.CryptoError.refused }
    let fields = try JSONDecoder().decode(ItemFields.self, from: opened.fields)
    return VaultItem(id: id, kind: opened.kind, fields: fields)
  }

  /// A format 1 payload, with no check of where it belongs: it has nothing to check against.
  func openFormat1(id: String, keyID: String, payload: Data) throws -> VaultItem {
    guard let key = try extraKeys[keyID] ?? vaultKey(id: keyID) else { throw VaultCrypto.CryptoError.missingKey(keyID) }
    let plaintext = try VaultCrypto.open(payload, key: key)
    let decoded = try JSONDecoder().decode(Payload.self, from: plaintext)
    if extraKeys[keyID] != nil, decoded.kind != VaultRecoveryBlob.kind { throw VaultCrypto.CryptoError.refused }
    return VaultItem(id: id, kind: decoded.kind, fields: decoded.fields)
  }

  /// An item sealed the way a row is.
  func sealed(kind: String, fields: ItemFields, id: String) throws -> (keyID: String, payload: Data) {
    let (keyID, key) = try kindKeys[kind] ?? keys.primary()
    return (
      keyID,
      try VaultItemSeal.seal(
        kind: kind, fields: try JSONEncoder().encode(fields), id: id, account: accountBinding, keyID: keyID, key: key)
    )
  }

  func writeRow(id: String, kind: String, fields: ItemFields, queue: Bool) throws {
    let sealed = try sealed(kind: kind, fields: fields, id: id)
    try database.query(
      """
      INSERT INTO items(id, kind, key_id, payload, version, deleted, modified) VALUES(?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, key_id = excluded.key_id, payload = excluded.payload,
        version = items.version + 1, deleted = excluded.deleted, modified = excluded.modified
      """,
      [
        .text(id), .text(kind), .text(sealed.keyID), .blob(sealed.payload), .int(fields.isDeleted ? 1 : 0),
        .double(Self.seconds(fields.latestClock)),
      ])
    guard queue else { return }
    try self.queue(id: id, version: try database.query("SELECT version FROM items WHERE id = ?", [.text(id)])[0][0].int ?? 0)
  }

  /// Puts an item in the outbox.
  func queue(id: String, version: Int64) throws {
    let now = Date.now.timeIntervalSince1970
    // The writer leases its own change when it can send it, so other apps don't race it to the server.
    let leased = _sendsOwnWrites
    try database.query(
      """
      INSERT INTO outbox(id, version, queued, owner, until) VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET version = excluded.version,
        owner = COALESCE(excluded.owner, outbox.owner), until = MAX(excluded.until, outbox.until)
      """,
      [.text(id), .int(version), .double(now), leased ? .text(owner) : .null, .double(leased ? now + lease : 0)])
  }

  /// The fields of the server's copy this device last saw (sent or fetched), the base of text merges.
  func serverCopy(id: String) throws -> ItemFields? {
    guard let row = try database.query("SELECT key_id, payload FROM server_copies WHERE id = ?", [.text(id)]).first,
      let item = try decodeIfItOpens(id: id, keyID: row[0].text ?? "", payload: row[1].blob ?? Data())
    else { return nil }
    return item.fields
  }

  func setServerCopy(id: String, keyID: String, payload: Data) throws {
    try database.query(
      "INSERT OR REPLACE INTO server_copies(id, key_id, payload) VALUES(?, ?, ?)",
      [.text(id), .text(keyID), .blob(payload)])
  }

  func setServerFields(id: String, changeTag: String?, systemFields: Data?) throws {
    try database.query(
      "UPDATE items SET change_tag = ?, system_fields = ? WHERE id = ?",
      [.init(changeTag), .init(systemFields), .text(id)])
  }

  /// Items of one kind that name the same thing (the `_identity` field, e.g. a project's remote URL) but got
  /// different ids, which happens when two devices add it before seeing each other's copy. The one with the
  /// smaller id takes both copies' fields; the other is deleted. Every device folds the same way, so they
  /// converge. Returns whether `id` changed.
  @discardableResult
  private func foldDuplicates(of id: String, kind: String) throws -> Bool {
    guard let row = try loadRow(id: id), let item = row.item, !item.isDeleted,
      let identity = item.fields["_identity"]?.stringValue, !identity.isEmpty
    else { return false }
    var twins: [VaultItem] = []
    for other in try database.query(
      "SELECT id, key_id, payload FROM items WHERE kind = ? AND deleted = 0 AND id != ?", [.text(kind), .text(id)])
    {
      if let twin = try decodeIfItOpens(id: other[0].text!, keyID: other[1].text!, payload: other[2].blob ?? Data()),
        !twin.isDeleted, twin.fields["_identity"]?.stringValue == identity
      {
        twins.append(twin)
      }
    }
    guard !twins.isEmpty else { return false }
    let all = ([item] + twins).sorted { $0.id < $1.id }
    let survivor = all[0]
    var fields = all.dropFirst().reduce(survivor.fields) { $0.merged(with: $1.fields) }
    fields.stamped[ItemFields.deletedKey] = survivor.fields.stamped[ItemFields.deletedKey]
    if fields != survivor.fields {
      try writeRow(id: survivor.id, kind: kind, fields: fields, queue: true)
    }
    for loser in all.dropFirst() {
      var tombstone = loser.fields
      tombstone.stamped[ItemFields.deletedKey] = StampedValue(true, clock: try nextClock().after(tombstone.latestClock))
      try writeRow(id: loser.id, kind: kind, fields: tombstone, queue: true)
    }
    return survivor.id == id ? fields != survivor.fields : true
  }

  /// How far ahead of this device's wall clock another device's clock may pull this device's. A clock further ahead still
  /// merges as it says, on every device, so all of them keep the same value; it just stays with the fields it's on
  /// (`observe`). Past the bound nothing breaks: a write to such a field goes just past it (`ItemFields.apply`).
  public static let clockSkewBound: TimeInterval = 3600

  /// The next clock for a local write: later than every clock this device issued or saw within the bound.
  ///
  /// A remembered clock past the bound can't be used: it came from before the bound existed, or from this device's own
  /// wall clock while it was wrong. It's dropped here, so a store that saw a far-future clock recovers at its next write.
  private func nextClock() throws -> HybridClock {
    let now = wallClock()
    var last = try meta("clock").flatMap(HybridClock.init) ?? .zero
    if last.millis > Self.millis(now.addingTimeInterval(Self.clockSkewBound)) { last = .zero }
    let next = last.next(now: now, device: deviceID)
    try setMeta("clock", next.description)
    return next
  }

  /// Remembers a clock seen from another device, so later local writes outrank it. One past the bound isn't remembered:
  /// rejecting the field itself on only some devices would split them, so the field merges as usual and only this
  /// device's own clock stays where it is.
  func observe(_ clock: HybridClock) throws {
    guard isWithinBound(clock) else { return }
    let last = try meta("clock").flatMap(HybridClock.init) ?? .zero
    if clock > last { try setMeta("clock", clock.description) }
  }

  private static func millis(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
  }

  func bumpRevision() throws {
    let revision = (try meta("revision").flatMap { Int64($0) } ?? 0) + 1
    try setMeta("revision", String(revision))
  }

  func meta(_ key: String) throws -> String? {
    try database.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?[0].text
  }

  func setMeta(_ key: String, _ value: String) throws {
    try database.query("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text(key), .text(value)])
  }

  func didChange(locally ids: [String]) {
    notifier?.post()
    didWriteLocally?(ids)
  }

  private static func seconds(_ clock: HybridClock) -> Double {
    Double(clock.millis) / 1000
  }
}
