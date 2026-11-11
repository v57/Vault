import ComponentKit
import Foundation
import Observation
import VaultFiles
import VaultKit
import VaultSync

/// Folder sync on real folders: one VaultSync `FolderSync` per folder that has a remote and a place on this device,
/// driven when the app opens or comes back, on Sync Now and on a timer while it's open (Settings' "Check remotes").
/// Each engine's status is copied here for the screens. Never a helper process: nothing runs while Vault is closed,
/// except the system's background turn on iPhone and iPad.
@MainActor
@Observable
final class LiveFolderSync: FolderSyncEngine {
  @ObservationIgnored let vault: Vault
  /// The user's identity: opens the folder keys and signs changes and member lists.
  @ObservationIgnored private let identity: () throws -> PersonalIdentity
  /// The backend for a remote record, nil for a kind that has none yet.
  @ObservationIgnored private let fileSystem: (VaultRemote) throws -> (any RemoteFileSystem)?
  /// Each folder's sync state, sealed, in the app's own Application Support (never in the folder or the store).
  @ObservationIgnored private let stateDirectory: URL
  /// The name a device's id stands for, in the screens.
  /// The name of one of the user's devices, nil for a device that isn't theirs (on a shared folder, the owner's).
  @ObservationIgnored var deviceName: (String) -> String? = { _ in nil }
  @ObservationIgnored private weak var library: FolderLibrary?
  @ObservationIgnored private var engines: [String: Engine] = [:]
  @ObservationIgnored private var timer: Timer?

  private var statuses: [String: FolderSyncStatus] = [:]
  /// What stopped a folder's last pass before its engine ran (no remote record, a backend not built, no identity).
  private var problems: [String: String] = [:]
  /// Shared folders whose owner hasn't added this person yet: not a problem, just not open yet.
  private var waiting: Set<String> = []
  private var syncing: Set<String> = []
  /// Bumped every half minute so "checked 2 min ago" moves on.
  private var clock = Date.now

  private struct Engine {
    /// What the engine was made from: a change to any of it makes a new one (its state is on disk).
    var key: String
    var sync: FolderSync
  }

  init(
    vault: Vault, identity: @escaping () throws -> PersonalIdentity = { try VaultPersonalIdentity.current() },
    fileSystem: @escaping (VaultRemote) throws -> (any RemoteFileSystem)? = LiveFolderSync.backend(for:),
    stateDirectory: URL = LiveFolderSync.defaultStateDirectory
  ) {
    self.vault = vault
    self.identity = identity
    self.fileSystem = fileSystem
    self.stateDirectory = stateDirectory.appendingPathComponent(vault.accountID, isDirectory: true)
  }

  /// `Application Support/Vault/FolderSync` (the app's own container on iPhone and iPad).
  nonisolated static var defaultStateDirectory: URL {
    URL.applicationSupportDirectory.appendingPathComponent("FolderSync", isDirectory: true)
  }

  /// A remote's backend: S3 today (`RemoteConnections`), with the secret from the keychain.
  nonisolated static func backend(for remote: VaultRemote) throws -> (any RemoteFileSystem)? {
    try RemoteConnections.fileSystem(for: remote, secret: remote.secret)
  }

  func attach(_ library: FolderLibrary) {
    self.library = library
    scheduleTimer()
    // On open: every folder's remote once.
    Task { await syncAll() }
  }

  /// Every few minutes while the app is open, as Settings' "Check remotes" says (5 by default).
  private func scheduleTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.clock = .now
        // Read each time, so a change in Settings applies from the next check.
        let minutes = max(1, UserDefaults.standard.object(forKey: "remoteCheckMinutes") as? Int ?? 5)
        if self.clock.timeIntervalSince(self.lastTimedCheck) >= TimeInterval(minutes * 60) - 1 {
          self.lastTimedCheck = self.clock
          await self.syncAll()
        }
      }
    }
  }

  @ObservationIgnored private var lastTimedCheck = Date.now

  // MARK: Engines

  private func record(_ id: String) -> VaultFolder? { vault.folders.first { $0.id == id } }

  /// The folder's engine, made (or made again when its remote, place or mode changed) on first use. nil when the
  /// folder doesn't sync through a remote or has no place on this device yet.
  private func engine(for id: String) throws -> FolderSync? {
    guard let folder = record(id), let remoteID = folder.remoteID else { return nil }
    let device = vault.deviceID
    guard let path = folder.path(for: device) else { return nil }
    guard let remote = vault.remote(id: remoteID) else {
      throw SyncSetupError("The remote this folder syncs through isn’t in the vault any more.")
    }
    let storage = folder.storage(for: device)
    let key = [
      remote.id, remote.endpoint, remote.bucket, remote.region, remote.path, remote.accessKeyID,
      remote.kind.rawValue, path, storage.rawValue, folder.mode(for: device).rawValue, folder.syncPath,
      folder.ownerSigningKey ?? "",
    ].joined(separator: "\u{1}")
    if let engine = engines[id], engine.key == key { return engine.sync }
    guard remote.enabled else { throw SyncSetupError("The remote “\(remote.displayName)” is off. Turn it on in Remotes.") }
    guard let backend = try fileSystem(remote) else {
      throw NotYetAvailable(what: "Syncing through \(LocationKind(remote.kind).title) remotes")
    }
    let local: any SyncLocalFolder
    switch storage {
    case .plain: local = try PlainSyncFolder(url: URL(fileURLWithPath: path, isDirectory: true))
    case .encrypted:
      guard let library else { return nil }
      local = EncryptedSyncFolder(try library.encrypted(id))
    }
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    let sync = try FolderSync(
      FolderSync.Configuration(
        folder: folder, remote: backend, local: local, device: device, identity: try identity(),
        stateDirectory: stateDirectory))
    let handler: @Sendable (FolderSyncStatus) -> Void = { [weak self] status in
      Task { @MainActor [weak self] in self?.statuses[id] = status }
    }
    Task { await sync.observe(handler) }
    engines[id] = Engine(key: key, sync: sync)
    return sync
  }

  // MARK: Syncing

  func start(_ folderID: String) async throws {
    guard let folder = record(folderID), let remoteID = folder.remoteID, let remote = vault.remote(id: remoteID) else {
      throw SyncSetupError("Choose a remote for this folder first.")
    }
    guard remote.enabled else { throw SyncSetupError("The remote “\(remote.displayName)” is off. Turn it on in Remotes.") }
    guard let backend = try fileSystem(remote) else {
      throw NotYetAvailable(what: "Syncing through \(LocationKind(remote.kind).title) remotes")
    }
    let identity = try identity()
    if folder.isOwned(by: identity) {
      do {
        try await FolderSync.createRemoteFolder(
          remote: backend, remotePath: folder.syncPath, folderID: folder.id, owner: identity,
          ownerName: KitDevice.name)
      } catch FolderSyncError.folderExists {
        // Made before (another device of the user's, or an earlier try): the sync checks it's signed by the user.
      }
    }
    await sync(folderID)
    if waiting.contains(folderID) { return }
    if let problem = problems[folderID] ?? statuses[folderID]?.lastError { throw SyncSetupError(problem) }
  }

  func sync(_ folderID: String) async {
    guard !syncing.contains(folderID) else { return }
    syncing.insert(folderID)
    defer { syncing.remove(folderID) }
    do {
      guard let engine = try engine(for: folderID) else {
        problems[folderID] = nil
        return
      }
      problems[folderID] = nil
      try await engine.sync()
      waiting.remove(folderID)
    } catch FolderSyncError.notAMember where record(folderID)?.isShared == true {
      waiting.insert(folderID)
    } catch {
      waiting.remove(folderID)
      problems[folderID] = error.localizedDescription
    }
    library?.invalidate()
  }

  func syncAll() async {
    for folder in vault.folders where folder.remoteID != nil && folder.path(for: vault.deviceID) != nil {
      await sync(folder.id)
    }
  }

  func deliversKeys(for folderID: String) -> Bool {
    guard let folder = record(folderID), folder.remoteID != nil, folder.path(for: vault.deviceID) != nil,
      let identity = try? identity()
    else { return false }
    return folder.isOwned(by: identity)
  }

  func addMember(_ identity: PublicIdentity, name: String, role: VaultPerson.Role, to folderID: String) async throws {
    guard let engine = try engine(for: folderID) else {
      throw SyncSetupError("This folder doesn’t sync through a remote yet, so its key can’t reach anyone.")
    }
    try await engine.addMember(identity, name: name, role: role)
  }

  func removeMember(_ identity: PublicIdentity, from folderID: String) async throws {
    guard let engine = try engine(for: folderID) else { return }
    try await engine.removeMember(identity.signingKey)
  }

  func keepMine(_ path: String, in folderID: String) { answer(folderID) { try await $0.keepMine(path) } }
  func revert(_ path: String, in folderID: String) { answer(folderID) { try await $0.revertToRemote(path) } }
  func revertAll(in folderID: String) { answer(folderID) { try await $0.revertAll() } }

  private func answer(_ folderID: String, _ action: @escaping (FolderSync) async throws -> Void) {
    Task {
      do {
        guard let engine = try engine(for: folderID) else { return }
        try await action(engine)
      } catch {
        problems[folderID] = error.localizedDescription
      }
      library?.invalidate()
    }
  }

  // MARK: What the screens show

  func activity(for folderID: String) -> FolderSyncActivity? {
    guard let folder = record(folderID), let remoteID = folder.remoteID else { return nil }
    _ = clock
    let remote = vault.remote(id: remoteID)
    let status = statuses[folderID]
    var activity = FolderSyncActivity(folderName: folder.name)
    activity.source = remote?.name ?? String(localized: "the remote")
    let owner = (folder.ownerSigningKey as String?).flatMap { key in vault.people.first { $0.signingKey == key } }?.name
    // A change on a shared folder comes from the owner's devices, which aren't this user's.
    let sender = { (device: String) in self.deviceName(device) ?? owner ?? String(localized: "Another device") }
    if waiting.contains(folderID) {
      activity.waiting = String(localized: "Waiting for \(owner ?? String(localized: "the owner")) to add you")
    } else {
      activity.error = problems[folderID] ?? status?.lastError
    }
    activity.isWorking = syncing.contains(folderID) || (status.map { $0.phase != .idle } ?? false)
    guard let status else {
      activity.checked = activity.isWorking ? String(localized: "now") : String(localized: "not yet")
      return activity
    }
    activity.receiving = status.receiving.map { transfer in
      .init(
        name: transfer.name, detail: "\(Bytes.text(transfer.bytesDone)) of \(Bytes.text(transfer.bytesTotal))",
        progress: transfer.bytesDone > 0 ? transfer.progress : nil)
    }
    activity.receivingDone = status.receivingDone
    activity.receivingTotal = status.receivingTotal
    activity.receivingBytes = Bytes.text(status.receivingBytes)
    activity.sending = Dictionary(status.sending.map { ($0.name, $0.progress) }, uniquingKeysWith: max)
    let here = String(localized: "This \(ThisDevice.word)")
    activity.changedHere = status.changedHere.map { file in
      let what = switch file.change {
      case .added: String(localized: "added here")
      case .modified: String(localized: "edited here")
      case .deleted: String(localized: "deleted here")
      }
      let when = file.modified.map { " · " + RelativeTime.dayTime($0) } ?? ""
      return .init(name: file.name, detail: folderOf(file.path) + what + when, path: file.path)
    }
    activity.conflicts = status.conflicts.map { conflict in
      let theirs = conflict.remote.device.map(sender) ?? String(localized: "another device")
      return .init(
        name: conflict.name,
        meta: [String(localized: "changed here and on \(theirs)"), String(localized: "your edit is kept until you choose")],
        mine: sideText(conflict.mine), mineRef: [here, conflict.mine.modified.map(RelativeTime.dayTime)].compactMap { $0 }.joined(separator: " · "),
        theirs: sideText(conflict.remote), theirsRef: [theirs, conflict.remote.modified.map(RelativeTime.dayTime)].compactMap { $0 }.joined(separator: " · "),
        path: conflict.path)
    }
    let today = status.receivedRecently.filter { Calendar.current.isDateInToday($0.date) }
    activity.receivedToday = today.prefix(20).map { item in
      .init(
        name: item.name,
        detail: [parent(item.path), item.deleted ? String(localized: "deleted") : Bytes.text(item.size), sender(item.device)]
          .filter { !$0.isEmpty }.joined(separator: " · "),
        time: item.date.formatted(date: .omitted, time: .shortened))
    }
    if !today.isEmpty {
      let devices = ListFormatter.localizedString(byJoining: Array(Set(today.map { sender($0.device) })).sorted())
      activity.receivedSummary = String(localized: "\(today.count) files · from \(devices)")
    }
    let facts = status.remote
    let minutes = max(1, UserDefaults.standard.object(forKey: "remoteCheckMinutes") as? Int ?? 5)
    activity.remoteFacts = [
      (String(localized: "Here"), hereLine(folder, status)),
      (String(localized: "Chunks"), facts.chunkCount == 0 ? "—" : "\(facts.chunkCount.formatted()) · \(Bytes.text(facts.chunkBytes))"),
      (String(localized: "Change logs"), facts.changeLogs == 1 ? String(localized: "1 device") : String(localized: "\(facts.changeLogs) devices")),
      (String(localized: "Snapshot"), facts.lastSnapshot.map(RelativeTime.dayTime) ?? String(localized: "none yet")),
      (String(localized: "Checks"), String(localized: "on open, every \(minutes) min while open")),
      (String(localized: "The remote holds"), String(localized: "Ciphertext only")),
    ]
    activity.checked = facts.lastCheck.map { RelativeTime.short($0) } ?? String(localized: "not yet")
    return activity
  }

  private func hereLine(_ folder: VaultFolder, _ status: FolderSyncStatus) -> String {
    let mode = status.mode == .readOnly ? String(localized: "Read-only") : String(localized: "Read-write")
    if status.role == .readOnly { return String(localized: "\(mode) · the owner lets you read") }
    return "\(mode) · \(folder.storage(for: vault.deviceID) == .encrypted ? String(localized: "Encrypted") : String(localized: "Plain"))"
  }

  /// "mods · " for a file in a subfolder, "" at the top.
  private func folderOf(_ path: String) -> String {
    let parent = parent(path)
    return parent.isEmpty ? "" : parent + " · "
  }

  private func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }

  private func sideText(_ side: FolderSyncStatus.Conflict.Side) -> String {
    if let text = side.text { return text }
    guard let size = side.size else { return String(localized: "Deleted") }
    return Bytes.text(size)
  }
}

/// Why a folder can't sync yet, said plainly.
struct SyncSetupError: LocalizedError {
  var message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
