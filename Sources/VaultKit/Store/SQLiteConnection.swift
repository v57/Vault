import Foundation
import SQLite3

/// A minimal SQLite connection for the store: statements with bound values, and write transactions that take
/// the database lock up front (`BEGIN IMMEDIATE`), so several apps writing the same file queue up instead of
/// failing halfway through.
///
/// Not thread-safe on its own; `VaultStore` serializes every call.
final class SQLiteConnection {
  enum Value {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
  }

  struct SQLiteError: LocalizedError {
    let code: Int32
    let message: String
    var errorDescription: String? { "SQLite \(code): \(message)" }
  }

  enum Mode {
    /// A store: created when missing, WAL, and a commit that a crash can't hurt but a power cut may lose.
    case store
    /// A store file this connection only reads, never created. Not `SQLITE_OPEN_READONLY`, which can't recover a WAL it
    /// finds with no `-shm`: `query_only` makes every write fail while leaving recovery working.
    case readOnly
    /// A file on its way into place: every commit reaches the disk.
    case building
  }

  private var handle: OpaquePointer?
  /// Writes fail: see `Mode.readOnly`.
  let isReadOnly: Bool

  init(url: URL, mode: Mode = .store) throws {
    isReadOnly = mode == .readOnly
    let create = mode == .readOnly ? 0 : SQLITE_OPEN_CREATE
    let flags = SQLITE_OPEN_READWRITE | create | SQLITE_OPEN_FULLMUTEX
    let code = sqlite3_open_v2(url.path, &handle, flags, nil)
    guard code == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close(handle)
      throw SQLiteError(code: code, message: message)
    }
    // Another app may hold the write lock for a moment.
    sqlite3_busy_timeout(handle, 10_000)
    switch mode {
    case .store:
      try execute("PRAGMA journal_mode = WAL")
      try execute("PRAGMA synchronous = NORMAL")
    case .readOnly:
      try execute("PRAGMA query_only = ON")
    case .building:
      try execute("PRAGMA journal_mode = WAL")
      try execute("PRAGMA synchronous = FULL")
    }
  }

  deinit {
    close()
  }

  /// Closes the file; with no other connection, SQLite removes the `-wal` and `-shm` beside it.
  func close() {
    sqlite3_close_v2(handle)
    handle = nil
  }

  /// Moves everything in the WAL into the main file and empties the WAL, so the main file holds it all.
  func checkpointFully() throws {
    let result = try query("PRAGMA wal_checkpoint(TRUNCATE)")
    guard result.first?.first?.int == 0 else {
      throw SQLiteError(code: SQLITE_BUSY, message: "the checkpoint couldn't finish")
    }
  }

  func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(handle, sql, nil, nil, &error)
    if code != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? "error"
      sqlite3_free(error)
      throw SQLiteError(code: code, message: message)
    }
  }

  /// Runs a statement and returns its rows.
  @discardableResult
  func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
    var statement: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() {
      let position = Int32(index + 1)
      switch value {
      case .null: try check(sqlite3_bind_null(statement, position))
      case .int(let int): try check(sqlite3_bind_int64(statement, position, int))
      case .double(let double): try check(sqlite3_bind_double(statement, position, double))
      case .text(let text): try check(sqlite3_bind_text(statement, position, text, -1, Self.transient))
      case .blob(let data):
        try data.withUnsafeBytes { bytes in
          try check(sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(bytes.count), Self.transient))
        }
      }
    }
    var rows: [[Value]] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { try check(code); break }
      let count = sqlite3_column_count(statement)
      rows.append(
        (0..<count).map { column in
          switch sqlite3_column_type(statement, column) {
          case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
          case SQLITE_FLOAT: .double(sqlite3_column_double(statement, column))
          case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
          case SQLITE_BLOB:
            .blob(
              Data(
                bytes: sqlite3_column_blob(statement, column),
                count: Int(sqlite3_column_bytes(statement, column))))
          default: .null
          }
        })
    }
    return rows
  }

  /// Runs `body` in a write transaction, committing when it returns and rolling back when it throws.
  func transaction<T>(_ body: () throws -> T) throws -> T {
    if isReadOnly { throw SQLiteError(code: SQLITE_READONLY, message: "this connection only reads") }
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  /// Runs `body` inside a transaction so that a throw undoes only what it did.
  func savepoint<T>(_ body: () throws -> T) throws -> T {
    try execute("SAVEPOINT one")
    do {
      let result = try body()
      try execute("RELEASE one")
      return result
    } catch {
      try execute("ROLLBACK TO one")
      try execute("RELEASE one")
      throw error
    }
  }

  private func check(_ code: Int32) throws {
    guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE else {
      throw SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
  }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

extension SQLiteConnection.Value {
  var text: String? {
    if case .text(let value) = self { return value }
    return nil
  }

  var int: Int64? {
    if case .int(let value) = self { return value }
    return nil
  }

  var double: Double? {
    switch self {
    case .double(let value): value
    case .int(let value): Double(value)
    default: nil
    }
  }

  var blob: Data? {
    switch self {
    case .blob(let value): value
    // An empty blob reads back as NULL-typed zero bytes on some paths.
    default: nil
    }
  }

  init(_ text: String?) { self = text.map(Self.text) ?? .null }
  init(_ data: Data?) { self = data.map(Self.blob) ?? .null }
}
