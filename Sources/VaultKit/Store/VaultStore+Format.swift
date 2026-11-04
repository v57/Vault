import CryptoKit
import Foundation

/// How a store moved to payload format 2 (`VaultItemSeal`).
public struct VaultFormatStatus: Sendable, Equatable {
  /// The store rewrote everything it can read and refuses format 1 from now on.
  public var isFinished: Bool
  /// Rows rewritten to format 2.
  public var resealed: Int
  /// Rows it couldn't open when it finished (their key hasn't arrived). They stay, and open and move over once it does.
  public var unreadable: Int
  /// Rows whose payload names no kind: they stay readable, under the empty kind.
  public var withoutKind: Int
  /// Rows whose column and payload named different kinds. The payload's kind counts.
  public var kindMismatches: Int
  /// Records this process refused from CloudKit or a Hub.
  public var refused: Int
  /// The copy of the store from before the first rewrite. Ciphertext only; nothing deletes it but deleting the store.
  public var backup: URL?
  /// Why it hasn't finished (the keychain was out of reach, the disk was full): it tries again.
  public var error: String?
}

/// Lets tests stop a migration at every step, and move the clock.
struct FormatTesting: Sendable {
  enum Stage: Sendable, Equatable {
    case backedUp
    case batch(Int)
    case beforeFinish
    case finished
  }

  var stage: (@Sendable (Stage) throws -> Void)?
  var now: @Sendable () -> Date = { .now }
  var batchSize = 200
}

/// Payload format 2 is one-way, per store. `prepareFormat` runs on every open, before the store is used, and every app
/// that shares the file gets it: killed anywhere, the next open of any app carries on, and SQLite's write lock makes
/// concurrent opens take turns.
///
/// 1. Copies the store once (`VACUUM INTO`, so the journal comes along) to `<file>.format1-backup`, before anything is
///    rewritten. Only ciphertext; it stays until the store is deleted.
/// 2. Rewrites rows in batches, each a transaction, reading back each one before it commits. Each rewrite goes into the
///    outbox like any write, so CloudKit and the Hubs get format 2.
/// 3. In a last transaction: sweeps what's left (another app's write), lists what can't open yet, forgets what the sync
///    engines fetched (an old build skipped format 2 records it must now read) and sets `format` in `meta`.
/// 4. Sets two keychain marks: one on this device, so editing the file can't undo the migration, and a synced one, so a
///    store this user's other devices make is born finished.
///
/// **Before a store finishes, format 1 is read.** An existing store finishes in the same open, so nothing arrives in
/// between. The window is a new, empty store on a device with no mark from any other (the user's only device, or the
/// first one to update): it reads format 1 for an hour from its first open and finishes at the next open after that, so
/// that a first fetch from a CloudKit holding only format 1 isn't thrown away. In that hour someone who can write to
/// CloudKit can put an old payload at any record id it knows, and move one between ids; that hour is what they get.
///
/// **After it finishes, format 1 from elsewhere is refused**, and a row's format 1 payload opens only if it's on the
/// sealed list made in step 3. A device still on an old build keeps its own edits and sends them again when it migrates:
/// its rows go in the outbox with new change tags, so the devices that refused them hear about them again, and fields
/// merge as usual.
extension VaultStore {
  static let formatBackupSuffix = ".format1-backup"
  private static let formatValue = "2"
  /// How long a new store reads format 1 when no other device has finished (see above).
  private static let formatGrace: TimeInterval = 3600
  /// Format 2's first five bytes, for SQL.
  private static let format1Rows = "substr(payload, 1, 5) != x'5635374902'"

  /// What a payload is bound to: the store. Personal has no account id.
  var accountBinding: String { accountID ?? VaultAccount.personal.id }

  var formatBackupURL: URL { URL(fileURLWithPath: fileURL.path + Self.formatBackupSuffix) }

  /// Whether this store refuses format 1. Another app may have finished it since this one looked.
  var formatIsFinished: Bool {
    if _formatFinished { return true }
    if (try? meta("format")) == Self.formatValue { _formatFinished = true }
    return _formatFinished
  }

  public var isFormatFinished: Bool { withLock { formatIsFinished } }

  public var formatStatus: VaultFormatStatus {
    withLock {
      let report = (try? formatReport()) ?? FormatReport()
      let backup = FileManager.default.fileExists(atPath: formatBackupURL.path) ? formatBackupURL : nil
      return VaultFormatStatus(
        isFinished: formatIsFinished, resealed: report.resealed, unreadable: report.unreadable,
        withoutKind: report.withoutKind, kindMismatches: report.kindMismatches, refused: _refusedCount, backup: backup,
        error: _formatError)
    }
  }

  private struct FormatReport: Codable {
    var resealed = 0
    var unreadable = 0
    var withoutKind = 0
    var kindMismatches = 0
  }

  private func formatReport() throws -> FormatReport {
    try meta("format.report").flatMap { try? JSONDecoder().decode(FormatReport.self, from: Data($0.utf8)) } ?? FormatReport()
  }

  private func setFormatReport(_ report: FormatReport) throws {
    try setMeta("format.report", String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
  }

  private var formatMark: String { "format2.\(deviceID).\(accountBinding)" }

  // MARK: Migrating

  /// Never throws out of `init`: a store that can't migrate yet still opens, and reads what it has.
  func prepareFormat() {
    withLock {
      do {
        try runFormat()
        _formatError = nil
      } catch {
        _formatError = String(describing: error)
      }
    }
  }

  private func runFormat() throws {
    if try meta("format") == Self.formatValue {
      _formatFinished = true
      try setFormatMarks()
      return
    }
    let hasFormat1 = try !database.query("SELECT 1 FROM items WHERE \(Self.format1Rows) LIMIT 1").isEmpty
    // This device finished this store before, and the file doesn't say so: it was restored from a backup, or edited.
    // The rows it holds aren't taken back; what's on CloudKit comes again.
    if try keys.hasMark(formatMark, synced: false) {
      try database.transaction {
        if hasFormat1 { try forgetWhatWasFetched() }
        try setMeta("format", Self.formatValue)
      }
      _formatFinished = true
      return
    }
    // A migration that began goes on, even with no format 1 row left: only the last transaction may be missing.
    if try meta("format.started") == nil, try !keys.hasMark(formatMark, synced: true) {
      let firstOpen = try meta("format.firstOpen").flatMap(Double.init)
      if firstOpen == nil, !hasFormat1 {
        try setMeta("format.firstOpen", String(formatTesting.now().timeIntervalSince1970))
        return
      }
      if let firstOpen, formatTesting.now().timeIntervalSince1970 - firstOpen < Self.formatGrace { return }
    }
    // With no key here yet, opening nothing would make one; come back when the keys have arrived.
    guard try !keys.allKeys.isEmpty else { return }
    if hasFormat1 { try makeFormatBackup() }
    try setMeta("format.started", "1")
    try formatTesting.stage?(.backedUp)
    useRecoveryRecordKey()
    var after = ""
    var batch = 0
    while true {
      let finished: Bool = try database.transaction {
        var report = try formatReport()
        let rows = try database.query(
          "SELECT id, kind, key_id, payload FROM items WHERE \(Self.format1Rows) AND id > ? ORDER BY id LIMIT ?",
          [.text(after), .int(Int64(formatTesting.batchSize))])
        for row in rows {
          after = row[0].text ?? ""
          try reseal(row, report: &report)
        }
        try resealServerCopies(ids: rows.compactMap { $0[0].text })
        try setFormatReport(report)
        return rows.isEmpty
      }
      if finished { break }
      batch += 1
      try formatTesting.stage?(.batch(batch))
    }
    try formatTesting.stage?(.beforeFinish)
    try database.transaction {
      var report = try formatReport()
      var legacy: [String: Data] = [:]
      // Everything once more, under the write lock: another app may have written since, and now nobody can.
      for row in try database.query("SELECT id, kind, key_id, payload FROM items") {
        let id = row[0].text ?? ""
        let payload = row[3].blob ?? Data()
        if let parsed = VaultItemSeal.parse(payload) {
          do {
            _ = try openFormat2(parsed, id: id, from: .local)
            continue
          } catch VaultCrypto.CryptoError.missingKey {
            continue
          } catch {}
        }
        if try !reseal(row, report: &report) {
          legacy[id] = Data(SHA256.hash(data: payload))
        }
      }
      report.unreadable = legacy.count
      try setFormatReport(report)
      try setLegacyAllowed(legacy)
      try forgetWhatWasFetched()
      try setMeta("format", Self.formatValue)
      try bumpRevision()
    }
    _formatFinished = true
    removeFormatTemporaryFiles()
    try formatTesting.stage?(.finished)
    try setFormatMarks()
  }

  private func setFormatMarks() throws {
    if try !keys.hasMark(formatMark, synced: false) { try keys.setMark(formatMark, synced: false) }
    if try !keys.hasMark(formatMark, synced: true) { try keys.setMark(formatMark, synced: true) }
  }

  /// A row in format 1 becomes format 2, read back before the transaction commits. Returns false for one that doesn't
  /// open here, which is left exactly as it is.
  @discardableResult
  private func reseal(_ row: [SQLiteConnection.Value], report: inout FormatReport) throws -> Bool {
    let id = row[0].text ?? ""
    guard let item = try? openFormat1(id: id, keyID: row[2].text ?? "", payload: row[3].blob ?? Data()) else { return false }
    if item.kind.isEmpty {
      report.withoutKind += 1
    } else if let column = row[1].text, !column.isEmpty, column != item.kind {
      report.kindMismatches += 1
    }
    try rewrite(item)
    report.resealed += 1
    return true
  }

  /// Seals an item again with the current key and queues it, and checks it reads back the same.
  private func rewrite(_ item: VaultItem) throws {
    try writeRow(id: item.id, kind: item.kind, fields: item.fields, queue: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let written = try loadRow(id: item.id)?.item, written.kind == item.kind,
      try encoder.encode(written.fields) == encoder.encode(item.fields)
    else { throw VaultCrypto.CryptoError.damaged }
  }

  /// The bases of text merges go too. One that doesn't open is just not a base any more.
  private func resealServerCopies(ids: [String]) throws {
    for id in ids {
      guard let row = try database.query("SELECT key_id, payload FROM server_copies WHERE id = ?", [.text(id)]).first,
        let payload = row[1].blob, VaultItemSeal.parse(payload) == nil,
        let item = try? openFormat1(id: id, keyID: row[0].text ?? "", payload: payload)
      else { continue }
      let (keyID, key) = try keys.primary()
      let sealed = try VaultItemSeal.seal(
        kind: item.kind, fields: try JSONEncoder().encode(item.fields), id: id, account: accountBinding, keyID: keyID,
        key: key)
      try setServerCopy(id: id, keyID: keyID, payload: sealed)
    }
  }

  /// Recovery blobs open with a key made from the recovery key's record.
  private func useRecoveryRecordKey() {
    guard let key = try? record(VaultRecoveryKey.self, id: VaultRecoveryKey.recordID), key.publicKey.count == 32 else {
      return
    }
    let recordKey = key.recordKey
    useKey(recordKey.key, id: recordKey.id, sealing: VaultRecoveryBlob.kind)
  }

  /// Every app's next launch fetches everything again: what it skipped on an old build, it can read now. A change tag
  /// the store already has is skipped, so what didn't change costs only the fetch. Hub state stays: `HubSync` asks for
  /// a resend. What a sync engine made once on the server stays made.
  private func forgetWhatWasFetched() throws {
    try database.query(
      """
      DELETE FROM engines WHERE name NOT LIKE 'hub-sync:%' AND name NOT LIKE '%.subscription'
        AND name NOT LIKE '%.zone' AND name != 'environment.production'
      """)
  }

  private func makeFormatBackup() throws {
    let manager = FileManager.default
    let backup = formatBackupURL
    guard !manager.fileExists(atPath: backup.path) else { return }
    let temporary = URL(fileURLWithPath: "\(backup.path).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporary) }
    try database.execute("VACUUM INTO '\(temporary.path.replacingOccurrences(of: "'", with: "''"))'")
    do {
      // Fails when the file is there: another app won, and rewriting needs only that one exists.
      try manager.moveItem(at: temporary, to: backup)
    } catch {
      guard manager.fileExists(atPath: backup.path) else { throw error }
    }
  }

  /// What a kill during the copy left.
  private func removeFormatTemporaryFiles() {
    let prefix = fileURL.lastPathComponent + Self.formatBackupSuffix + "."
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  // MARK: Rows that couldn't open when the store finished

  private var legacyAAD: Data { Data("dev.v57.vault.format.legacy|\(accountBinding)".utf8) }

  /// A row's format 1 payload is accepted after the store finished only if it's on this list, sealed so that nobody
  /// without the keys can add to it: `id → SHA-256(payload)`.
  private func setLegacyAllowed(_ allowed: [String: Data]) throws {
    _legacyAllowed = allowed
    guard !allowed.isEmpty else {
      try database.query("DELETE FROM meta WHERE key = 'format.legacy'")
      return
    }
    let (keyID, key) = try keys.primary()
    let box = try AES.GCM.seal(try JSONEncoder().encode(allowed), using: key, authenticating: legacyAAD)
    guard let combined = box.combined else { throw VaultCrypto.CryptoError.damaged }
    try setMeta("format.legacy", "\(keyID):\(combined.base64EncodedString())")
  }

  private func legacyAllowed() -> [String: Data] {
    if let cached = _legacyAllowed { return cached }
    var allowed: [String: Data] = [:]
    if let stored = try? meta("format.legacy") {
      let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
      if parts.count == 2, let key = try? keys.key(id: parts[0]), let combined = Data(base64Encoded: parts[1]),
        let box = try? AES.GCM.SealedBox(combined: combined),
        let plaintext = try? AES.GCM.open(box, using: key, authenticating: legacyAAD),
        let decoded = try? JSONDecoder().decode([String: Data].self, from: plaintext)
      {
        allowed = decoded
      } else {
        // Its key hasn't arrived: look again next time.
        return [:]
      }
    }
    _legacyAllowed = allowed
    return allowed
  }

  func isAllowedFormat1(id: String, payload: Data) throws -> Bool {
    legacyAllowed()[id] == Data(SHA256.hash(data: payload))
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

  /// Does what couldn't be done before a key arrived: finishes the format, moves rows that couldn't open to format 2,
  /// and merges server copies that waited for their key. Changes go in the outbox. Returns the ids it wrote.
  @discardableResult
  public func catchUp() throws -> [String] {
    let written: [String] = try withLock {
      if !formatIsFinished { prepareFormat() }
      var written: [String] = []
      written += try moveLegacyRows()
      written += try mergeWaitingServerCopies()
      return written
    }
    if !written.isEmpty { didChange(locally: written) }
    return written
  }

  private func moveLegacyRows() throws -> [String] {
    let allowed = legacyAllowed()
    guard !allowed.isEmpty else { return [] }
    return try database.transaction {
      var moved: [String] = []
      for id in allowed.keys.sorted() {
        guard let row = try database.query("SELECT key_id, payload FROM items WHERE id = ?", [.text(id)]).first,
          let payload = row[1].blob, Data(SHA256.hash(data: payload)) == allowed[id],
          let item = try? openFormat1(id: id, keyID: row[0].text ?? "", payload: payload)
        else { continue }
        try rewrite(item)
        moved.append(id)
      }
      guard !moved.isEmpty else { return [] }
      var left = allowed
      for id in moved { left[id] = nil }
      try setLegacyAllowed(left)
      var report = try formatReport()
      report.resealed += moved.count
      report.unreadable = left.count
      try setFormatReport(report)
      try bumpRevision()
      return moved
    }
  }

  private func mergeWaitingServerCopies() throws -> [String] {
    let waiting = try waitingServerCopies()
    guard !waiting.isEmpty else { return [] }
    return try database.transaction {
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
        } catch {
          _refusedCount += 1
          try database.query("DELETE FROM server_copies WHERE id = ?", [.text(id)])
          left.remove(id)
          continue
        }
        left.remove(id)
        guard let local = try loadRow(id: id)?.item else { continue }
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
