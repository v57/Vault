import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Temporary decryption: a plaintext working copy of an encrypted folder, for tools that can't read the encrypted
/// form (git, Xcode, the terminal, other apps). Changes in the copy are sealed back with `sealChanges()`, which the
/// app calls on a timer or when the copy changes (`FolderWatcher`); `lock()` seals what's left and deletes the copy.
///
/// The copy goes in a folder the app chooses (its app group container's `Decrypted/`, or `Documents` on iPad so
/// other apps open it in place), with a `.metadata_never_index` file so Spotlight skips it, excluded from backups.
/// Each session is recorded next to it, in `.v57-sessions/` (the record, and an encrypted snapshot of the copy as
/// last sealed), so `recoverLeftovers(in:folder:)` can seal and delete copies a crash left behind. A live session
/// holds a lock on its record, so recovery from another app sharing the folder never touches it.
///
/// While a folder is decrypted any process the user runs can read it, and deleted plaintext can't be reliably wiped
/// from an SSD, so the app should show this as a visible, timed state ("Decrypted, locks in 30 min").
public final class DecryptSession: @unchecked Sendable {
  public static let sessionsDirectoryName = ".v57-sessions"
  /// Spotlight skips a folder holding a file with this name.
  public static let neverIndexName = ".metadata_never_index"
  /// Names in the copy that are never sealed.
  static let ignoredNames: Set<String> = [neverIndexName, ".DS_Store"]

  /// What a session records about itself, readable without the folder key.
  public struct Record: Codable, Sendable, Equatable {
    public let id: String
    public let folderID: String
    /// Where the encrypted folder was when the session started.
    public let folderPath: String
    /// The copy's folder name, inside the parent folder.
    public let copyName: String
    public let started: Date
    public var lockDate: Date
  }

  /// What a `sealChanges()` pass did. Folders count with files.
  public struct Report: Sendable, Equatable {
    public var edited = 0
    public var added = 0
    public var deleted = 0

    public init(edited: Int = 0, added: Int = 0, deleted: Int = 0) {
      self.edited = edited
      self.added = added
      self.deleted = deleted
    }

    public var changed: Int { edited + added + deleted }
    public var isEmpty: Bool { changed == 0 }

    /// "2 edited · 1 added · 3 deleted", or "No changes".
    public var summary: String {
      let parts = [(edited, "edited"), (added, "added"), (deleted, "deleted")].filter { $0.0 > 0 }
      return parts.isEmpty ? "No changes" : parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
  }

  /// The encrypted folder this session decrypted.
  public let folder: EncryptedFolder
  /// The plaintext working copy.
  public let copyURL: URL
  /// The folder holding the copy (and the session records).
  public let parentURL: URL

  private let mutex = NSLock()
  private var record: Record
  private var snapshot: Snapshot
  private var lockHandle: SessionLock?
  private var ended = false

  public var id: String { record.id }
  public var started: Date { record.started }
  /// When the app should lock the session.
  public var lockDate: Date { locked { record.lockDate } }
  public var isExpired: Bool { lockDate <= Date() }
  /// Whether `lock()` has run (the copy is gone).
  public var isLocked: Bool { locked { ended } }

  private init(folder: EncryptedFolder, parent: URL, record: Record, snapshot: Snapshot, lockHandle: SessionLock?) {
    self.folder = folder
    parentURL = parent
    copyURL = parent.appendingPathComponent(record.copyName, isDirectory: true)
    self.record = record
    self.snapshot = snapshot
    self.lockHandle = lockHandle
  }

  deinit { lockHandle?.release() }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    mutex.lock()
    defer { mutex.unlock() }
    return try body()
  }

  // MARK: Starting

  /// Decrypts `folder` into a new working copy in `parent`, named `name` (the encrypted folder's name by default; a
  /// number is added when taken), locking after `duration`.
  public static func start(
    _ folder: EncryptedFolder, in parent: URL, name: String? = nil, duration: TimeInterval = 30 * 60
  ) throws -> DecryptSession {
    let fileManager = FileManager.default
    let sessions = parent.appendingPathComponent(sessionsDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
    excludeFromBackup(sessions)
    let copyName = uniqueName(try NameCipher.normalized(name ?? folder.url.lastPathComponent), in: parent)
    let now = Date()
    let record = Record(
      id: UUID().uuidString, folderID: folder.folderID, folderPath: folder.url.path, copyName: copyName,
      started: now, lockDate: now.addingTimeInterval(duration))
    let lockHandle = try SessionLock(url: sessions.appendingPathComponent(record.id + ".lock"))
    let session = DecryptSession(
      folder: folder, parent: parent, record: record, snapshot: Snapshot(), lockHandle: lockHandle)
    // The record goes first, so a crash while decrypting leaves something to clean up.
    try session.saveRecord()
    do {
      try fileManager.createDirectory(at: session.copyURL, withIntermediateDirectories: false)
      excludeFromBackup(session.copyURL)
      try Data().write(to: session.copyURL.appendingPathComponent(neverIndexName))
      try session.decryptAll()
      try session.saveSnapshot()
    } catch {
      session.removeCopyAndRecord()
      throw error
    }
    return session
  }

  private func decryptAll() throws {
    let fileManager = FileManager.default
    for entry in try folder.walk() {
      let target = copyURL.appendingPathComponent(entry.path, isDirectory: entry.isDirectory)
      if entry.isDirectory {
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        snapshot.directories.insert(entry.path)
      } else {
        let digest = try folder.readFile(entry.path, to: target, progress: nil)
        let attributes = try Self.fileAttributes(target)
        snapshot.files[entry.path] = FileState(
          size: attributes.size, modified: attributes.modified, hash: Data(digest).hexString)
      }
    }
  }

  // MARK: Sealing

  /// Seals what changed in the copy since the last pass into the encrypted folder: edited and new files are
  /// encrypted, deleted ones removed. A file whose size and modification date are unchanged isn't read; one whose
  /// date changed is hashed and sealed only when its contents differ.
  @discardableResult
  public func sealChanges() throws -> Report {
    try locked {
      guard !ended else { return Report() }
      return try sealLocked()
    }
  }

  private func sealLocked() throws -> Report {
    let fileManager = FileManager.default
    let scan = try scanCopy()
    var report = Report()
    defer { try? saveSnapshot() }

    // Deletions first, so a file that became a folder (or the reverse) is out of the way.
    for path in snapshot.files.keys.sorted() where scan.files[path] == nil {
      try removeIgnoringMissing(path)
      snapshot.files[path] = nil
      report.deleted += 1
    }
    for path in snapshot.directories.sorted(by: >) where !scan.directories.contains(path) {
      try removeIgnoringMissing(path)
      snapshot.directories.remove(path)
      report.deleted += 1
    }
    for path in scan.directories.sorted() where !snapshot.directories.contains(path) {
      try folder.createDirectory(path)
      snapshot.directories.insert(path)
      report.added += 1
    }
    for path in scan.files.keys.sorted() {
      let file = scan.files[path]!
      let old = snapshot.files[path]
      if let old, old.size == file.size, old.modified == file.modified { continue }
      if let old, old.size == file.size, let hash = try? Self.hash(of: file.url), hash == old.hash {
        // Touched, not changed.
        snapshot.files[path] = FileState(size: file.size, modified: file.modified, hash: hash)
        continue
      }
      let digest: SHA256.Digest
      do {
        digest = try folder.writeFile(from: file.url, to: path, progress: nil)
      } catch where !fileManager.fileExists(atPath: file.url.path) {
        continue  // Deleted since the scan; the next pass removes it.
      }
      // The size and date from before reading: if the file changed while it was sealed, the next pass sees it.
      snapshot.files[path] = FileState(size: file.size, modified: file.modified, hash: Data(digest).hexString)
      if old == nil { report.added += 1 } else { report.edited += 1 }
    }
    return report
  }

  private func removeIgnoringMissing(_ path: String) throws {
    do {
      try folder.remove(path)
    } catch VaultFilesError.notFound {
    } catch VaultFilesError.notADirectory {
    }
  }

  // MARK: Time and locking

  /// Moves the lock time `interval` later (from now, if it has passed).
  public func extend(by interval: TimeInterval) throws {
    try locked {
      record.lockDate = max(record.lockDate, Date()).addingTimeInterval(interval)
      try saveRecord()
    }
  }

  /// Seals the remaining changes, then deletes the copy and the session's record. When sealing fails, nothing is
  /// deleted and the error is thrown.
  @discardableResult
  public func lock() throws -> Report {
    try locked {
      guard !ended else { return Report() }
      let report = try sealLocked()
      removeCopyAndRecord()
      ended = true
      return report
    }
  }

  private func removeCopyAndRecord() {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: copyURL)
    try? fileManager.removeItem(at: recordURL)
    try? fileManager.removeItem(at: snapshotURL)
    lockHandle?.release()
    try? fileManager.removeItem(at: lockURL)
    lockHandle = nil
  }

  // MARK: Recovery

  /// What `recoverLeftovers` did with one leftover session.
  public enum Outcome: Sendable {
    /// Its changes were sealed and the copy deleted.
    case sealed(Report)
    /// It crashed while decrypting, before the copy was handed out: the copy was deleted.
    case discarded
    /// The app gave no folder for it (not on this device, or no key yet): the copy was left alone.
    case skipped
    /// Sealing failed; the copy was left alone.
    case failed(any Error)
  }

  public struct Recovery: Sendable {
    public let record: Record
    public let outcome: Outcome
  }

  /// The sessions recorded in `parent` that no running session holds (left by a crash or a quit without locking).
  public static func leftovers(in parent: URL) -> [Record] {
    let sessions = parent.appendingPathComponent(sessionsDirectoryName, isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return names.filter { $0.hasSuffix(".json") }.compactMap { name in
      guard let data = try? Data(contentsOf: sessions.appendingPathComponent(name)),
        let record = try? decoder.decode(Record.self, from: data),
        let probe = try? SessionLock(url: sessions.appendingPathComponent(record.id + ".lock"))
      else { return nil }
      probe.release()
      return record
    }.sorted { $0.started < $1.started }
  }

  /// Seals and deletes the working copies crashed sessions left in `parent`. `folder` returns the encrypted folder
  /// (opened with its key) for a leftover, or nil to leave that copy for later. Run it at launch.
  @discardableResult
  public static func recoverLeftovers(in parent: URL, folder: (Record) throws -> EncryptedFolder?) -> [Recovery] {
    leftovers(in: parent).map { record in
      Recovery(record: record, outcome: recover(record, in: parent, folder: folder))
    }
  }

  private static func recover(_ record: Record, in parent: URL, folder open: (Record) throws -> EncryptedFolder?)
    -> Outcome
  {
    let sessions = parent.appendingPathComponent(sessionsDirectoryName, isDirectory: true)
    do {
      guard let lockHandle = try? SessionLock(url: sessions.appendingPathComponent(record.id + ".lock")) else {
        return .skipped  // It came back to life.
      }
      guard let folder = try open(record) else {
        lockHandle.release()
        return .skipped
      }
      guard folder.folderID == record.folderID else {
        lockHandle.release()
        return .failed(VaultFilesError.wrongKey)
      }
      let session = DecryptSession(
        folder: folder, parent: parent, record: record, snapshot: Snapshot(), lockHandle: lockHandle)
      guard let snapshot = try? session.loadSnapshot() else {
        session.removeCopyAndRecord()
        return .discarded
      }
      session.snapshot = snapshot
      if !FileManager.default.fileExists(atPath: session.copyURL.path) {
        session.removeCopyAndRecord()
        return .sealed(Report())
      }
      return .sealed(try session.lock())
    } catch {
      return .failed(error)
    }
  }

  // MARK: Files

  private var sessionsURL: URL { parentURL.appendingPathComponent(Self.sessionsDirectoryName, isDirectory: true) }
  private var recordURL: URL { sessionsURL.appendingPathComponent(record.id + ".json") }
  private var snapshotURL: URL { sessionsURL.appendingPathComponent(record.id + ".snapshot") }
  private var lockURL: URL { sessionsURL.appendingPathComponent(record.id + ".lock") }

  private func saveRecord() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: recordURL, options: .atomic)
  }

  /// The snapshot holds names and hashes of the plaintext, so it is sealed with the folder's key.
  private func saveSnapshot() throws {
    let data = try JSONEncoder().encode(snapshot)
    try EncryptedFile.seal(data, key: folder.subkeys.content, keyID: folder.key.id)
      .write(to: snapshotURL, options: .atomic)
  }

  private func loadSnapshot() throws -> Snapshot {
    let data = try EncryptedFile.open(Data(contentsOf: snapshotURL), key: folder.subkeys.content)
    return try JSONDecoder().decode(Snapshot.self, from: data)
  }

  struct FileState: Codable, Equatable {
    var size: Int64
    var modified: Double
    var hash: String
  }

  struct Snapshot: Codable {
    var files: [String: FileState] = [:]
    var directories: Set<String> = []
  }

  private struct ScannedFile {
    let url: URL
    let size: Int64
    let modified: Double
  }

  /// The copy's files and folders by normalized relative path. Symbolic links are skipped.
  private func scanCopy() throws -> (files: [String: ScannedFile], directories: Set<String>) {
    var files: [String: ScannedFile] = [:]
    var directories: Set<String> = []
    let fileManager = FileManager.default
    func visit(_ url: URL, _ components: [String]) throws {
      for name in try fileManager.contentsOfDirectory(atPath: url.path) where !Self.ignoredNames.contains(name) {
        guard let normalized = try? NameCipher.normalized(name) else { continue }
        let child = url.appendingPathComponent(name)
        let path = components + [normalized]
        guard let attributes = try? fileManager.attributesOfItem(atPath: child.path),
          let type = attributes[.type] as? FileAttributeType
        else { continue }
        if type == .typeDirectory {
          directories.insert(EncryptedFolder.join(path))
          try visit(child, path)
        } else if type == .typeRegular {
          let (size, modified) = Self.values(attributes)
          files[EncryptedFolder.join(path)] = ScannedFile(url: child, size: size, modified: modified)
        }
      }
    }
    try visit(copyURL, [])
    return (files, directories)
  }

  static func fileAttributes(_ url: URL) throws -> (size: Int64, modified: Double) {
    values(try FileManager.default.attributesOfItem(atPath: url.path))
  }

  private static func values(_ attributes: [FileAttributeKey: Any]) -> (size: Int64, modified: Double) {
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
    return (size, modified)
  }

  static func hash(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: EncryptedFile.defaultChunkSize), !data.isEmpty {
      hash.update(data: data)
    }
    return Data(hash.finalize()).hexString
  }

  static func uniqueName(_ name: String, in parent: URL) -> String {
    var candidate = name
    var number = 2
    while FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidate).path) {
      candidate = "\(name) \(number)"
      number += 1
    }
    return candidate
  }

  static func excludeFromBackup(_ url: URL) {
    #if canImport(Darwin)
      var url = url
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
    #endif
  }
}

/// An exclusive lock on a session's lock file, held while the session lives and released by the system when the
/// process ends, so recovery can tell a crashed session from a running one (in any app sharing the folder).
final class SessionLock: @unchecked Sendable {
  private var descriptor: Int32 = -1

  /// Takes the lock, or throws when someone holds it.
  init(url: URL) throws {
    #if canImport(Darwin) || canImport(Glibc)
      descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
      guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        descriptor = -1
        throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: url.path])
      }
    #else
      // No flock: sessions in other processes can't be told apart from crashed ones, so only recover at launch.
      FileManager.default.createFile(atPath: url.path, contents: nil)
    #endif
  }

  func release() {
    #if canImport(Darwin) || canImport(Glibc)
      if descriptor >= 0 {
        close(descriptor)
        descriptor = -1
      }
    #endif
  }

  deinit { release() }
}
