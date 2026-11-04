import CryptoKit
import Foundation

@testable import VaultKit

/// A device still on a build from before format 2: the store's write, apply and peer paths as they were at c4ba614,
/// copied rather than rewritten, so tests can show what such a build does with what a new one sends.
final class OldBuildStore {
  let directory: URL
  let database: SQLiteConnection
  let keys: VaultKeyProvider
  let device: String
  private var token = 0

  init(directory: URL = temporaryDirectory(), keys: VaultKeyProvider, device: String) throws {
    self.directory = directory
    self.keys = keys
    self.device = device
    database = try SQLiteConnection(url: directory.appendingPathComponent(VaultStore.fileName))
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

  private struct Payload: Codable {
    var kind: String
    var fields: ItemFields

    enum CodingKeys: String, CodingKey {
      case kind = "k"
      case fields = "f"
    }
  }

  /// `primary()` as it was: the smallest id.
  private func primary() throws -> (id: String, key: SymmetricKey) {
    let all = try keys.allKeys
    let id = all.keys.min()!
    return (id, all[id]!)
  }

  static func format1(id: String, kind: String, fields: ItemFields, keys: VaultKeyProvider) throws -> (keyID: String, payload: Data) {
    let all = try keys.allKeys
    let keyID = all.keys.min()!
    let plaintext = try JSONEncoder().encode(Payload(kind: kind, fields: fields))
    return (keyID, try VaultCrypto.seal(plaintext, key: all[keyID]!))
  }

  private func decode(keyID: String, payload: Data) throws -> (kind: String, fields: ItemFields) {
    let plaintext = try VaultCrypto.open(payload, keyID: keyID, keys: keys)
    let decoded = try JSONDecoder().decode(Payload.self, from: plaintext)
    return (decoded.kind, decoded.fields)
  }

  func read(_ id: String) -> (kind: String, fields: ItemFields)? {
    guard let row = try? database.query("SELECT key_id, payload FROM items WHERE id = ?", [.text(id)]).first else { return nil }
    return try? decode(keyID: row[0].text ?? "", payload: row[1].blob ?? Data())
  }

  private func writeRow(id: String, kind: String, fields: ItemFields, queue: Bool) throws {
    let plaintext = try JSONEncoder().encode(Payload(kind: kind, fields: fields))
    let (keyID, key) = try primary()
    let ciphertext = try VaultCrypto.seal(plaintext, key: key)
    try database.query(
      """
      INSERT INTO items(id, kind, key_id, payload, version, deleted, modified) VALUES(?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, key_id = excluded.key_id, payload = excluded.payload,
        version = items.version + 1, deleted = excluded.deleted, modified = excluded.modified
      """,
      [
        .text(id), .text(kind), .text(keyID), .blob(ciphertext), .int(fields.isDeleted ? 1 : 0),
        .double(Double(fields.latestClock.millis) / 1000),
      ])
    guard queue else { return }
    let version = try database.query("SELECT version FROM items WHERE id = ?", [.text(id)])[0][0].int ?? 0
    try database.query(
      """
      INSERT INTO outbox(id, version, queued, owner, until) VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET version = excluded.version
      """,
      [.text(id), .int(version), .double(Date.now.timeIntervalSince1970), .null, .double(0)])
  }

  private func nextClock() throws -> HybridClock {
    let last = try database.query("SELECT value FROM meta WHERE key = 'clock'").first?[0].text.flatMap(HybridClock.init) ?? .zero
    let next = last.next(now: .now, device: device)
    try database.query("INSERT OR REPLACE INTO meta(key, value) VALUES('clock', ?)", [.text(next.description)])
    return next
  }

  private func observe(_ clock: HybridClock) throws {
    let last = try database.query("SELECT value FROM meta WHERE key = 'clock'").first?[0].text.flatMap(HybridClock.init) ?? .zero
    if clock > last {
      try database.query("INSERT OR REPLACE INTO meta(key, value) VALUES('clock', ?)", [.text(clock.description)])
    }
  }

  func save(id: String, kind: String, changes: [String: JSONValue]) throws {
    try database.transaction {
      var fields = ItemFields()
      if let row = try database.query("SELECT key_id, payload FROM items WHERE id = ?", [.text(id)]).first {
        fields = try decode(keyID: row[0].text ?? "", payload: row[1].blob ?? Data()).fields
      }
      _ = fields.apply(changes, clock: try nextClock())
      try writeRow(id: id, kind: kind, fields: fields, queue: true)
    }
  }

  func delete(id: String) throws {
    try database.transaction {
      guard let row = try database.query("SELECT key_id, payload FROM items WHERE id = ?", [.text(id)]).first else { return }
      let decoded = try decode(keyID: row[0].text ?? "", payload: row[1].blob ?? Data())
      var fields = decoded.fields
      fields.stamped[ItemFields.deletedKey] = StampedValue(true, clock: try nextClock())
      try writeRow(id: id, kind: decoded.kind, fields: fields, queue: true)
    }
  }

  /// `VaultStore.apply` at c4ba614. Returns whether the local copy has to go up.
  @discardableResult
  func apply(_ record: RemoteRecord) throws -> Bool {
    try database.transaction {
      let row = try database.query("SELECT key_id, payload, change_tag FROM items WHERE id = ?", [.text(record.id)]).first
      if let row, let tag = record.changeTag, row[2].text == tag { return false }
      let hasPending = try !database.query("SELECT 1 FROM outbox WHERE id = ?", [.text(record.id)]).isEmpty
      let local = row.flatMap { try? decode(keyID: $0[0].text ?? "", payload: $0[1].blob ?? Data()) }

      guard let remote = try? decode(keyID: record.keyID, payload: record.payload) else {
        if hasPending, local != nil {
          try setServerFields(record)
        } else {
          try database.query(
            """
            INSERT INTO items(id, kind, key_id, payload, version, deleted, modified, change_tag, system_fields)
            VALUES(?, '', ?, ?, 0, 0, 0, ?, ?)
            ON CONFLICT(id) DO UPDATE SET key_id = excluded.key_id, payload = excluded.payload,
              change_tag = excluded.change_tag, system_fields = excluded.system_fields
            """,
            [.text(record.id), .text(record.keyID), .blob(record.payload), .init(record.changeTag), .init(record.systemFields)])
        }
        return false
      }

      try observe(remote.fields.latestClock)
      let kind = local?.kind.isEmpty == false ? local!.kind : remote.kind
      let merged = local.map { $0.fields.merged(with: remote.fields) } ?? remote.fields
      if merged == remote.fields {
        try database.query(
          """
          INSERT INTO items(id, kind, key_id, payload, version, deleted, modified, change_tag, system_fields)
          VALUES(?, ?, ?, ?, 1, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, key_id = excluded.key_id, payload = excluded.payload,
            version = items.version + 1, deleted = excluded.deleted, modified = excluded.modified,
            change_tag = excluded.change_tag, system_fields = excluded.system_fields
          """,
          [
            .text(record.id), .text(kind), .text(record.keyID), .blob(record.payload),
            .int(merged.isDeleted ? 1 : 0), .double(Double(merged.latestClock.millis) / 1000),
            .init(record.changeTag), .init(record.systemFields),
          ])
        try database.query("DELETE FROM outbox WHERE id = ?", [.text(record.id)])
        return false
      }
      try writeRow(id: record.id, kind: kind, fields: merged, queue: true)
      try setServerFields(record)
      return true
    }
  }

  private func setServerFields(_ record: RemoteRecord) throws {
    try database.query(
      "UPDATE items SET change_tag = ?, system_fields = ? WHERE id = ?",
      [.init(record.changeTag), .init(record.systemFields), .text(record.id)])
  }

  /// What `CloudSync.remote` did at c4ba614: no `keyID` field, no record. The record is skipped.
  private func visible(_ record: RemoteRecord) -> Bool {
    VaultItemSeal.parse(record.payload) == nil
  }

  func pull(_ cloud: FakeCloud) throws {
    let changes = cloud.changes(since: token)
    token = changes.token
    for record in changes.modified where visible(record) { try apply(record) }
  }

  /// What its outbox holds. A conflict with a record it can't see stays there: `failure()` said `retryLater`.
  func push(_ cloud: FakeCloud) throws {
    var queue = try database.query("SELECT id FROM outbox").compactMap { $0[0].text }
    var rounds = 0
    while !queue.isEmpty, rounds < 100 {
      rounds += 1
      let id = queue.removeFirst()
      guard let row = try database.query(
        "SELECT key_id, payload, system_fields, version FROM items WHERE id = ?", [.text(id)]
      ).first else { continue }
      let record = OutgoingRecord(
        id: id, keyID: row[0].text ?? "", payload: row[1].blob ?? Data(), systemFields: row[2].blob, version: row[3].int ?? 0)
      switch cloud.save(record) {
      case .success(let tag):
        try database.query(
          "UPDATE items SET change_tag = ?, system_fields = ? WHERE id = ?", [.text(tag), .blob(Data(tag.utf8)), .text(id)])
        try database.query("DELETE FROM outbox WHERE id = ?", [.text(id)])
      case .failure(.conflict(let server)):
        guard visible(server) else { continue }
        try apply(server)
        queue.append(id)
      case .failure:
        continue
      }
    }
  }

  var pending: Int { (try? database.query("SELECT COUNT(*) FROM outbox")[0][0].int).map(Int.init) ?? 0 }
}
