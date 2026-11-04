import CryptoKit
import Foundation

/// How a store moved to payload format 2 (`VaultItemSeal`).
public struct VaultFormatStatus: Sendable, Equatable {
  /// The store made its first complete fetch (or the vault's month ran out), and refuses format 1 from elsewhere.
  public var isFinished: Bool
  /// The store is still reading the old file: the keychain was out of reach, no key has arrived, or the disk was full.
  public var isWaiting: Bool
  /// Rows rewritten to format 2.
  public var resealed: Int
  /// Rows that came over as they were because their key hasn't arrived. They move over once it does.
  public var unreadable: Int
  /// Rows that came over as they were because they wouldn't rewrite. They stay as readable as they were.
  public var notRewritten: Int
  /// Rows whose payload names no kind: they stay readable, under the empty kind.
  public var withoutKind: Int
  /// Rows whose column and payload named different kinds. The payload's kind counts.
  public var kindMismatches: Int
  /// Records this store doesn't take, at the moment: moved, changed, under a retired key, or in the old format.
  public var refused: Int
  /// Of those, the ones in the old format: most likely a device of the user's that hasn't updated. It kept its own copy,
  /// and they merge when it updates.
  public var fromOldDevices: Int
  /// Why it can't do more yet: it tries again.
  public var error: String?

  /// What to tell the user, when there's anything to tell.
  public var note: String? {
    if isWaiting { return "Waiting for this device’s keys to finish updating this vault. Everything here stays readable." }
    switch fromOldDevices {
    case 0: return nil
    case 1: return "1 record came from a device that hasn’t updated yet. It will merge once that device updates."
    default: return "\(fromOldDevices) records came from a device that hasn’t updated yet. They will merge once it updates."
    }
  }
}

/// Lets tests stop a migration at every step, and move the clock.
struct FormatTesting: Sendable {
  enum Stage: Sendable, Equatable {
    /// Every row is in the temporary file.
    case copied
    /// The temporary file is on disk, under its temporary name.
    case beforeMove
    /// The new file is in place.
    case moved
  }

  var stage: (@Sendable (Stage) throws -> Void)?
  var now: @Sendable () -> Date = { .now }
}

/// Payload format 2 lives in its own file, one per store (`Vault.v2.sqlite`, `<account id>.v2.sqlite`). The file being
/// there means the store migrated.
///
/// **The old file is never written.** An app on an old build goes on opening it and never meets a format 2 row, so
/// it can't store one over its own copy, send one, or see an empty store and trash note files. The old file is also the
/// backup: rolling back means removing the new file, and the next open migrates again.
///
/// **Building the new file** happens on open, when the keychain can be read and has a key. A temporary file with a unique
/// name gets every row with its clocks and fields exact: each format 1 row is sealed again and read back. It's then forced
/// to disk (`wal_checkpoint(TRUNCATE)`, `F_FULLFSYNC`) and moved into place without overwriting anything, so a kill leaves
/// a temporary file and no store, two processes get one winner, and a power cut can't leave half a file under the
/// final name. Rows whose key hasn't arrived, or that won't rewrite, come over as they are, on a sealed list.
///
/// **Until then the store reads the old file** and takes no writes, except that a save on a keychain with no keys at all
/// makes a key, as every build did, and builds the file. Without keys the rows can't be read anyway, and a save
/// that failed would lose what the user just typed. `derivedID` waits (`idKeyCouldBeWrong`). The sync engines don't start.
///
/// **What an old app does on this device afterwards:** for 30 days from this store's migration, each open, `catchUp` and
/// local write after the old file changed merges in by field clock the old file's rows that have outbox entries: local edits the old app couldn't send. An old app can send
/// some, a brand new row for one, and those would then be refused by the store they came from, so rows
/// with fields stamped by this device since the migration come over too, those fields only. Nothing else in the old file
/// counts, as what it fetched came from CloudKit. Afterwards the old file is ignored.
///
/// **Format 1 from elsewhere** is read during a store's own first complete fetch after it migrated, and only within 30
/// days of the vault-wide mark, so that a v1 edit waiting on the server merges by clock rather than being overwritten. The
/// mark is a synced keychain item naming the date the first device migrated (`format2.vault.<millis>`), where CloudKit
/// can't touch it; if two devices set it, every device takes the earliest. A store finishes when that fetch completes,
/// not on a timer, so an offline one stays unfinished rather than refusing what it hasn't seen. Past the 30 days a store
/// finishes as soon as it opens: whoever can write to CloudKit can put an old payload at an id it knows, or move one
/// between ids, until then, and only for a store that hasn't completed that fetch.
///
/// **After it finishes, format 1 from elsewhere is refused and left there.** The server's copy is its writer's, and that
/// device merges it when it migrates; the refusal is counted, and persists (`VaultFormatStatus.fromOldDevices`). A
/// local edit still goes up over it as a normal conflict, which is why the row takes the record's tag then. A device
/// that never updates leaves its later edits on the server and in that count.
///
/// A row's format 1 payload in the new file opens only if it's on the sealed list, whatever the store's state.
extension VaultStore {
  /// What a format 2 store's file name ends in.
  static let format2Suffix = ".v2.sqlite"
  private static let formatValue = "2"
  /// Format 1 from the server is read for this long after the vault's first device migrated.
  private static let serverFormat1Window: TimeInterval = 30 * 24 * 3600
  /// The old file is looked at for this long after a store migrated.
  private static let oldFileWindow: TimeInterval = 30 * 24 * 3600
  /// A temporary file older than this was left by a kill. A live build takes seconds.
  private static let leftoverAge: TimeInterval = 600
  private static let vaultMarkPrefix = "format2.vault."
  /// Format 2's first five bytes, for SQL.
  static let format2Rows = "substr(payload, 1, 5) = x'5635374902'"

  /// A store's format 2 file name: any name passed to `init` ends up here, so nothing can open an old file for writing.
  static func format2Name(of name: String) -> String {
    if name.hasSuffix(format2Suffix) { return name }
    return (name.hasSuffix(".sqlite") ? String(name.dropLast(".sqlite".count)) : name) + format2Suffix
  }

  static func format1Name(of name: String) -> String {
    String(format2Name(of: name).dropLast(format2Suffix.count)) + ".sqlite"
  }

  /// What a payload is bound to: the store. Personal has no account id.
  var accountBinding: String { accountID ?? VaultAccount.personal.id }

  /// The tables, the same as they've always been.
  static func createTables(in database: SQLiteConnection) throws {
    try database.transaction {
      try database.execute(
        """
        CREATE TABLE IF NOT EXISTS items(
          id TEXT PRIMARY KEY, kind TEXT NOT NULL, key_id TEXT NOT NULL, payload BLOB NOT NULL,
          version INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, modified REAL NOT NULL DEFAULT 0,
          change_tag TEXT, system_fields BLOB);
        CREATE INDEX IF NOT EXISTS items_kind ON items(kind, deleted);
        CREATE TABLE IF NOT EXISTS outbox(
          id TEXT PRIMARY KEY, version INTEGER NOT NULL, queued REAL NOT NULL, owner TEXT, until REAL NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS engines(name TEXT PRIMARY KEY, state BLOB);
        CREATE TABLE IF NOT EXISTS server_copies(id TEXT PRIMARY KEY, key_id TEXT NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
    }
  }

  /// Whether an old file holds anything to migrate. A file an old build only just made, with no tables yet, doesn't. Any
  /// other failure throws: taking it for empty would make an empty new file, and that would count as migrated.
  static func hasRows(_ url: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let database = try SQLiteConnection(url: url, mode: .readOnly)
    let tables = try database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'items'")
    guard !tables.isEmpty else { return false }
    return try !database.query("SELECT 1 FROM items LIMIT 1").isEmpty
  }

  /// Whether this store refuses format 1 from elsewhere. Another app may have finished it since this one looked.
  var formatIsFinished: Bool {
    if _isWaiting { return false }
    if _formatFinished { return true }
    if (try? meta("format")) == Self.formatValue { _formatFinished = true }
    return _formatFinished
  }

  public var isFormatFinished: Bool { withLock { formatIsFinished } }

  /// Whether this store still reads the old file, and so doesn't sync. `catchUp` tries again.
  public var isWaitingToMigrate: Bool { withLock { _isWaiting } }

  /// Whether a sync engine must fetch everything, rather than from where it left off: a store that hasn't completed its
  /// first fetch since migrating has to see what's on the server.
  public var needsFullFetch: Bool {
    withLock { !formatIsFinished || (try? deferredRecords().contains { $0.unreadSince != nil }) == true }
  }

  public var formatStatus: VaultFormatStatus {
    withLock {
      let report = (try? formatReport()) ?? FormatReport()
      return VaultFormatStatus(
        isFinished: formatIsFinished, isWaiting: _isWaiting, resealed: report.resealed, unreadable: report.unreadable,
        notRewritten: report.notRewritten, withoutKind: report.withoutKind, kindMismatches: report.kindMismatches,
        refused: _isWaiting ? 0 : (try? refusedCount("")) ?? 0,
        fromOldDevices: _isWaiting ? 0 : (try? refusedCount(Self.refusedOld)) ?? 0, error: _formatError)
    }
  }

  private struct FormatReport: Codable {
    var resealed = 0
    var unreadable = 0
    var notRewritten = 0
    var withoutKind = 0
    var kindMismatches = 0
    /// The keys rows named when they came over without opening.
    var missingKeys: [String] = []
  }

  private func formatReport() throws -> FormatReport {
    guard !_isWaiting else { return FormatReport() }
    return try meta("format.report").flatMap { try? JSONDecoder().decode(FormatReport.self, from: Data($0.utf8)) } ?? FormatReport()
  }

  /// Whether this store's rows came from an old file, rather than from nothing.
  var cameFromOldFile: Bool { withLock { !_isWaiting && (try? meta("format.report")) != nil } }

  private func setFormatReport(_ report: FormatReport) throws {
    try setMeta("format.report", String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
  }

  // MARK: Opening

  /// Never throws out of `init`: a store that can't migrate yet still opens, and reads what it has.
  func prepareFormat() {
    withLock {
      do {
        if _isWaiting { try buildFormat2File() }
        _formatError = nil
        settle()
      } catch FormatWait.noKeys {
        _formatError = nil
      } catch {
        _formatError = String(describing: error)
      }
    }
  }

  enum FormatWait: Error {
    /// The keychain answered, and has no key.
    case noKeys
  }

  /// What every open does on the new file. Each step is one a later open or `catchUp` does again.
  private func settle() {
    do {
      if try meta("format.built") == nil {
        try setMeta("format.built", String(formatTesting.now().timeIntervalSince1970))
      }
      removeLeftovers()
      _vaultMark = nil
      try finishIfDue()
      try markRevocationsOnce()
      try withKeySweep { try importOldEdits() }
    } catch {
      _formatError = String(describing: error)
    }
  }

  /// A write can't wait for the keys (`VaultStore+Format`'s header), so it moves the store on when it can.
  func openForWriting() throws {
    guard _isWaiting else { return }
    if try keys.allKeys.isEmpty { _ = try keys.primary() }
    try buildFormat2File()
    settle()
  }

  /// Records from elsewhere wait where they are until the new file exists.
  func requireOpen() throws {
    guard _isWaiting else { return }
    try buildFormat2File()
    settle()
  }

  // MARK: Building the new file

  private func buildFormat2File() throws {
    // Another app got here first: its file is as good as this one's would be.
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try switchToNewFile()
      return
    }
    let available = try keys.allKeys
    guard !available.isEmpty else { throw FormatWait.noKeys }
    let manager = FileManager.default
    let temporary = URL(fileURLWithPath: "\(fileURL.path).\(UUID().uuidString).tmp")
    defer {
      for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: temporary.path + suffix) }
    }
    let legacy = database
    let building = try SQLiteConnection(url: temporary, mode: .building)
    // Before the files go, by the defer above: Windows doesn't remove an open file.
    defer { building.close() }
    try Self.createTables(in: building)
    database = building
    defer { if database === building { database = legacy } }
    try withKeySweep { try copyRows(from: legacy, into: building) }
    try formatTesting.stage?(.copied)
    guard (try building.query("PRAGMA quick_check").first?.first?.text) == "ok" else {
      throw VaultCrypto.CryptoError.damaged
    }
    try building.checkpointFully()
    building.close()
    try StoreFiles.sync(temporary)
    try formatTesting.stage?(.beforeMove)
    // False when another app won: its file is as good as this one.
    _ = try StoreFiles.moveWithoutReplacing(temporary, to: fileURL)
    StoreFiles.syncFolder(directory)
    database = legacy
    try switchToNewFile()
    try formatTesting.stage?(.moved)
  }

  private func switchToNewFile() throws {
    let legacy = database
    database = try SQLiteConnection(url: fileURL)
    _isWaiting = false
    legacy.close()
    _legacyAllowed = nil
    _legacyAllowedSource = nil
    notifier?.post()
  }

  /// Every row of the old file, read from one snapshot, into the one transaction of the new file.
  private func copyRows(from legacy: SQLiteConnection, into building: SQLiteConnection) throws {
    try legacy.execute("BEGIN")
    defer { try? legacy.execute("COMMIT") }
    useRecoveryRecordKey(from: legacy)
    try building.transaction {
      for row in try legacy.query("SELECT key, value FROM meta WHERE key NOT LIKE 'format%' AND key NOT LIKE 'refused.%'") {
        try building.query("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [row[0], row[1]])
      }
      // What a sync engine fetched goes, as what an old build skipped can be read now: every app's next launch fetches
      // everything again, and a change tag the store already has is skipped. Hub state stays, as `HubSync` asks for a
      // resend. What a sync engine made once on the server stays made.
      for row in try legacy.query(
        """
        SELECT name, state FROM engines WHERE name LIKE 'hub-sync:%' OR name LIKE '%.subscription' OR name LIKE '%.zone'
          OR name = 'environment.production'
        """)
      {
        try building.query("INSERT OR REPLACE INTO engines(name, state) VALUES(?, ?)", [row[0], row[1]])
      }
      var report = FormatReport()
      var allowed: [String: Data] = [:]
      var outbox: [String: Int64] = [:]
      for row in try legacy.query("SELECT id, version FROM outbox") {
        if let id = row[0].text { outbox[id] = row[1].int ?? 0 }
      }
      var imported: [String: Int64] = [:]
      var after = ""
      var count = 0
      while true {
        let rows = try legacy.query(
          """
          SELECT id, kind, key_id, payload, version, deleted, modified, change_tag, system_fields FROM items
          WHERE id > ? ORDER BY id LIMIT 500
          """, [.text(after)])
        guard let last = rows.last else { break }
        after = last[0].text ?? ""
        for row in rows {
          let id = row[0].text ?? ""
          if let version = row[4].int, outbox[id] != nil { imported[id] = version }
          count += 1
          try copy(row, wasQueued: outbox[id] != nil, report: &report, allowed: &allowed)
        }
      }
      for row in try legacy.query("SELECT id, key_id, payload FROM server_copies") {
        try copyServerCopy(row)
      }
      report.missingKeys.sort()
      guard Int(try building.query("SELECT COUNT(*) FROM items")[0][0].int ?? -1) == count else {
        throw VaultCrypto.CryptoError.damaged
      }
      try setFormatReport(report)
      try setLegacyAllowed(allowed)
      try setImported(imported)
      try setMeta("format.built", String(formatTesting.now().timeIntervalSince1970))
      try bumpRevision()
    }
  }

  /// One row: format 1 is sealed again and queued, so CloudKit and the Hubs get format 2. What won't, comes as it is.
  private func copy(
    _ row: [SQLiteConnection.Value], wasQueued: Bool, report: inout FormatReport, allowed: inout [String: Data]
  ) throws {
    let id = row[0].text ?? ""
    let keyID = row[2].text ?? ""
    let payload = row[3].blob ?? Data()
    try database.query(
      """
      INSERT INTO items(id, kind, key_id, payload, version, deleted, modified, change_tag, system_fields)
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [row[0], row[1], row[2], .blob(payload), row[4], row[5], row[6], row[7], row[8]])
    if let parsed = VaultItemSeal.parse(payload) {
      do {
        _ = try openFormat2(parsed, id: id, from: .local)
        if wasQueued { try queue(id: id, version: row[4].int ?? 0) }
        return
      } catch VaultCrypto.CryptoError.missingKey {
        return
      } catch where Self.payloadIsWrong(error) {
        // Format 1 starts with a random nonce, which can look like format 2's header once in 2^40.
      }
    }
    do {
      let item = try openFormat1(id: id, keyID: keyID, payload: payload)
      try database.savepoint { try rewrite(item) }
      if item.kind.isEmpty {
        report.withoutKind += 1
      } else if let column = row[1].text, !column.isEmpty, column != item.kind {
        report.kindMismatches += 1
      }
      report.resealed += 1
    } catch VaultCrypto.CryptoError.missingKey {
      allowed[id] = Data(SHA256.hash(data: payload))
      report.unreadable += 1
      if !report.missingKeys.contains(keyID) { report.missingKeys.append(keyID) }
    } catch where Self.payloadIsWrong(error) {
      // It stays as readable as it was, and a later `catchUp` tries again. A row like this never stops the store. Any
      // other failure stops the build, as it says nothing about the row.
      allowed[id] = Data(SHA256.hash(data: payload))
      report.notRewritten += 1
    }
  }

  /// The bases of text merges go too. One that doesn't open is just not a base any more.
  private func copyServerCopy(_ row: [SQLiteConnection.Value]) throws {
    let id = row[0].text ?? ""
    let payload = row[2].blob ?? Data()
    guard VaultItemSeal.parse(payload) == nil else {
      try setServerCopy(id: id, keyID: row[1].text ?? "", payload: payload)
      return
    }
    do {
      let item = try openFormat1(id: id, keyID: row[1].text ?? "", payload: payload)
      let sealed = try sealed(kind: item.kind, fields: item.fields, id: id)
      try setServerCopy(id: id, keyID: sealed.keyID, payload: sealed.payload)
    } catch VaultCrypto.CryptoError.missingKey {
    } catch where Self.payloadIsWrong(error) {
    }
  }

  /// Seals an item again with the current key and queues it, and checks it reads back the same.
  func rewrite(_ item: VaultItem) throws {
    try writeRow(id: item.id, kind: item.kind, fields: item.fields, queue: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let written = try loadRow(id: item.id)?.item, written.kind == item.kind,
      try encoder.encode(written.fields) == encoder.encode(item.fields)
    else { throw VaultCrypto.CryptoError.damaged }
  }

  /// Recovery blobs open with a key made from the recovery key's record.
  private func useRecoveryRecordKey(from database: SQLiteConnection) {
    guard
      let row = try? database.query("SELECT key_id, payload FROM items WHERE id = ?", [.text(VaultRecoveryKey.recordID)]).first,
      let item = try? decode(id: VaultRecoveryKey.recordID, keyID: row[0].text ?? "", payload: row[1].blob ?? Data()),
      case let key = VaultRecoveryKey(id: item.id, values: item.values), key.publicKey.count == 32
    else { return }
    let recordKey = key.recordKey
    useKey(recordKey.key, id: recordKey.id, sealing: VaultRecoveryBlob.kind)
  }

  /// What a kill during a build left, once it's old enough not to be another app's build under way.
  private func removeLeftovers() {
    let manager = FileManager.default
    let prefix = fileURL.lastPathComponent + "."
    let now = formatTesting.now()
    for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) && name.contains(".tmp") {
      let url = directory.appendingPathComponent(name)
      let modified = (try? manager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
      if let modified, now.timeIntervalSince(modified) > Self.leftoverAge { try? manager.removeItem(at: url) }
    }
  }

  // MARK: An old app on this device

  private func imported() throws -> [String: Int64] {
    try meta("format.imported").flatMap { try? JSONDecoder().decode([String: Int64].self, from: Data($0.utf8)) } ?? [:]
  }

  private func setImported(_ versions: [String: Int64]) throws {
    try setMeta("format.imported", String(decoding: try JSONEncoder().encode(versions), as: UTF8.self))
  }

  /// See this file's header. Runs on every open, on `catchUp`, and before a local write when the old file has changed, so
  /// that an old app's edit, whose clock may be ahead of this store's by what a fast peer told it, is merged before a later
  /// edit here gets its clock: the later one goes past it, as any write does. With a device id made up for this process,
  /// nothing can be told about a stamp, so nothing is imported or recorded, and the next launch does it. Returns what it wrote.
  @discardableResult
  private func importOldEdits() throws -> [String] {
    guard !VaultDevice.isProvisional(deviceID) else { return [] }
    let seen = oldFileSignature()
    let written = try importOldEditsNow()
    _oldFileSeen = seen
    return written
  }

  /// `importOldEdits`, if the old file changed since it last ran. A failure doesn't stop the write it comes before.
  func importOldEditsIfChanged() {
    guard oldFileSignature() != _oldFileSeen else { return }
    do {
      try withKeySweep { _ = try importOldEdits() }
    } catch {
      _formatError = String(describing: error)
    }
  }

  /// Enough to tell the old file changed: an old build's write goes to its journal first.
  private func oldFileSignature() -> String? {
    let manager = FileManager.default
    let parts = ["", "-wal"].compactMap { suffix -> String? in
      guard let attributes = try? manager.attributesOfItem(atPath: legacyFileURL.path + suffix) else { return nil }
      let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      return "\(suffix):\(attributes[.size] as? Int64 ?? 0):\(modified)"
    }
    return parts.isEmpty ? nil : parts.joined(separator: "|")
  }

  /// A text merge stamps `<device>+merge`, which is this device's edit too.
  private func isThisDevice(_ clock: HybridClock) -> Bool {
    var device = Substring(clock.device)
    while device.hasSuffix("+merge") { device = device.dropLast("+merge".count) }
    return device == deviceID
  }

  private func importOldEditsNow() throws -> [String] {
    guard FileManager.default.fileExists(atPath: legacyFileURL.path),
      let built = try meta("format.built").flatMap(Double.init),
      formatTesting.now().timeIntervalSince1970 - built < Self.oldFileWindow,
      let legacy = try? SQLiteConnection(url: legacyFileURL, mode: .readOnly),
      let queued = try? legacy.query(
        """
        SELECT items.id, items.kind, items.key_id, items.payload, items.version FROM outbox
        JOIN items ON items.id = outbox.id WHERE items.kind != ''
        """),
      let stamped = try? legacy.query(
        """
        SELECT id, kind, key_id, payload, version FROM items
        WHERE kind != '' AND modified >= ? AND id NOT IN (SELECT id FROM outbox)
        """, [.double(built - 1)])
    else { return [] }
    guard !queued.isEmpty || !stamped.isEmpty else { return [] }
    let wrote: [String] = try database.transaction {
      var versions = try imported()
      var wrote: [String] = []
      let builtMillis = Int64(built * 1000)
      for (rows, isQueued) in [(queued, true), (stamped, false)] {
        for row in rows {
          let id = row[0].text ?? ""
          let version = row[4].int ?? 0
          let payload = row[3].blob ?? Data()
          guard versions[id] != version, VaultItemSeal.parse(payload) == nil else { continue }
          // An old build doesn't know of a rotation until iCloud Keychain tells it, and goes on writing under the key.
          let keyID = row[2].text ?? ""
          if extraKeys[keyID] == nil, try keys.isRetired(keyID) {
            versions[id] = version
            try noteRefused(id: id, tag: nil, isOldFormat: false)
            continue
          }
          let old: VaultItem
          do {
            old = try openFormat1(id: id, keyID: keyID, payload: payload)
          } catch VaultCrypto.CryptoError.missingKey {
            continue
          } catch where Self.payloadIsWrong(error) {
            versions[id] = version
            continue
          }
          let incoming =
            isQueued ? old.fields : ItemFields(old.fields.stamped.filter { isThisDevice($0.value.clock) && $0.value.clock.millis >= builtMillis })
          var isOverDropped = false
          do {
            try checkHighWater(id: id, VaultItem(id: id, kind: old.kind, fields: incoming))
          } catch VaultCrypto.CryptoError.refused {
            isOverDropped = true
          }
          guard !incoming.stamped.isEmpty, !isOverDropped else {
            versions[id] = version
            continue
          }
          let local = try loadRow(id: id)
          // Its row waits for a key: it comes over once that row opens.
          if let local, local.item == nil, !local.isRefused { continue }
          versions[id] = version
          let fields = local?.item?.fields.merged(with: incoming) ?? incoming
          guard fields != local?.item?.fields else { continue }
          try observe(incoming.latestClock)
          try writeRow(id: id, kind: local?.item?.kind ?? old.kind, fields: fields, queue: true)
          wrote.append(id)
        }
      }
      try setImported(versions)
      if !wrote.isEmpty { try bumpRevision() }
      return wrote
    }
    if !wrote.isEmpty { notifier?.post() }
    return wrote
  }

  // MARK: Records from the server in format 1

  /// The vault's mark: the earliest date any device set. Setting one here when there's none is how the first device does
  /// it; one that hadn't seen another's yet settles on the earlier when it arrives.
  func vaultMarkDate() throws -> Date {
    if let _vaultMark { return _vaultMark }
    let dates = try keys.marks(prefix: Self.vaultMarkPrefix, synced: true).compactMap {
      Int64($0.name.dropFirst(Self.vaultMarkPrefix.count))
    }
    let date: Date
    if let earliest = dates.min() {
      date = Date(timeIntervalSince1970: Double(earliest) / 1000)
    } else {
      date = formatTesting.now()
      let name = Self.vaultMarkPrefix + String(Int64(date.timeIntervalSince1970 * 1000))
      try keys.setMark(name, data: Data("1".utf8), synced: true)
    }
    _vaultMark = date
    return date
  }

  /// Whether a format 1 record from elsewhere may be read now.
  func readsFormat1FromElsewhere() throws -> Bool {
    if formatIsFinished { return false }
    try finishIfDue()
    return !formatIsFinished
  }

  /// A store finishes when its first complete fetch is done, or as soon as it can past the vault's month.
  func finishIfDue() throws {
    guard !_isWaiting, !formatIsFinished else { return }
    // What's deferred was seen but not read, so a fetch isn't complete without it, and nor is a format 1 copy waiting for
    // its key, which would be refused when the key came and written over by the row. The month ends regardless.
    var isDue = try meta("format.fetched") == "1" && deferredRecords().isEmpty && !hasFormat1CopyWaiting()
    if !isDue { isDue = formatTesting.now().timeIntervalSince(try vaultMarkDate()) > Self.serverFormat1Window }
    if isDue { try setMeta("format", Self.formatValue) }
  }

  private func hasFormat1CopyWaiting() throws -> Bool {
    for id in try waitingServerCopies() {
      let copy = try database.query("SELECT payload FROM server_copies WHERE id = ?", [.text(id)]).first
      if let payload = copy?[0].blob, VaultItemSeal.parse(payload) == nil { return true }
    }
    return false
  }

  /// A fetch that began with no saved position reached the end: this store has seen what the server held.
  public func fetchCompleted() {
    withLock {
      guard !_isWaiting, !formatIsFinished else { return }
      do {
        try setMeta("format.fetched", "1")
        try finishIfDue()
      } catch {
        _formatError = String(describing: error)
      }
    }
  }

  // MARK: Records that couldn't be applied yet

  /// A fetched record that met a keychain out of reach or a busy database. The sync engine's position has moved past it,
  /// so it waits here until it can be read. One per id: a later one replaces it.
  struct DeferredRecord: Codable {
    var id: String
    var keyID = ""
    var payload = Data()
    var changeTag: String?
    var systemFields: Data?
    var isDeletion = false
    /// When a record whose payload couldn't be had was first met. It can't be retried here: the next full fetch brings it
    /// again, and `apply` then takes this one's place. Optional, for rows written before there was such a thing.
    var unreadSince: Double?

    init(_ record: RemoteRecord) {
      id = record.id
      keyID = record.keyID
      payload = record.payload
      changeTag = record.changeTag
      systemFields = record.systemFields
    }

    init(deletionOf id: String) {
      self.id = id
      isDeletion = true
    }
  }

  private static let deferredPrefix = "retry:"

  func deferRecord(_ record: DeferredRecord) throws {
    try setEngineState(try JSONEncoder().encode(record), for: Self.deferredPrefix + record.id)
  }

  func forgetDeferred(id: String) throws {
    try database.query("DELETE FROM engines WHERE name = ?", [.text(Self.deferredPrefix + id)])
  }

  /// A record the sync engine's position has moved past with nothing read of it (`CloudSync.fetched`). One whose payload
  /// the server holds waits for a full fetch, and holds up finishing for that long: the store hasn't seen it. One with no
  /// payload at all has nothing to wait for. A payload still out of reach after a month stops being waited for.
  func noteUnread(_ record: UnreadRecord) throws {
    guard record.hasPayload else {
      try withLock { try noteRefused(id: record.id, tag: record.changeTag, isOldFormat: false) }
      return
    }
    try withLock {
      let existing = try engineState(Self.deferredPrefix + record.id).flatMap { try? JSONDecoder().decode(DeferredRecord.self, from: $0) }
      var unread = DeferredRecord(RemoteRecord(id: record.id, keyID: "", payload: Data(), changeTag: record.changeTag, systemFields: nil))
      unread.unreadSince = existing?.unreadSince ?? formatTesting.now().timeIntervalSince1970
      try deferRecord(unread)
    }
  }

  private func deferredRecords() throws -> [DeferredRecord] {
    try database.query("SELECT state FROM engines WHERE name LIKE ?", [.text(Self.deferredPrefix + "%")]).compactMap {
      $0[0].blob.flatMap { try? JSONDecoder().decode(DeferredRecord.self, from: $0) }
    }
  }

  /// What was deferred, again, each on its own: one that can't be applied doesn't keep the rest waiting. Anything that
  /// couldn't even be written down is thrown at the end.
  private func retryDeferred() throws -> [String] {
    var toSend: [String] = []
    var failure: Error?
    for record in try deferredRecords() {
      do {
        if let unreadSince = record.unreadSince {
          if formatTesting.now().timeIntervalSince1970 - unreadSince > Self.serverFormat1Window { try forgetDeferred(id: record.id) }
        } else if record.isDeletion {
          try applyDeletion(id: record.id)
        } else {
          let remote = RemoteRecord(
            id: record.id, keyID: record.keyID, payload: record.payload, changeTag: record.changeTag, systemFields: record.systemFields)
          switch try apply(remote) {
          case .merged(needsSend: true), .refused(needsSend: true): toSend.append(record.id)
          default: break
          }
        }
      } catch {
        failure = failure ?? error
      }
    }
    if let failure { throw failure }
    return toSend
  }

  /// See `resetServerState`.
  func keepDeferredForAnotherServer() throws {
    for var record in try deferredRecords() {
      if record.isDeletion || record.unreadSince != nil {
        try forgetDeferred(id: record.id)
      } else {
        record.changeTag = nil
        record.systemFields = nil
        try deferRecord(record)
      }
    }
  }

  // MARK: Refusals

  static let refusedOld = "old."
  static let refusedOther = "other."

  /// A record this store refused, once per id: every app on the device fetches the same one. It goes when a record it can
  /// read arrives at the id, or this store's copy replaces it on the server.
  func noteRefused(id: String, tag: String?, isOldFormat: Bool) throws {
    try clearRefused(id: id)
    try setMeta("refused.\(isOldFormat ? Self.refusedOld : Self.refusedOther)\(id)", tag ?? "")
  }

  func clearRefused(id: String) throws {
    try database.query(
      "DELETE FROM meta WHERE key IN (?, ?)", [.text("refused.\(Self.refusedOld)\(id)"), .text("refused.\(Self.refusedOther)\(id)")])
  }

  private func refusedCount(_ prefix: String) throws -> Int {
    Int(try database.query("SELECT COUNT(*) FROM meta WHERE key LIKE ?", [.text("refused.\(prefix)%")])[0][0].int ?? 0)
  }

  // MARK: What being absent says

  /// Whether this store has what it should, so that a record missing from it is really missing: it finished its first
  /// fetch, nothing it fetched waits to be read, and every row and server copy names a key that's here. Until then a row
  /// that says otherwise may be on its way, or here and unreadable, so nothing may be deleted for being absent. What can't
  /// be told counts as not settled.
  public var isSettled: Bool {
    withLock {
      do {
        guard !_isWaiting, formatIsFinished, try deferredRecords().isEmpty, try waitingServerCopies().isEmpty else { return false }
        for row in try database.query(
          "SELECT DISTINCT key_id FROM items WHERE key_id != '' AND key_id NOT LIKE 'recovery-%'")
        {
          guard let keyID = row[0].text else { continue }
          if extraKeys[keyID] == nil, try keys.key(id: keyID) == nil { return false }
        }
        return true
      } catch {
        return false
      }
    }
  }

  /// Whether this store holds or held a record at this id: a row, deleted or not, one it dropped, or one still to be read.
  func knows(id: String) throws -> Bool {
    try withLock {
      guard try database.query("SELECT 1 FROM items WHERE id = ?", [.text(id)]).isEmpty else { return true }
      if try meta("hw.\(id)") != nil { return true }
      return try engineState(Self.deferredPrefix + id) != nil
    }
  }

  /// Of these Hubs, the ones whose hosts go: Hubs this store holds a tombstone for. A Hub record that's just not here says
  /// nothing, as a fresh device's first fetch brings a Hub's hosts before the Hub, or the Hub waits for its key, and a
  /// host deleted now would be deleted on every device. Nothing goes until the store is settled, for the same reason.
  public func removedHubs(among ids: Set<String>) -> Set<String> {
    guard isSettled else { return [] }
    return ids.filter { id in
      guard let item = try? item(id: id) else { return false }
      return item.kind == VaultHubServer.kind && item.isDeleted
    }
  }

  /// Whether Personal holds the account's record, not deleted.
  func isLive(account id: String) throws -> Bool {
    guard let item = try item(id: id) else { return false }
    return item.kind == VaultAccount.kind && !item.isDeleted
  }

  // MARK: Rows that came over without opening

  private var legacyAAD: Data { Data("dev.v57.vault.format.legacy|\(accountBinding)".utf8) }

  /// A row's format 1 payload is accepted in the new file only if it's on this list, sealed so that nobody
  /// without the keys can add to it: `id → SHA-256(payload)`.
  func setLegacyAllowed(_ allowed: [String: Data]) throws {
    guard !allowed.isEmpty else {
      try database.query("DELETE FROM meta WHERE key = 'format.legacy'")
      return
    }
    let (keyID, key) = try keys.primary()
    let box = try AES.GCM.seal(try JSONEncoder().encode(allowed), using: key, authenticating: legacyAAD)
    guard let combined = box.combined else { throw VaultCrypto.CryptoError.damaged }
    try setMeta("format.legacy", "\(keyID):\(combined.base64EncodedString())")
  }

  /// Adds a record that arrived in format 1, naming a key this device hasn't got, while the store still reads format 1.
  /// Sealing the list takes a key: with none here this isn't the moment to make one, so it fails, and the record is
  /// deferred until keys arrive.
  func addLegacyAllowed(id: String, payload: Data) throws {
    guard try !keys.allKeys.isEmpty else { throw FormatWait.noKeys }
    var allowed = try legacyAllowed()
    allowed[id] = Data(SHA256.hash(data: payload))
    try setLegacyAllowed(allowed)
  }

  /// The list. A keychain out of reach throws, and so does a list whose own key is gone: neither says anything about a row.
  func legacyAllowed() throws -> [String: Data] {
    // Another app can change it, so the row is read each time, and opened only when it's changed.
    let stored = try meta("format.legacy")
    if stored == _legacyAllowedSource, let cached = _legacyAllowed { return cached }
    var allowed: [String: Data] = [:]
    if let stored {
      let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { throw VaultCrypto.CryptoError.missingKey("") }
      guard let key = try vaultKey(id: parts[0]) else { throw VaultCrypto.CryptoError.missingKey(parts[0]) }
      guard let combined = Data(base64Encoded: parts[1]), let box = try? AES.GCM.SealedBox(combined: combined),
        let plaintext = try? AES.GCM.open(box, using: key, authenticating: legacyAAD),
        let decoded = try? JSONDecoder().decode([String: Data].self, from: plaintext)
      else { throw VaultCrypto.CryptoError.refused }
      allowed = decoded
    }
    _legacyAllowed = allowed
    _legacyAllowedSource = stored
    return allowed
  }

  func isAllowedFormat1(id: String, payload: Data) throws -> Bool {
    try legacyAllowed()[id] == Data(SHA256.hash(data: payload))
  }

  /// With no key, or only one made here on an empty keychain, while something here names a key that isn't, this device
  /// belongs to a vault whose id key hasn't arrived. Any id made now would be wrong, and a record under it would never
  /// converge with the real one, so ids wait. What counts is a row, a server copy or a deferred record naming a key that
  /// would come before the one ids come from now, or a rotation's, which says there's a vault with a first key. With nothing
  /// here naming anything, this is a vault's first device, or one whose first fetch hasn't reached it yet: the id key
  /// can't tell, and a brand new vault has to be able to go on.
  func idKeyCouldBeWrong() throws -> Bool {
    let source = try keys.stableIDKeySource()
    if let source {
      guard source.hasPrefix("n") else { return false }
    } else {
      guard try keys.allKeys.isEmpty else { return false }
    }
    let names: Set<String>
    if _isWaiting {
      names = Set(try database.query("SELECT DISTINCT key_id FROM items").compactMap { $0[0].text })
    } else {
      var seen = Set(try formatReport().missingKeys)
      seen.formUnion(try database.query("SELECT DISTINCT key_id FROM items").compactMap { $0[0].text })
      seen.formUnion(try database.query("SELECT DISTINCT key_id FROM server_copies").compactMap { $0[0].text })
      seen.formUnion(try deferredRecords().map(\.keyID))
      names = seen.filter { !$0.isEmpty && !$0.hasPrefix("recovery-") && extraKeys[$0] == nil }
    }
    return try names.contains { name in
      guard source == nil || name < source! || name.hasPrefix(VaultKeyRing.rotationKeyPrefix) else { return false }
      return try keys.key(id: name) == nil
    }
  }

  // MARK: Catching up

  /// A server copy that named a key this device didn't have, while its own row stayed readable.
  func addWaitingServerCopy(_ id: String) throws {
    var ids = try waitingServerCopies()
    guard ids.insert(id).inserted else { return }
    try setWaitingServerCopies(ids)
  }

  private func waitingServerCopies() throws -> Set<String> {
    try meta("format.waiting").flatMap { try? JSONDecoder().decode(Set<String>.self, from: Data($0.utf8)) } ?? []
  }

  private func setWaitingServerCopies(_ ids: Set<String>) throws {
    try setMeta("format.waiting", String(decoding: try JSONEncoder().encode(ids), as: UTF8.self))
  }

  /// `catchUp`, at most twice a minute: the sync engine asks often.
  func catchUpIfDue() {
    let now = formatTesting.now()
    let due = withLock {
      if let last = _lastCatchUp, now.timeIntervalSince(last) < 30 { return false }
      _lastCatchUp = now
      return true
    }
    if due { _ = try? catchUp() }
  }

  /// Does what couldn't be done before a key arrived: builds the new file, brings over what an old app wrote since the last
  /// look, as an app stays open long after its first look, moves rows that came over unopened to format 2,
  /// merges server copies that waited for their key, and seals again what's still under a key a rotation retired (on
  /// this device, or on one that told iCloud Keychain). Killed halfway, the next call carries on. Changes go in the
  /// outbox. Returns the ids it wrote.
  @discardableResult
  public func catchUp() throws -> [String] {
    let written: [String] = try withLock {
      if _isWaiting {
        prepareFormat()
        guard !_isWaiting else { return [] }
      }
      _vaultMark = nil
      // What an open couldn't do, with the keychain out of reach.
      if _formatError != nil {
        _formatError = nil
        settle()
      }
      return try withKeySweep {
        var written: [String] = try importOldEdits()
        written += try retryDeferred()
        written += try moveLegacyRows()
        written += try mergeWaitingServerCopies()
        let retired = try retiredKeys()
        if !retired.isEmpty {
          written += try resealRows(sealedWith: retired)
          written += try rewrapFolderKeys(sealedWith: retired)
        }
        try finishIfDue()
        return written
      }
    }
    if !written.isEmpty { didChange(locally: written) }
    return written
  }

  private func moveLegacyRows() throws -> [String] {
    guard try !legacyAllowed().isEmpty else { return [] }
    if let row = try record(VaultRecoveryKey.self, id: VaultRecoveryKey.recordID), row.publicKey.count == 32 {
      let recordKey = row.recordKey
      useKey(recordKey.key, id: recordKey.id, sealing: VaultRecoveryBlob.kind)
    }
    return try database.transaction {
      let allowed = try legacyAllowed()
      var moved: [String] = []
      for id in allowed.keys.sorted() {
        guard let row = try database.query("SELECT key_id, payload FROM items WHERE id = ?", [.text(id)]).first,
          let payload = row[1].blob, Data(SHA256.hash(data: payload)) == allowed[id]
        else { continue }
        do {
          let item = try openFormat1(id: id, keyID: row[0].text ?? "", payload: payload)
          try database.savepoint { try rewrite(item) }
          moved.append(id)
        } catch VaultCrypto.CryptoError.missingKey {
        } catch where Self.payloadIsWrong(error) {
        }
      }
      guard !moved.isEmpty else { return [] }
      var left = allowed
      for id in moved { left[id] = nil }
      try setLegacyAllowed(left)
      var report = try formatReport()
      report.resealed += moved.count
      report.unreadable = max(left.count - report.notRewritten, 0)
      try setFormatReport(report)
      try bumpRevision()
      return moved
    }
  }

  private func mergeWaitingServerCopies() throws -> [String] {
    guard try !waitingServerCopies().isEmpty else { return [] }
    return try database.transaction {
      let waiting = try waitingServerCopies()
      var written: [String] = []
      var left = waiting
      for id in waiting.sorted() {
        guard let copy = try database.query("SELECT key_id, payload FROM server_copies WHERE id = ?", [.text(id)]).first
        else {
          left.remove(id)
          continue
        }
        let remote: VaultItem
        do {
          remote = try decode(id: id, keyID: copy[0].text ?? "", payload: copy[1].blob ?? Data(), from: .network)
        } catch VaultCrypto.CryptoError.missingKey {
          continue
        } catch where Self.payloadIsWrong(error) {
          try noteRefused(id: id, tag: nil, isOldFormat: VaultItemSeal.parse(copy[1].blob ?? Data()) == nil)
          try database.query("DELETE FROM server_copies WHERE id = ?", [.text(id)])
          left.remove(id)
          continue
        }
        left.remove(id)
        guard let row = try loadRow(id: id) else { continue }
        guard let local = row.item else {
          // The row still waits for its own key, and this record is authentic and is what the server has now.
          try writeRow(id: id, kind: remote.kind, fields: remote.fields, queue: false)
          try bumpRevision()
          continue
        }
        try observe(remote.fields.latestClock)
        let merged = local.fields.merged(with: remote.fields, base: nil, textKeys: Self.textFields[local.kind] ?? [])
        if merged != local.fields {
          try writeRow(id: id, kind: local.kind, fields: merged, queue: true)
          try bumpRevision()
          written.append(id)
        }
      }
      try setWaitingServerCopies(left)
      return written
    }
  }
}
