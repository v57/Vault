import CryptoKit
import Foundation

#if os(Linux)
  import CVaultLinux
#endif

/// Keeps a folder of note files and the vault's notes the same, both ways.
///
/// The vault (CloudKit) syncs notes between devices; the folder is this device's copy of them as real files, so
/// Finder, Files, other editors, git and backups work on them. Markdown runs the mirror on its notes folder:
/// - a file saved, renamed, moved or deleted in the folder (by Markdown or any other app) becomes a change to its
///   note in the vault;
/// - a note changed in the vault (by Shell, or on another device) is written to its file;
/// - when both changed since the last pass, the texts merge line by line against the last synced text.
///
/// Each file carries its note's id in an extended attribute (`dev.v57.note-id`). Editors that save by replacing
/// the file drop it; the file is then recognized by its last known path. An index (the state of the last pass:
/// path, content hash and the note's clock per id) tells which side changed.
///
/// Notes are `.md` (plain) or `.mdenc` (encrypted with the vault key, `EncryptedNote`); any other file under
/// `VaultNoteFile.maximumSize` (images next to a note) syncs as a `VaultNoteFile`.
public final class NotesMirror: @unchecked Sendable {
  public let folder: URL
  private let store: VaultStore
  private let keys: VaultKeyProvider
  private let bases: NoteBaseCache
  private let indexURL: URL
  private let queue = DispatchQueue(label: "dev.v57.vault.notes-mirror")
  private let lock = NSLock()
  private var index: Index
  private var pending: DispatchWorkItem?
  private var observer: VaultChangeObserver?
  private var presenter: MirrorPresenter?
  private let lockURL: URL
  /// The lock file while this mirror holds it (`holdsLock()`).
  private var lockDescriptor: Int32 = -1
  #if os(Windows)
    /// The state directories whose mirror runs, where no file lock is taken.
    nonisolated(unsafe) private static var running: Set<String> = []
    private static let runningLock = NSLock()
  #endif

  /// The last problem, for the UI.
  public var lastError: String? { lock.withLock { error } }
  private var error: String?

  /// Whether files deleted elsewhere go to the Trash (macOS) rather than away for good.
  public var usesTrash = true

  /// Called on the main queue after a pass wrote, moved or deleted files.
  public var didChangeFiles: (@Sendable () -> Void)?

  public static let idAttribute = "dev.v57.note-id"

  struct Entry: Codable, Equatable {
    var path: String
    var hash: String
    var clock: String
  }

  struct Index: Codable {
    var folder: String
    var entries: [String: Entry]
  }

  /// What a pass did, for tests.
  public struct Report: Equatable, Sendable {
    public var sent = 0
    public var written = 0
    public var merged = 0
    public var removedFiles = 0
    public var removedNotes = 0
  }

  /// - Parameters:
  ///   - folder: the notes folder.
  ///   - stateDirectory: where the mirror keeps its index and the merge bases (the app's own storage).
  public init(folder: URL, store: VaultStore, keys: VaultKeyProvider, stateDirectory: URL) {
    self.folder = folder.standardizedFileURL.resolvingSymlinksInPath()
    self.store = store
    self.keys = keys
    bases = NoteBaseCache(directory: stateDirectory.appendingPathComponent("NoteBases", isDirectory: true), keys: keys)
    indexURL = stateDirectory.appendingPathComponent("NotesMirror.json")
    lockURL = stateDirectory.appendingPathComponent("NotesMirror.lock")
    index = Index(folder: self.folder.path, entries: [:])
    try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    loadIndex()
  }

  deinit { releaseLock() }

  /// Runs a pass now and follows both sides from then on: the folder (any app's change) and the vault (another
  /// app's or device's change).
  public func start() {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    observer = VaultChangeObserver { [weak self] in self?.scheduleReconcile() }
    let presenter = MirrorPresenter(url: folder) { [weak self] in self?.scheduleReconcile() }
    #if canImport(ObjectiveC)
      NSFileCoordinator.addFilePresenter(presenter)
    #endif
    self.presenter = presenter
    scheduleReconcile(after: 0)
  }

  /// Stops following the folder, and lets another mirror of it take over.
  public func stop() {
    #if canImport(ObjectiveC)
      if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
    #endif
    presenter = nil
    observer = nil
    queue.sync { releaseLock() }
  }

  /// Runs a pass shortly (changes come in bursts).
  public func scheduleReconcile(after delay: TimeInterval = 0.4) {
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let report = self.reconcile()
      if report.written + report.removedFiles > 0, let didChangeFiles = self.didChangeFiles {
        DispatchQueue.main.async(execute: didChangeFiles)
      }
    }
    lock.withLock {
      pending?.cancel()
      pending = item
    }
    queue.asyncAfter(deadline: .now() + delay, execute: item)
  }

  /// One pass, synchronously (on the mirror's queue).
  @discardableResult
  public func reconcileNow() -> Report {
    queue.sync { reconcile() }
  }

  // MARK: - The pass

  private struct LocalFile {
    let url: URL
    let path: String
    let isNote: Bool
    let id: String?
    let data: Data
    let hash: String
    let modified: Date
  }

  private func reconcile() -> Report {
    var report = Report()
    guard FileManager.default.fileExists(atPath: folder.path), holdsLock() else { return report }
    let files = scan()
    guard let notes = try? store.items(kind: VaultNote.kind), let others = try? store.items(kind: VaultNoteFile.kind)
    else { return report }
    let records = Dictionary((notes + others).map { ($0.id, $0) }) { first, _ in first }

    // A folder whose every known file vanished is more likely unmounted or replaced than emptied: start over
    // rather than delete every note.
    if files.isEmpty, index.entries.count > 3 { index.entries = [:] }

    // Files by note id: the extended attribute, else the path the id had last time.
    var byID: [String: LocalFile] = [:]
    var unknown: [LocalFile] = []
    for file in files {
      if let id = file.id, byID[id] == nil { byID[id] = file } else { unknown.append(file) }
    }
    let idsByPath = Dictionary(index.entries.map { ($0.value.path, $0.key) }) { first, _ in first }
    for file in unknown {
      if let id = idsByPath[file.path], byID[id] == nil {
        byID[id] = file
      } else {
        byID[UUID().uuidString] = file
      }
    }

    for id in Set(byID.keys).union(index.entries.keys).union(records.keys) {
      do {
        try reconcile(id: id, file: byID[id], record: records[id], entry: index.entries[id], report: &report)
      } catch {
        lock.withLock { self.error = error.localizedDescription }
      }
    }
    saveIndex()
    return report
  }

  private func reconcile(id: String, file: LocalFile?, record: VaultItem?, entry: Entry?, report: inout Report) throws {
    switch (file, record, entry) {
    case let (file?, record?, entry?):
      let fileChanged = file.hash != entry.hash || file.path != entry.path
      let recordChanged = record.fields.latestClock.description != entry.clock
      if fileChanged && recordChanged {
        try mergeBoth(id: id, file: file, record: record, keepLocalPath: file.path != entry.path)
        report.merged += 1
      } else if fileChanged {
        try send(file, id: id, over: record)
        report.sent += 1
      } else if recordChanged {
        try write(record, over: file)
        report.written += 1
      } else if file.id != id {
        Self.setID(id, of: file.url)
      }

    case let (file?, record?, nil):
      // Both exist but weren't paired before (a new index): the same content needs nothing; else the newer wins.
      let same =
        file.isNote
        ? (try? text(of: file)) == VaultNote(id: id, values: record.values).text
        : file.data == VaultNoteFile(id: id, values: record.values).data
      if same {
        index.entries[id] = Entry(path: file.path, hash: file.hash, clock: record.fields.latestClock.description)
        Self.setID(id, of: file.url)
      } else if file.modified > record.modified {
        try send(file, id: id, over: record)
        report.sent += 1
      } else {
        try write(record, over: file)
        report.written += 1
      }

    case let (file?, nil, entry?):
      if file.hash == entry.hash {
        // Deleted elsewhere.
        try removeFile(file.url)
        index.entries[id] = nil
        report.removedFiles += 1
      } else {
        // Edited here after it was deleted elsewhere: the edit brings it back.
        try send(file, id: id, over: nil)
        report.sent += 1
      }

    case let (file?, nil, nil):
      try send(file, id: id, over: nil)
      report.sent += 1

    case let (nil, record?, entry?):
      if record.fields.latestClock.description == entry.clock {
        // Deleted here.
        try store.delete(id: id)
        index.entries[id] = nil
        report.removedNotes += 1
      } else {
        // Changed elsewhere after it was deleted here: the change brings it back.
        try write(record, over: nil)
        report.written += 1
      }

    case let (nil, record?, nil):
      try write(record, over: nil)
      report.written += 1

    case (nil, nil, _?):
      index.entries[id] = nil

    case (nil, nil, nil):
      break
    }
  }

  // MARK: - File → vault

  private func send(_ file: LocalFile, id: String, over record: VaultItem?) throws {
    if file.isNote {
      let text = try text(of: file)
      var note = record.map { VaultNote(id: id, values: $0.values) } ?? VaultNote(id: id, name: "")
      (note.folder, note.name, note.encrypted) = Self.location(of: file.path)
      note.text = text
      try store.save(note)
      bases.setBase(text, for: baseKey(id))
    } else {
      guard file.data.count <= VaultNoteFile.maximumSize else { return }
      try store.save(VaultNoteFile(id: id, path: file.path, data: file.data))
    }
    Self.setID(id, of: file.url)
    try remember(id: id, path: file.path, hash: file.hash)
  }

  private func mergeBoth(id: String, file: LocalFile, record: VaultItem, keepLocalPath: Bool) throws {
    guard file.isNote else {
      // Not text: the newer copy wins.
      if file.modified > record.modified { try send(file, id: id, over: record) } else { try write(record, over: file) }
      return
    }
    var note = VaultNote(id: id, values: record.values)
    let local = try text(of: file)
    let base = bases.base(for: baseKey(id)) ?? ""
    note.text = TextMerge.merge(base: base, ours: local, theirs: note.text, oursLabel: "This device", theirsLabel: "Other device").text
    if keepLocalPath { (note.folder, note.name, note.encrypted) = Self.location(of: file.path) }
    try store.save(note)
    guard let saved = try store.item(id: id) else { return }
    try write(saved, over: file)
  }

  // MARK: - Vault → file

  private func write(_ record: VaultItem, over file: LocalFile?) throws {
    let data: Data
    let path: String
    var text: String?
    if record.kind == VaultNote.kind {
      let note = VaultNote(id: record.id, values: record.values)
      data = note.encrypted ? try EncryptedNote.seal(note.text, keys: keys) : Data(note.text.utf8)
      path = note.path
      text = note.text
    } else {
      let other = VaultNoteFile(id: record.id, values: record.values)
      data = other.data
      path = other.path
    }
    var target = folder.appendingPathComponent(path)
    let fileManager = FileManager.default
    // The place is taken by another file: the next free name.
    if fileManager.fileExists(atPath: target.path), Self.id(of: target) != record.id, file?.url != target {
      target = Self.availableURL(for: target)
    }
    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let file, file.url.path != target.path {
      try coordinateMove(from: file.url, to: target)
    }
    try coordinateWrite(data, to: target)
    Self.setID(record.id, of: target)
    if let text { bases.setBase(text, for: baseKey(record.id)) }
    index.entries[record.id] = Entry(
      path: relativePath(of: target), hash: Self.hash(data), clock: record.fields.latestClock.description)
  }

  private func remember(id: String, path: String, hash: String) throws {
    guard let item = try store.item(id: id) else { return }
    index.entries[id] = Entry(path: path, hash: hash, clock: item.fields.latestClock.description)
  }

  // MARK: - Files

  private func scan() -> [LocalFile] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var files: [LocalFile] = []
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
      let isNote = Self.isNote(url)
      if !isNote, (values.fileSize ?? 0) > VaultNoteFile.maximumSize { continue }
      guard let data = coordinatedRead(url) else { continue }
      files.append(
        LocalFile(
          url: url, path: relativePath(of: url), isNote: isNote, id: Self.id(of: url), data: data,
          hash: Self.hash(data), modified: values.contentModificationDate ?? .distantPast))
    }
    return files
  }

  private func text(of file: LocalFile) throws -> String {
    if EncryptedNote.isEncrypted(file.url) {
      return file.data.isEmpty ? "" : try EncryptedNote.open(file.data, keys: keys)
    }
    return String(decoding: file.data, as: UTF8.self)
  }

  private func relativePath(of url: URL) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    return path.hasPrefix(folder.path + "/") ? String(path.dropFirst(folder.path.count + 1)) : url.lastPathComponent
  }

  /// A note's folder, name and encryption from its path.
  static func location(of path: String) -> (folder: String, name: String, encrypted: Bool) {
    let folder = (path as NSString).deletingLastPathComponent
    let file = (path as NSString).lastPathComponent
    return (folder, (file as NSString).deletingPathExtension, (file as NSString).pathExtension.lowercased() == EncryptedNote.fileExtension)
  }

  static func isNote(_ url: URL) -> Bool {
    ["md", "markdown", EncryptedNote.fileExtension].contains(url.pathExtension.lowercased())
  }

  private func baseKey(_ id: String) -> URL {
    URL(fileURLWithPath: "/vault-note/" + id)
  }

  private func loadIndex() {
    let saved = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode(Index.self, from: $0) }
    // An index of another folder says nothing about this one: start over (nothing is deleted then).
    index = saved?.folder == folder.path ? saved! : Index(folder: folder.path, entries: [:])
  }

  private func saveIndex() {
    if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
  }

  // MARK: - One mirror at a time

  /// Whether this mirror runs the passes, taking the state directory's lock when it is free. Only one mirror of a
  /// state directory runs at a time (another window's, or another copy of the app's): two would each take a file the
  /// other just gave an id, and lost when the editor replaced the file, for a new note, and write it back beside
  /// itself as "Untitled 2". The mirror that takes over starts from the index the other one saved.
  private func holdsLock() -> Bool {
    guard lockDescriptor < 0 else { return true }
    #if os(Windows)
      let taken = Self.runningLock.withLock { Self.running.insert(lockURL.path).inserted }
      guard taken else { return false }
      lockDescriptor = 0
    #else
      let descriptor = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
      guard descriptor >= 0 else { return true }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        return false
      }
      lockDescriptor = descriptor
    #endif
    loadIndex()
    return true
  }

  private func releaseLock() {
    guard lockDescriptor >= 0 else { return }
    #if os(Windows)
      _ = Self.runningLock.withLock { Self.running.remove(lockURL.path) }
    #else
      flock(lockDescriptor, LOCK_UN)
      close(lockDescriptor)
    #endif
    lockDescriptor = -1
  }

  #if canImport(ObjectiveC)
  private func coordinatedRead(_ url: URL) -> Data? {
    var result: Data?
    var error: NSError?
    NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &error) {
      result = try? Data(contentsOf: $0)
    }
    return result
  }

  private func coordinateWrite(_ data: Data, to url: URL) throws {
    var writeError: Error?
    var error: NSError?
    NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forReplacing, error: &error) {
      do { try data.write(to: $0, options: .atomic) } catch { writeError = error }
    }
    if let failure = error ?? writeError { throw failure }
  }

  private func coordinateMove(from source: URL, to target: URL) throws {
    var moveError: Error?
    var error: NSError?
    let coordinator = NSFileCoordinator(filePresenter: presenter)
    coordinator.coordinate(
      writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &error
    ) { from, to in
      do {
        try FileManager.default.moveItem(at: from, to: to)
        coordinator.item(at: from, didMoveTo: to)
      } catch {
        moveError = error
      }
    }
    if let failure = error ?? moveError { throw failure }
  }

  private func removeFile(_ url: URL) throws {
    var removeError: Error?
    var error: NSError?
    NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forDeleting, error: &error) {
      do {
        #if os(macOS)
          // Into the Trash, where a note deleted on another device can still be taken back.
          if usesTrash {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
            return
          }
        #endif
        try FileManager.default.removeItem(at: $0)
      } catch {
        removeError = error
      }
    }
    if let failure = error ?? removeError { throw failure }
  }
  #else
  // No file coordination off Apple platforms: plain file operations.
  private func coordinatedRead(_ url: URL) -> Data? {
    try? Data(contentsOf: url)
  }

  private func coordinateWrite(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
  }

  private func coordinateMove(from source: URL, to target: URL) throws {
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.moveItem(at: source, to: target)
  }

  private func removeFile(_ url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }
  #endif

  static func availableURL(for url: URL) -> URL {
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    var number = 2
    var candidate = url
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
      number += 1
    }
    return candidate
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Note ids on files

  #if os(Windows)
    // An NTFS alternate data stream holds the id: it travels with the file through moves and renames.
    static func id(of url: URL) -> String? {
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: url.path + ":" + idAttribute)), !data.isEmpty else { return nil }
      return String(decoding: data, as: UTF8.self)
    }

    static func setID(_ id: String, of url: URL) {
      guard self.id(of: url) != id else { return }
      try? Data(id.utf8).write(to: URL(fileURLWithPath: url.path + ":" + idAttribute))
    }
  #elseif canImport(Glibc)
    // Linux keeps user attributes in the "user." namespace.
    static func id(of url: URL) -> String? {
      let name = "user." + idAttribute
      let size = getxattr(url.path, name, nil, 0)
      guard size > 0 else { return nil }
      var buffer = [UInt8](repeating: 0, count: size)
      guard getxattr(url.path, name, &buffer, size) == size else { return nil }
      return String(decoding: buffer, as: UTF8.self)
    }

    static func setID(_ id: String, of url: URL) {
      guard self.id(of: url) != id else { return }
      let bytes = Array(id.utf8)
      _ = setxattr(url.path, "user." + idAttribute, bytes, bytes.count, 0)
    }
  #else
    static func id(of url: URL) -> String? {
      let size = getxattr(url.path, idAttribute, nil, 0, 0, 0)
      guard size > 0 else { return nil }
      var buffer = [UInt8](repeating: 0, count: size)
      guard getxattr(url.path, idAttribute, &buffer, size, 0, 0) == size else { return nil }
      return String(decoding: buffer, as: UTF8.self)
    }

    static func setID(_ id: String, of url: URL) {
      guard self.id(of: url) != id else { return }
      let bytes = Array(id.utf8)
      _ = setxattr(url.path, idAttribute, bytes, bytes.count, 0, 0)
    }
  #endif
}

#if canImport(ObjectiveC)
/// Reports changes inside the mirrored folder.
private final class MirrorPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  private let changed: @Sendable () -> Void

  init(url: URL, changed: @escaping @Sendable () -> Void) {
    presentedItemURL = url
    self.changed = changed
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
  }

  func presentedSubitemDidChange(at url: URL) { changed() }
  func presentedItemDidChange() { changed() }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
  func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
    changed()
    completionHandler(nil)
  }
}
#else
/// Reports changes inside the mirrored folder: off Apple platforms, by comparing the folder's files (names, sizes,
/// modification dates) once a second.
private final class MirrorPresenter: @unchecked Sendable {
  private let url: URL
  private let changed: @Sendable () -> Void
  private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
  private var snapshot: [String: [Double]] = [:]

  init(url: URL, changed: @escaping @Sendable () -> Void) {
    self.url = url
    self.changed = changed
    snapshot = Self.snapshot(of: url)
    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
    timer.setEventHandler { [weak self] in self?.check() }
    timer.resume()
  }

  private func check() {
    let current = Self.snapshot(of: url)
    guard current != snapshot else { return }
    snapshot = current
    changed()
  }

  private static func snapshot(of folder: URL) -> [String: [Double]] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [:] }
    var result: [String: [Double]] = [:]
    for case let file as URL in files {
      let values = try? file.resourceValues(forKeys: Set(keys))
      result[file.path] = [values?.contentModificationDate?.timeIntervalSince1970 ?? 0, Double(values?.fileSize ?? 0)]
    }
    return result
  }

  deinit { timer.cancel() }
}
#endif
