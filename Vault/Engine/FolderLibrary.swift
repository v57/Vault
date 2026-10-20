import ComponentKit
import Foundation
import Observation
import VaultFiles
import VaultKit

/// A folder as the screens show it.
struct FolderItem: Identifiable, Hashable {
  var record: VaultFolder
  var id: String { record.id }
  var name: String { record.name }
  /// Encrypted on this device (the remote copy is always ciphertext).
  var isEncrypted: Bool
  var isReadOnly: Bool
  var localURL: URL?
  var sharedWith: String?
}

/// A folder decrypted for other apps: the plain copy, when it locks, what was sealed back.
@MainActor
@Observable
final class FolderSession {
  let session: DecryptSession
  var lockDate: Date
  var sealedEdits = 0
  var activity = FolderActivity.idle
  @ObservationIgnored var lastError: String?

  init(session: DecryptSession) {
    self.session = session
    lockDate = session.lockDate
  }

  var copyURL: URL { session.copyURL }
  var minutesLeft: Int { max(0, Int((lockDate.timeIntervalSinceNow / 60).rounded(.up))) }
  /// How much of the decrypted time is left, for the countdown ring.
  var fractionLeft: Double {
    let total = lockDate.timeIntervalSince(session.started)
    return total > 0 ? max(0, min(1, lockDate.timeIntervalSinceNow / total)) : 0
  }
}

/// The encrypted and synced folders: their records in the vault, their encrypted contents through VaultFiles, and
/// the timed plain copies other apps open. A copy is sealed back on a timer (and as files change on the Mac), and
/// locked (sealed, then deleted) when its time runs out or the user locks it. Copies a crash left behind are sealed
/// and removed at launch.
@MainActor
@Observable
final class FolderLibrary {
  let vault: Vault
  let keys: VaultKeyProvider
  let sync: any FolderSyncEngine
  /// Where plain copies go: the app group container's `Decrypted` folder on the Mac, Documents on iPad (Files
  /// shows it under On My iPad › Vault).
  let decryptedRoot: URL
  private(set) var sessions: [String: FolderSession] = [:]
  /// Bumped every few seconds so countdowns redraw.
  private(set) var tick = Date.now
  /// Caches filled while views draw, so they aren't observed; `revision` is, and `invalidate()` bumps it.
  @ObservationIgnored private var opened: [String: EncryptedFolder] = [:]
  @ObservationIgnored private var listings: [String: [FileEntry]] = [:]
  @ObservationIgnored private var totalsCache: [String: (items: Int, bytes: Int64)] = [:]
  private(set) var revision = 0
  private var timer: Timer?
  #if os(macOS)
    private var watchers: [String: FolderWatcher] = [:]
  #endif
  var lastError: String?

  init(vault: Vault, keys: VaultKeyProvider = KeychainKeyProvider(), sync: any FolderSyncEngine, decryptedRoot: URL? = nil) {
    self.vault = vault
    self.keys = keys
    self.sync = sync
    #if os(macOS)
      self.decryptedRoot = decryptedRoot ?? VaultConfiguration.defaultDirectory().deletingLastPathComponent().appendingPathComponent("Decrypted")
    #else
      self.decryptedRoot = decryptedRoot ?? URL.documentsDirectory
    #endif
    recoverLeftovers()
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.heartbeat() }
    }
  }

  // MARK: Folders

  var folders: [FolderItem] {
    let device = vault.deviceID
    return vault.folders.map { record in
      let shared = vault.people.first { $0.roles[record.id] != nil }?.name.split(separator: " ").first.map(String.init)
      return FolderItem(
        record: record, isEncrypted: record.storage(for: device) == .encrypted, isReadOnly: record.mode(for: device) == .readOnly,
        localURL: record.path(for: device).map { URL(fileURLWithPath: $0, isDirectory: true) }, sharedWith: shared)
    }
  }

  func folder(_ id: String) -> FolderItem? { folders.first { $0.id == id } }

  var hasDecrypted: Bool { !sessions.isEmpty }

  func session(for id: String) -> FolderSession? { sessions[id] }

  /// The folder's encrypted contents on this device.
  func encrypted(_ id: String) throws -> EncryptedFolder {
    if let open = opened[id] { return open }
    guard let item = folder(id), let url = item.localURL else { throw NotYetAvailable(what: "Opening folders not on this device") }
    guard let wrapped = item.record.wrappedKey else { throw VaultFilesError.wrongKey }
    let folder = try EncryptedFolder(url: url, key: FolderKey(wrapped: wrapped, keys: keys))
    opened[id] = folder
    return folder
  }

  /// The entries at `path` (a folder's root is ""): the plain copy's while decrypted, the plain folder's for a
  /// folder kept plain here, else the encrypted folder's (names and sizes decrypted). Read once, kept until
  /// something changes.
  func entries(_ id: String, path: String = "") -> [FileEntry] {
    _ = revision
    let key = id + "/" + path
    if let cached = listings[key] { return cached }
    do {
      let entries: [FileEntry]
      if let live = sessions[id] {
        entries = try FileEntry.list(live.copyURL, path: path)
      } else if let item = folder(id), !item.isEncrypted, let url = item.localURL {
        entries = try FileEntry.list(url, path: path)
      } else {
        entries = try encrypted(id).list(path).map(FileEntry.init(_:))
      }
      let sorted = entries.sorted { a, b in
        a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
      }
      listings[key] = sorted
      return sorted
    } catch {
      lastError = error.localizedDescription
      return []
    }
  }

  /// How many items a subfolder holds, for the Size column.
  func itemCount(_ id: String, path: String) -> Int { entries(id, path: path).count }

  /// Items and plaintext bytes in the whole folder.
  func totals(_ id: String) -> (items: Int, bytes: Int64) {
    _ = revision
    if let cached = totalsCache[id] { return cached }
    var all: [FileEntry] = []
    if let item = folder(id), !item.isEncrypted, let url = item.localURL {
      all = (try? FileEntry.walk(url)) ?? []
    } else {
      all = ((try? encrypted(id).walk()) ?? []).map(FileEntry.init(_:))
    }
    let totals = (all.count, all.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) })
    totalsCache[id] = totals
    return totals
  }

  /// Makes a new encrypted folder at `url` with a fresh key wrapped by the vault key.
  @discardableResult
  func create(name: String, at url: URL) throws -> VaultFolder {
    let key = FolderKey()
    _ = try EncryptedFolder(url: url, key: key)
    var record = VaultFolder(name: name, encrypted: true, wrappedKey: try key.wrapped(with: keys))
    record.setPath(url.path, for: vault.deviceID)
    record.setStorage(.encrypted, for: vault.deviceID)
    vault.save(record)
    return record
  }

  /// Sets this device's mode for a folder (read-write or read-only) or how it is kept on disk.
  func setMode(_ mode: VaultFolder.Mode, for id: String) {
    guard var record = folder(id)?.record else { return }
    record.setMode(mode, for: vault.deviceID)
    vault.save(record)
  }

  func setStorage(_ storage: VaultFolder.Storage, for id: String) {
    guard var record = folder(id)?.record else { return }
    record.setStorage(storage, for: vault.deviceID)
    vault.save(record)
  }

  // MARK: Decrypting for other apps

  /// Decrypts the folder into a plain copy that locks after `duration`.
  @discardableResult
  func decrypt(_ id: String, for duration: TimeInterval) throws -> FolderSession {
    if let live = sessions[id] { return live }
    try FileManager.default.createDirectory(at: decryptedRoot, withIntermediateDirectories: true)
    let session = try DecryptSession.start(try encrypted(id), in: decryptedRoot, duration: duration)
    let live = FolderSession(session: session)
    session.onActivity = { [weak live] activity in
      Task { @MainActor in live?.activity = activity }
    }
    sessions[id] = live
    invalidate()
    #if os(macOS)
      watchers[id] = session.watch { [weak self, weak live] result in
        Task { @MainActor in
          switch result {
          case .success(let report):
            live?.sealedEdits += report.changed
            self?.invalidate()
          case .failure(let error): live?.lastError = error.localizedDescription
          }
        }
      }
    #endif
    return live
  }

  func extend(_ id: String, by interval: TimeInterval = 30 * 60) {
    guard let live = sessions[id] else { return }
    do {
      try live.session.extend(by: interval)
      live.lockDate = live.session.lockDate
    } catch {
      live.lastError = error.localizedDescription
    }
  }

  /// Seals what changed, then deletes the plain copy.
  func lock(_ id: String) {
    guard let live = sessions[id] else { return }
    #if os(macOS)
      watchers.removeValue(forKey: id)?.stop()
    #endif
    do {
      _ = try live.session.lock()
      sessions[id] = nil
      invalidate()
    } catch {
      live.lastError = error.localizedDescription
    }
  }

  func lockAll() {
    for id in sessions.keys { lock(id) }
  }

  /// A one-shot plain copy at `destination`, not watched and not locked.
  func exportDecrypted(_ id: String, to destination: URL) throws {
    try encrypted(id).exportDecrypted(to: destination)
  }

  /// Seals every copy's changes, locks the expired ones, redraws the countdowns.
  private func heartbeat() {
    tick = .now
    for (id, live) in sessions {
      if live.session.isExpired {
        lock(id)
        continue
      }
      #if !os(macOS)
        if let report = try? live.session.sealChanges(), !report.isEmpty {
          live.sealedEdits += report.changed
          invalidate()
        }
      #endif
    }
  }

  /// Seals and removes plain copies a crash left behind.
  private func recoverLeftovers() {
    let byPath = Dictionary(folders.compactMap { item in item.localURL.map { ($0.standardizedFileURL.path, item.id) } }, uniquingKeysWith: { a, _ in a })
    _ = DecryptSession.recoverLeftovers(in: decryptedRoot) { [self] record in
      guard let id = byPath[URL(fileURLWithPath: record.folderPath).standardizedFileURL.path] else { return nil }
      return try? MainActor.assumeIsolated { try encrypted(id) }
    }
  }

  /// Syncs every folder that has a remote. Until the folder sync engine is wired in, it only refreshes what's shown.
  func syncAll() async {
    invalidate()
  }

  func checkRemotes() {
    invalidate()
  }

  /// Drops the cached listings so the next draw reads the folders again.
  func invalidate() {
    listings = [:]
    totalsCache = [:]
    revision += 1
  }

  // MARK: State in the live icons

  /// A folder row's tile: the countdown while decrypted, the ring of a transfer while syncing.
  func rowStatus(_ id: String) -> WorkStatus {
    _ = tick
    if let live = sessions[id] {
      if live.activity.phase == .sealing { return .working(progress: live.activity.fraction) }
      return .working(progress: live.fractionLeft)
    }
    if let activity = sync.activity(for: id), activity.isReceiving {
      return .working(progress: Double(activity.receivingDone) / Double(max(1, activity.receivingTotal)))
    }
    return .idle
  }

  /// The Folders section's tile: the first decrypted folder's countdown.
  var headerStatus: WorkStatus {
    _ = tick
    if let live = sessions.values.first { return .working(progress: live.fractionLeft) }
    return .idle
  }
}

/// A file or folder in a listing, from an encrypted folder or a plain one.
struct FileEntry: Identifiable, Hashable {
  var name: String
  var path: String
  var isDirectory: Bool
  var size: Int64
  var modified: Date?
  var id: String { path }

  init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date?) {
    self.name = name
    self.path = path
    self.isDirectory = isDirectory
    self.size = size
    self.modified = modified
  }

  init(_ entry: EncryptedFolder.Entry) {
    self.init(name: entry.name, path: entry.path, isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified)
  }

  private static let hidden: Set<String> = [".DS_Store", DecryptSession.neverIndexName]

  /// A plain folder's entries at `path`.
  static func list(_ root: URL, path: String) throws -> [FileEntry] {
    let url = path.isEmpty ? root : root.appendingPathComponent(path)
    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
    return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
      .filter { !hidden.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".v57") }
      .map { item in
        let values = try? item.resourceValues(forKeys: Set(keys))
        let name = item.lastPathComponent
        return FileEntry(
          name: name, path: path.isEmpty ? name : path + "/" + name, isDirectory: values?.isDirectory ?? false,
          size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
      }
  }

  /// Every entry under a plain folder.
  static func walk(_ root: URL, path: String = "") throws -> [FileEntry] {
    try list(root, path: path).flatMap { entry in [entry] + (entry.isDirectory ? try walk(root, path: entry.path) : []) }
  }
}
