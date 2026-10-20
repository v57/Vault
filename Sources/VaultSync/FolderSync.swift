import CryptoKit
import Foundation
import VaultFiles
import VaultKit

/// Keeps one folder on this device in sync with its copy on a remote that is only plain storage (S3, SFTP, SMB, a
/// local disk): no server, transactions, locks or change notifications.
///
/// The remote copy is always encrypted (`RemoteLayout`): a signed member list, content-addressed chunks written
/// once, one change log per device that only that device appends to, and snapshots. Two devices never write the
/// same object, so nothing needs a lock, and eventually consistent listings only delay changes.
///
/// A sync (`sync()`, called by the app when it opens the folder and on a timer; there is no background process):
/// 1. reads the member list (checking the owner's signature and that it isn't older than one seen before) and the
///    folder keys this person holds;
/// 2. reads the newest snapshot and every device's new log files. Changes not signed by a member with write
///    access are ignored;
/// 3. scans the local folder against the last index. A read-write device sends what changed (chunks first, then
///    one log file); a read-only device keeps it as "changed here" and never sends it;
/// 4. applies what other devices changed. Each path's changes form a graph (`FileChange.parents`); when several
///    heads differ (edits made at once), every device resolves them the same way: an edit beats a delete, text
///    merges line by line against the common ancestor (`TextMerge`) when that merges cleanly, and otherwise the
///    later write wins and each loser becomes a conflict copy next to it. A read-write device then writes that
///    resolution as a change, so the graph has one head again;
/// 5. a read-write device makes a snapshot now and then, deletes its own log files once a snapshot older than the
///    grace period covers them, and deletes chunks nothing references after the grace period.
///
/// On a read-only device, a file edited locally that the remote also changed keeps the local edit and shows as a
/// conflict (`keepMine`, `revertToRemote`).
public actor FolderSync {
  public struct Configuration: Sendable {
    /// The `VaultFolder` id, which the member list, changes and snapshots are bound to.
    public var folderID: String
    public var remote: any RemoteFileSystem
    /// The folder's path on the remote (`VaultFolder.remotePath`).
    public var remotePath: String
    /// This device's copy: `PlainSyncFolder` or `EncryptedSyncFolder`.
    public var local: any SyncLocalFolder
    /// This device's id (`VaultDevice`), the name of its log on the remote.
    public var device: String
    /// The user's identity (`VaultPersonalIdentity.current()`): opens the folder key and signs changes.
    public var identity: PersonalIdentity
    /// The owner's Ed25519 key, which must have signed the member list (`VaultFolder.ownerSigningKey`, or the
    /// user's own for a folder of their own).
    public var ownerSigningKey: Data
    public var mode: VaultFolder.Mode
    /// Where this device keeps its sync state for the folder, sealed (outside the synced folder; the app's
    /// Application Support). nil keeps it in memory only.
    public var stateURL: URL?
    /// Plaintext bytes per chunk.
    public var chunkSize = 1 << 20
    /// A read-write device makes a snapshot once this many changes aren't covered by the newest one.
    public var snapshotAfter = 500
    /// How long a chunk stays unreferenced, and a snapshot exists, before what they make obsolete is deleted.
    public var gracePeriod: TimeInterval = 24 * 3600
    /// How often the chunk listing (count and size on the remote) is refreshed.
    public var factsInterval: TimeInterval = 3600
    /// How many received files the status keeps.
    public var recentLimit = 50
    public var now: @Sendable () -> Date = { Date() }

    public init(
      folderID: String, remote: any RemoteFileSystem, remotePath: String, local: any SyncLocalFolder, device: String,
      identity: PersonalIdentity, ownerSigningKey: Data, mode: VaultFolder.Mode = .readWrite, stateURL: URL? = nil
    ) {
      self.folderID = folderID
      self.remote = remote
      self.remotePath = remotePath
      self.local = local
      self.device = device
      self.identity = identity
      self.ownerSigningKey = ownerSigningKey
      self.mode = mode
      self.stateURL = stateURL
    }
  }

  public nonisolated let configuration: Configuration
  /// What the sync is doing, for the UI. `observe` delivers every change.
  public private(set) var status = FolderSyncStatus()

  private let layout: RemoteLayout
  private var mode: VaultFolder.Mode
  private var state = SyncState()
  private var stateLoaded = false
  private var members: FolderMembers?
  private var keys: SyncKeys?
  private var observer: (@Sendable (FolderSyncStatus) -> Void)?
  /// Contents read for merging and conflicts in this run, by hash.
  private var textCache: [String: Data] = [:]
  /// Chunks known to be on the remote and fresh, so they aren't checked again.
  private var knownChunks: Set<String> = []
  private var ownSequences: [Int] = []
  private var hadGap = false
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(_ configuration: Configuration) throws {
    let device = configuration.device
    guard !device.isEmpty, !device.contains("/"), !device.hasPrefix("."), device.utf8.count <= 200 else {
      throw FolderSyncError.invalidDevice(device)
    }
    self.configuration = configuration
    layout = RemoteLayout(root: try RemotePath.normalize(configuration.remotePath))
    mode = configuration.mode
  }

  /// Makes the remote folder: its member list, with the owner as the only member and `key` as the first key.
  /// Throws `folderExists` when a member list is already there.
  @discardableResult
  public static func createRemoteFolder(
    remote: any RemoteFileSystem, remotePath: String, folderID: String, owner: PersonalIdentity, ownerName: String,
    key: FolderKey = FolderKey()
  ) async throws -> FolderMembers {
    let path = try RemotePath.normalize(remotePath)
    guard try await remote.stat(RemotePath.join(path, FolderMembers.fileName)) == nil else {
      throw FolderSyncError.folderExists
    }
    let members = try FolderMembers.create(folderID: folderID, owner: owner, ownerName: ownerName, key: key)
    try await members.write(to: remote, folderPath: path)
    return members
  }

  /// Calls `handler` with the status whenever it changes (from the actor; hop to the main actor to show it).
  public func observe(_ handler: @escaping @Sendable (FolderSyncStatus) -> Void) {
    observer = handler
    handler(status)
  }

  /// Changes this device's mode (`VaultFolder.mode(for:)`); it applies from the next sync.
  public func setMode(_ mode: VaultFolder.Mode) {
    self.mode = mode
    status.mode = effectiveMode
    publish()
  }

  /// The member list as last read.
  public var memberList: FolderMembers? { members }

  // MARK: Sync

  /// Receives what other devices changed and, on a read-write device, sends what changed here.
  public func sync() async throws {
    await lock()
    defer { unlock() }
    do {
      try await run()
    } catch {
      status.phase = .idle
      status.lastError = error.localizedDescription
      publish()
      throw error
    }
  }

  private func run() async throws {
    textCache = [:]
    var errors: [String] = []
    setPhase(.checking)
    try await loadMembers()
    try await pull(errors: &errors)
    let local = try scanLocal()
    var dirty = try findDirty(local)
    if effectiveMode == .readWrite, !dirty.isEmpty {
      let sent = try await push(dirty, errors: &errors)
      dirty = dirty.filter { !sent.contains($0.path) }
    }
    let dirtyPaths = Set(dirty.map(\.path))
    try await applyRemote(local: local, dirty: dirtyPaths, errors: &errors)
    if effectiveMode == .readWrite {
      try await collapse(errors: &errors)
      setPhase(.cleaning)
      try await compact()
    }
    try await refreshFacts()
    state.facts.lastCheck = configuration.now()
    try await rebuildStatus(dirty: dirty)
    status.lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    try saveState()
    setPhase(.idle)
  }

  private var effectiveMode: VaultFolder.Mode {
    guard let members, members.role(of: configuration.identity.publicIdentity.signingKey) == .readWrite else {
      return .readOnly
    }
    return mode
  }

  // MARK: Members and keys

  private func loadMembers() async throws {
    let members = try await FolderMembers.read(
      from: configuration.remote, folderPath: layout.root, folderID: configuration.folderID,
      ownerSigningKey: configuration.ownerSigningKey, minimumVersion: stateLoaded ? state.membersVersion : 0)
    let keyring = try members.keyring(for: configuration.identity)
    if !stateLoaded {
      state = loadState(keyring) ?? SyncState()
      stateLoaded = true
      guard members.version >= state.membersVersion else {
        throw FolderSyncError.olderMemberList(found: members.version, known: state.membersVersion)
      }
    }
    state.membersVersion = members.version
    self.members = members
    keys = SyncKeys(keyring)
    status.role = members.role(of: configuration.identity.publicIdentity.signingKey)
    status.mode = effectiveMode
  }

  /// The last sequence number of each device's log that `signingKey` wrote to, as far as this device read: what
  /// to pass as `writesUntil` when removing a writer or making them read-only, so what they wrote until now counts.
  public func writesUntil(signingKey: Data) -> [String: Int] {
    var result: [String: Int] = [:]
    for (device, authors) in state.deviceAuthors where authors.contains(signingKey) {
      result[device] = state.read[device] ?? 0
    }
    return result
  }

  /// Adds someone to the folder (the owner only), or changes their role.
  public func addMember(_ identity: PublicIdentity, name: String, role: VaultPerson.Role) async throws {
    try await changeMembers { list, owner in try list.add(identity, name: name, role: role, owner: owner) }
  }

  /// Changes a member's role (the owner only); what a writer wrote until now keeps counting.
  public func setRole(_ role: VaultPerson.Role, for signingKey: Data) async throws {
    let until = writesUntil(signingKey: signingKey)
    try await changeMembers { list, owner in
      try list.setRole(role, for: signingKey, owner: owner, writesUntil: until)
    }
  }

  /// Removes a member and rotates the folder key (the owner only). What they wrote until now keeps counting; what
  /// they already downloaded stays theirs.
  public func removeMember(_ signingKey: Data) async throws {
    let until = writesUntil(signingKey: signingKey)
    try await changeMembers { list, owner in
      try list.remove(signingKey: signingKey, owner: owner, writesUntil: until)
    }
  }

  private func changeMembers(_ change: (inout FolderMembers, PersonalIdentity) throws -> Void) async throws {
    await lock()
    defer { unlock() }
    var list = try await FolderMembers.read(
      from: configuration.remote, folderPath: layout.root, folderID: configuration.folderID,
      ownerSigningKey: configuration.ownerSigningKey, minimumVersion: stateLoaded ? state.membersVersion : 0)
    try change(&list, configuration.identity)
    try await list.write(to: configuration.remote, folderPath: layout.root)
    try await loadMembers()
    try saveState()
    publish()
  }

  // MARK: Reading the remote

  private func pull(errors: inout [String]) async throws {
    guard let keys else { return }
    let snapshots = try await listIfPresent(layout.snapshots).filter { !$0.isDirectory }.map(\.name)
    if let latest = snapshots.max(), latest != state.snapshot {
      do {
        try await readSnapshot(latest, keys: keys)
      } catch {
        errors.append("Snapshot \(latest): \(error.localizedDescription)")
      }
    }
    let devices = try await listIfPresent(layout.logs).filter(\.isDirectory).map(\.name)
    var logFiles = 0
    hadGap = false
    for device in devices {
      let sequences = try await listIfPresent(layout.log(device)).compactMap { $0.isDirectory ? nil : Int($0.name) }
        .sorted()
      logFiles += sequences.count
      if device == configuration.device {
        ownSequences = sequences
        state.nextSequence = max(state.nextSequence, (sequences.last ?? 0) + 1)
      }
      var position = state.read[device] ?? 0
      for sequence in sequences where sequence > position {
        guard sequence == position + 1 else {
          hadGap = true
          break
        }
        setPhase(.checking)
        do {
          try await readSegment(device: device, sequence: sequence, keys: keys)
        } catch FolderSyncError.missingKey {
          // Written with a key epoch this device hasn't read about yet: try again next time.
          hadGap = true
          break
        } catch RemoteFileError.notFound {
          // Deleted since the listing (its device compacted it): the next snapshot covers it.
          hadGap = true
          break
        } catch {
          errors.append("Log \(device)/\(sequence): \(error.localizedDescription)")
        }
        position = sequence
        state.read[device] = position
      }
    }
    if state.nextSequence <= state.read[configuration.device] ?? 0 {
      state.nextSequence = (state.read[configuration.device] ?? 0) + 1
    }
    state.facts.changeLogs = devices.count
    state.facts.logFiles = logFiles
  }

  private func readSegment(device: String, sequence: Int, keys: SyncKeys) async throws {
    let data = try await configuration.remote.read(layout.segment(device, sequence))
    let (plain, _) = try keys.open(data, context: segmentContext(device, sequence))
    guard let segment = try? SyncCoding.decoder.decode(LogSegment.self, from: plain) else {
      throw FolderSyncError.damaged("log \(device)/\(sequence)")
    }
    for signed in segment.changes { accept(signed, device: device, sequence: sequence, countIgnored: true) }
  }

  /// Takes a signed change into the known changes when it checks out: signed by its author, for this folder,
  /// from the device whose log holds it, with a usable path, by someone allowed to write.
  @discardableResult
  private func accept(_ signed: SignedChange, device: String, sequence: Int, countIgnored: Bool) -> Bool {
    guard let members, let change = signed.verified(folderID: configuration.folderID), change.clock.device == device,
      SyncNames.validated(change.path) != nil
    else { return false }
    guard members.canWrite(signingKey: signed.author, device: device, sequence: sequence) else {
      if countIgnored { state.ignored += 1 }
      return false
    }
    state.deviceAuthors[device, default: []].insert(signed.author)
    if device == configuration.device, change.clock > state.clock { state.clock = change.clock }
    state.changes[change.path, default: [:]][change.clock.description] = KnownChange(
      change: change, signed: signed, device: device, sequence: sequence)
    return true
  }

  private func readSnapshot(_ name: String, keys: SyncKeys) async throws {
    guard let members else { return }
    let data = try await configuration.remote.read(layout.snapshot(name))
    let (plain, _) = try keys.open(data, context: snapshotContext(name))
    guard let signed = try? SyncCoding.decoder.decode(SignedSnapshot.self, from: plain) else {
      throw FolderSyncError.damaged("snapshot \(name)")
    }
    guard members.role(of: signed.author) == .readWrite,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signed.author),
      key.isValidSignature(signed.signature, for: SignedSnapshot.prefix + signed.body),
      let body = try? SyncCoding.decoder.decode(SnapshotBody.self, from: signed.body),
      body.folder == configuration.folderID
    else { throw FolderSyncError.damaged("snapshot \(name)") }
    var kept = Set<HybridClock>()
    for entry in body.changes where accept(entry.signed, device: entry.device, sequence: entry.sequence, countIgnored: false) {
      if let change = entry.signed.verified(folderID: configuration.folderID) { kept.insert(change.clock) }
    }
    // What the snapshot covers but doesn't hold was superseded: forget it, as a device starting from the
    // snapshot never knew it.
    for (path, changes) in state.changes {
      let remaining = changes.filter { _, known in
        kept.contains(known.clock) || known.sequence > body.covered[known.device] ?? 0
      }
      state.changes[path] = remaining.isEmpty ? nil : remaining
    }
    for (device, sequence) in body.covered { state.read[device] = max(state.read[device] ?? 0, sequence) }
    state.snapshot = name
    state.snapshotCovered = body.covered
    state.snapshotDate = body.created
    state.facts.lastSnapshot = body.created
  }

  private func listIfPresent(_ path: String) async throws -> [RemoteFileInfo] {
    do {
      return try await configuration.remote.list(path)
    } catch RemoteFileError.notFound {
      return []
    }
  }

  // MARK: The local folder

  private func scanLocal() throws -> [String: LocalFile] {
    var files: [String: LocalFile] = [:]
    for file in try configuration.local.scan() where SyncNames.validated(file.path) != nil { files[file.path] = file }
    return files
  }

  struct LocalChange: Sendable {
    var path: String
    var change: FolderSyncStatus.ChangedFile.Change
    var file: LocalFile?
  }

  /// What changed locally since the last sync. A new local file with the same contents the remote has is taken
  /// as synced (a device joining with a copy it already had).
  private func findDirty(_ local: [String: LocalFile]) throws -> [LocalChange] {
    var result: [LocalChange] = []
    for (path, file) in local {
      if let entry = state.index[path], entry.exists {
        if entry.matches(file) { continue }
        let hash = try hashLocal(path)
        if hash == entry.hash {
          state.index[path]?.size = file.size
          state.index[path]?.modified = file.modified.timeIntervalSince1970
          continue
        }
        result.append(LocalChange(path: path, change: .modified, file: file))
      } else {
        let heads = state.heads(path)
        let live = heads.filter { !$0.change.deleted }
        if !live.isEmpty, live.count == heads.count, Set(live.map(\.change.hash)).count == 1,
          try hashLocal(path) == live[0].change.hash
        {
          state.index[path] = SyncState.IndexEntry(
            exists: true, hash: live[0].change.hash, size: file.size, modified: file.modified.timeIntervalSince1970,
            heads: heads.map(\.clock).sorted())
          continue
        }
        result.append(LocalChange(path: path, change: .added, file: file))
      }
    }
    for (path, entry) in state.index where entry.exists && local[path] == nil {
      result.append(LocalChange(path: path, change: .deleted, file: nil))
    }
    return result.sorted { $0.path < $1.path }
  }

  private func hashLocal(_ path: String) throws -> String {
    let reader = try configuration.local.reader(path)
    var hash = SHA256()
    var offset: Int64 = 0
    let step = Int64(configuration.chunkSize)
    while offset < reader.size {
      let piece = try reader.read(range: offset..<min(offset + step, reader.size))
      if piece.isEmpty { break }
      hash.update(data: piece)
      offset += Int64(piece.count)
    }
    return hex(Data(hash.finalize()))
  }

  // MARK: Sending

  /// Sends local changes: their chunks, then one log file. Returns the paths sent.
  private func push(_ dirty: [LocalChange], errors: inout [String]) async throws -> Set<String> {
    guard let keys else { return [] }
    setPhase(.sending)
    status.sendingTotal = dirty.count
    status.sendingDone = 0
    knownChunks.formUnion(headChunks())
    var ready: [(KnownChange, SyncState.IndexEntry)] = []
    let sequence = state.nextSequence
    for item in dirty {
      let parents = state.index[item.path]?.heads ?? []
      var change: FileChange
      var entry: SyncState.IndexEntry
      if let file = item.file {
        do {
          let content = try await upload(item.path, keys: keys)
          change = FileChange(
            folder: configuration.folderID, path: item.path, clock: nextClock(file.modified), parents: parents,
            deleted: false, size: content.size, hash: content.hash, chunks: content.chunks)
          entry = SyncState.IndexEntry(
            exists: true, hash: content.hash, size: file.size, modified: file.modified.timeIntervalSince1970,
            heads: [change.clock])
        } catch let error as RemoteFileError {
          throw error
        } catch {
          errors.append("\(item.path): \(error.localizedDescription)")
          continue
        }
      } else {
        change = FileChange(
          folder: configuration.folderID, path: item.path, clock: nextClock(configuration.now()), parents: parents,
          deleted: true, size: 0, hash: "", chunks: [])
        entry = .absent([change.clock])
      }
      let signed = try SignedChange.sign(change, by: configuration.identity)
      ready.append((KnownChange(change: change, signed: signed, device: configuration.device, sequence: sequence), entry))
      status.sendingDone += 1
      publish()
    }
    guard !ready.isEmpty else { return [] }
    try await writeSegment(ready.map(\.0), sequence: sequence, keys: keys)
    for (known, entry) in ready { state.index[known.change.path] = entry }
    return Set(ready.map(\.0.change.path))
  }

  private func writeSegment(_ changes: [KnownChange], sequence: Int, keys: SyncKeys) async throws {
    let segment = LogSegment(changes: changes.map(\.signed))
    let sealed = try keys.seal(
      SyncCoding.encoder.encode(segment), context: segmentContext(configuration.device, sequence))
    try await configuration.remote.write(sealed, to: layout.segment(configuration.device, sequence))
    state.nextSequence = sequence + 1
    ownSequences.append(sequence)
    if state.read[configuration.device] ?? 0 == sequence - 1 { state.read[configuration.device] = sequence }
    state.deviceAuthors[configuration.device, default: []].insert(configuration.identity.publicIdentity.signingKey)
    for known in changes {
      state.changes[known.change.path, default: [:]][known.clock.description] = known
    }
  }

  private func nextClock(_ date: Date) -> HybridClock {
    state.clock = state.clock.next(now: date, device: configuration.device)
    return state.clock
  }

  private func headChunks() -> Set<String> {
    var chunks = Set<String>()
    for path in state.changes.keys {
      for head in state.heads(path) { chunks.formUnion(head.change.chunks) }
    }
    return chunks
  }

  private struct Content {
    var chunks: [String]
    var hash: String
    var size: Int64
  }

  /// Reads a local file chunk by chunk and puts the chunks the remote doesn't have.
  private func upload(_ path: String, keys: SyncKeys) async throws -> Content {
    let reader = try configuration.local.reader(path)
    var transfer = FolderSyncStatus.Transfer(path: path, bytesDone: 0, bytesTotal: reader.size)
    status.sending.append(transfer)
    defer { status.sending.removeAll { $0.path == path } }
    var hash = SHA256()
    var chunks: [String] = []
    var offset: Int64 = 0
    let step = Int64(configuration.chunkSize)
    while offset < reader.size {
      let piece = try reader.read(range: offset..<min(offset + step, reader.size))
      if piece.isEmpty { break }
      hash.update(data: piece)
      chunks.append(try await putChunk(piece, keys: keys))
      offset += Int64(piece.count)
      transfer.bytesDone = offset
      if let index = status.sending.firstIndex(where: { $0.path == path }) { status.sending[index] = transfer }
      publish()
    }
    return Content(chunks: chunks, hash: hex(Data(hash.finalize())), size: offset)
  }

  private func upload(text: String, keys: SyncKeys) async throws -> Content {
    let data = Data(text.utf8)
    var chunks: [String] = []
    var offset = 0
    while offset < data.count {
      let piece = data[offset..<min(offset + configuration.chunkSize, data.count)]
      chunks.append(try await putChunk(Data(piece), keys: keys))
      offset += piece.count
    }
    return Content(chunks: chunks, hash: hex(Data(SHA256.hash(data: data))), size: Int64(data.count))
  }

  /// Puts a chunk unless the remote has it: a head references it, or it is there and recent. An old unreferenced
  /// copy is written again, so cleanup on another device, which waits for chunks to be old, doesn't delete it.
  private func putChunk(_ piece: Data, keys: SyncKeys) async throws -> String {
    let id = keys.current.chunkID(piece)
    if knownChunks.contains(id) { return id }
    let path = layout.chunk(id)
    if let info = try await configuration.remote.stat(path),
      configuration.now().timeIntervalSince(info.modified ?? .distantFuture) < configuration.gracePeriod / 2
    {
      knownChunks.insert(id)
      return id
    }
    let sealed = try keys.seal(piece, context: chunkContext(id))
    try await configuration.remote.write(sealed, to: path)
    knownChunks.insert(id)
    state.unreferencedSince[id] = nil
    state.facts.chunkCount += 1
    state.facts.chunkBytes += Int64(sealed.count)
    return id
  }

  // MARK: Receiving

  /// A path's state on the remote, resolved the same way on every device.
  struct Resolution {
    enum Content {
      case absent
      case deleted
      case change(KnownChange)
      /// Concurrent text edits merged cleanly; `winner` is the latest of them.
      case text(String, winner: KnownChange)
    }

    var content: Content
    var heads: [HybridClock]
    var conflictCopies: [(path: String, change: KnownChange)] = []
    /// The heads differ: a read-write device writes the resolution as a new change.
    var contested = false

    var hash: String? {
      switch content {
      case .absent, .deleted: nil
      case .change(let known): known.change.hash
      case .text(let text, _): hex(Data(SHA256.hash(data: Data(text.utf8))))
      }
    }
  }

  func resolve(_ path: String) async throws -> Resolution {
    let heads = state.heads(path)
    let clocks = heads.map(\.clock).sorted()
    guard !heads.isEmpty else { return Resolution(content: .absent, heads: []) }
    let live = heads.filter { !$0.change.deleted }
    guard !live.isEmpty else { return Resolution(content: .deleted, heads: clocks) }
    // One head per distinct content, newest first.
    var distinct: [KnownChange] = []
    var seen = Set<String>()
    for head in live where seen.insert(head.change.hash).inserted { distinct.append(head) }
    let contested = distinct.count > 1 || live.count < heads.count
    guard distinct.count > 1 else {
      return Resolution(content: .change(distinct[0]), heads: clocks, contested: contested)
    }
    let winner = distinct[0]
    var merged: String?
    var copies: [(String, KnownChange)] = []
    for loser in distinct.dropFirst() {
      if let text = try await mergeText(path, winner: winner, current: merged, loser: loser) {
        merged = text
      } else {
        copies.append((Self.conflictCopyPath(path, loser: loser.change), loser))
      }
    }
    return Resolution(
      content: merged.map { .text($0, winner: winner) } ?? .change(winner), heads: clocks, conflictCopies: copies,
      contested: true)
  }

  /// Three-way merges a loser's text into the winner's (or what earlier merges made of it), against their newest
  /// common ancestor. nil when it can't: no common ancestor with contents, not text, or overlapping edits.
  private func mergeText(_ path: String, winner: KnownChange, current: String?, loser: KnownChange) async throws
    -> String?
  {
    guard let base = commonAncestor(path, winner, loser), !base.change.deleted,
      [base, winner, loser].allSatisfy({ $0.change.size <= Self.textLimit })
    else { return nil }
    guard let baseText = try await text(of: base), let theirs = try await text(of: loser) else { return nil }
    let ours: String
    if let current {
      ours = current
    } else if let text = try await text(of: winner) {
      ours = text
    } else {
      return nil
    }
    let result = TextMerge.merge(base: baseText, ours: ours, theirs: theirs)
    return result.hasConflicts ? nil : result.text
  }

  private func commonAncestor(_ path: String, _ a: KnownChange, _ b: KnownChange) -> KnownChange? {
    let changes = state.changes[path] ?? [:]
    func ancestors(_ start: KnownChange) -> [HybridClock: KnownChange] {
      var found: [HybridClock: KnownChange] = [:]
      var queue = start.change.parents
      while let clock = queue.popLast() {
        guard found[clock] == nil, let known = changes[clock.description] else { continue }
        found[clock] = known
        queue += known.change.parents
      }
      return found
    }
    let first = ancestors(a)
    return ancestors(b).filter { first[$0.key] != nil }.max { $0.key < $1.key }?.value
  }

  static let textLimit: Int64 = 1 << 20

  /// The contents of a change as text, or nil when they aren't text (or are larger than the limit).
  private func text(of known: KnownChange) async throws -> String? {
    guard !known.change.deleted, known.change.size <= Self.textLimit else { return nil }
    let data: Data
    if let cached = textCache[known.change.hash] {
      data = cached
    } else {
      var collected = Data()
      for id in known.change.chunks { collected.append(try await fetchChunk(id)) }
      guard hex(Data(SHA256.hash(data: collected))) == known.change.hash else {
        throw FolderSyncError.damaged("contents of \(known.change.path)")
      }
      textCache[known.change.hash] = collected
      data = collected
    }
    return Self.text(data)
  }

  static func text(_ data: Data) -> String? {
    guard Int64(data.count) <= textLimit, !data.contains(0) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// `Notes (conflict from mac-2 2026-10-20 143005).txt`: the losing device and the time of its write.
  static func conflictCopyPath(_ path: String, loser: FileChange) -> String {
    var parts = path.split(separator: "/").map(String.init)
    let name = parts.removeLast()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HHmmss"
    let date = formatter.string(from: Date(timeIntervalSince1970: Double(loser.clock.millis) / 1000))
    let suffix = " (conflict from \(loser.clock.device) \(date))"
    var stem = name
    var ext = ""
    if let dot = name.lastIndex(of: "."), dot != name.startIndex {
      stem = String(name[..<dot])
      ext = String(name[dot...])
    }
    return (parts + [stem + suffix + ext]).joined(separator: "/")
  }

  private func fetchChunk(_ id: String) async throws -> Data {
    guard let keys else { throw FolderSyncError.notAMember }
    let sealed = try await configuration.remote.read(layout.chunk(id))
    let (plain, epoch) = try keys.open(sealed, context: chunkContext(id))
    guard epoch.chunkID(plain) == id else { throw FolderSyncError.damaged("chunk \(id)") }
    return plain
  }

  private func applyRemote(local: [String: LocalFile], dirty: Set<String>, errors: inout [String]) async throws {
    let paths = Set(state.changes.keys).union(state.index.keys).sorted()
    var pending: [(String, Resolution)] = []
    for path in paths where !dirty.contains(path) {
      do {
        let resolution = try await resolve(path)
        if resolution.heads != state.index[path]?.heads ?? [] { pending.append((path, resolution)) }
      } catch {
        errors.append("\(path): \(error.localizedDescription)")
      }
    }
    guard !pending.isEmpty else { return }
    setPhase(.receiving)
    status.receivingTotal = pending.count
    status.receivingDone = 0
    status.receivingBytes = 0
    for (path, resolution) in pending {
      do {
        try await apply(resolution, to: path, localFile: local[path], record: true)
      } catch {
        errors.append("\(path): \(error.localizedDescription)")
      }
      status.receivingDone += 1
      publish()
    }
  }

  /// Makes the local file what the resolution says, unless it already is, and notes it in the index.
  private func apply(_ resolution: Resolution, to path: String, localFile: LocalFile?, record: Bool) async throws {
    let entry = state.index[path]
    let unchanged = entry.map { $0.matches(localFile) } ?? (localFile == nil)
    switch resolution.content {
    case .absent, .deleted:
      if localFile != nil {
        try configuration.local.remove(path)
        if record, let head = state.heads(path).first {
          note(path: path, size: 0, device: head.clock.device, deleted: true)
        }
      }
      state.index[path] = resolution.heads.isEmpty ? nil : .absent(resolution.heads)
      state.conflictCopies.remove(path)
    case .change(let known):
      if unchanged, entry?.exists == true, entry?.hash == known.change.hash {
        state.index[path]?.heads = resolution.heads
      } else {
        let file = try await download(known, to: path)
        state.index[path] = SyncState.IndexEntry(
          exists: true, hash: known.change.hash, size: file.size, modified: file.modified.timeIntervalSince1970,
          heads: resolution.heads)
        if record { note(path: path, size: known.change.size, device: known.clock.device, deleted: false) }
      }
      if known.change.conflictOf != nil { state.conflictCopies.insert(path) }
    case .text(let text, let winner):
      let data = Data(text.utf8)
      let hash = hex(Data(SHA256.hash(data: data)))
      if unchanged, entry?.exists == true, entry?.hash == hash {
        state.index[path]?.heads = resolution.heads
      } else {
        let writer = try configuration.local.beginWrite(path)
        let file: LocalFile
        do {
          try writer.append(data)
          file = try writer.commit()
        } catch {
          writer.cancel()
          throw error
        }
        state.index[path] = SyncState.IndexEntry(
          exists: true, hash: hash, size: file.size, modified: file.modified.timeIntervalSince1970,
          heads: resolution.heads)
        if record { note(path: path, size: Int64(data.count), device: winner.clock.device, deleted: false) }
      }
    }
    state.acknowledged[path] = nil
    for copy in resolution.conflictCopies {
      guard state.changes[copy.path] == nil, state.index[copy.path] == nil,
        try configuration.local.stat(copy.path) == nil
      else { continue }
      let file = try await download(copy.change, to: copy.path)
      state.index[copy.path] = SyncState.IndexEntry(
        exists: true, hash: copy.change.change.hash, size: file.size, modified: file.modified.timeIntervalSince1970,
        heads: [])
      state.conflictCopies.insert(copy.path)
    }
  }

  /// Downloads a change's chunks into the local file at `path`, checking each chunk's id and the whole hash.
  private func download(_ known: KnownChange, to path: String) async throws -> LocalFile {
    var transfer = FolderSyncStatus.Transfer(path: path, bytesDone: 0, bytesTotal: known.change.size)
    status.receiving.append(transfer)
    publish()
    defer { status.receiving.removeAll { $0.path == path } }
    let writer = try configuration.local.beginWrite(path)
    do {
      var hash = SHA256()
      var total: Int64 = 0
      for id in known.change.chunks {
        let data = try await fetchChunk(id)
        hash.update(data: data)
        try writer.append(data)
        total += Int64(data.count)
        transfer.bytesDone = total
        if let index = status.receiving.firstIndex(where: { $0.path == path }) { status.receiving[index] = transfer }
        publish()
      }
      guard total == known.change.size, hex(Data(hash.finalize())) == known.change.hash else {
        throw FolderSyncError.damaged("contents of \(path)")
      }
      let file = try writer.commit()
      status.receivingBytes += total
      return file
    } catch {
      writer.cancel()
      throw error
    }
  }

  private func note(path: String, size: Int64, device: String, deleted: Bool) {
    state.received.insert(
      FolderSyncStatus.Received(path: path, size: size, date: configuration.now(), device: device, deleted: deleted),
      at: 0)
    if state.received.count > configuration.recentLimit { state.received.removeLast(state.received.count - configuration.recentLimit) }
  }

  // MARK: Resolving contested paths (read-write)

  /// Writes the resolution of every contested path this device applied as a change whose parents are all the
  /// heads, and each conflict copy as a new file, so the next reader sees one head. Devices doing this at once
  /// write the same contents, which then resolve without a conflict.
  private func collapse(errors: inout [String]) async throws {
    guard let keys else { return }
    var ready: [(KnownChange, SyncState.IndexEntry?)] = []
    let sequence = state.nextSequence
    for path in state.changes.keys.sorted() {
      let resolution: Resolution
      do {
        resolution = try await resolve(path)
      } catch {
        continue
      }
      guard resolution.contested, let entry = state.index[path], entry.heads == resolution.heads else { continue }
      let now = configuration.now()
      var content: Content
      switch resolution.content {
      case .absent, .deleted: continue
      case .change(let known):
        content = Content(chunks: known.change.chunks, hash: known.change.hash, size: known.change.size)
      case .text(let text, _):
        do {
          content = try await upload(text: text, keys: keys)
        } catch let error as RemoteFileError {
          throw error
        } catch {
          errors.append("\(path): \(error.localizedDescription)")
          continue
        }
      }
      let change = FileChange(
        folder: configuration.folderID, path: path, clock: nextClock(now), parents: resolution.heads,
        deleted: false, size: content.size, hash: content.hash, chunks: content.chunks)
      var updated = entry
      updated.heads = [change.clock]
      ready.append((try known(change, sequence: sequence), updated))
      for copy in resolution.conflictCopies where state.changes[copy.path] == nil {
        let copyChange = FileChange(
          folder: configuration.folderID, path: copy.path, clock: nextClock(now), parents: [], deleted: false,
          size: copy.change.change.size, hash: copy.change.change.hash, chunks: copy.change.change.chunks,
          conflictOf: path)
        var copyEntry = state.index[copy.path]
        if copyEntry?.hash == copyChange.hash { copyEntry?.heads = [copyChange.clock] } else { copyEntry = nil }
        ready.append((try known(copyChange, sequence: sequence), copyEntry))
      }
    }
    guard !ready.isEmpty else { return }
    try await writeSegment(ready.map(\.0), sequence: sequence, keys: keys)
    for (known, entry) in ready where entry != nil { state.index[known.change.path] = entry }
  }

  private func known(_ change: FileChange, sequence: Int) throws -> KnownChange {
    KnownChange(
      change: change, signed: try SignedChange.sign(change, by: configuration.identity), device: configuration.device,
      sequence: sequence)
  }

  // MARK: Snapshots and cleanup (read-write)

  private func compact() async throws {
    guard let keys else { return }
    let now = configuration.now()
    let uncovered = state.changes.values.reduce(0) { count, changes in
      count + changes.values.filter { $0.sequence > state.snapshotCovered[$0.device] ?? 0 }.count
    }
    if uncovered >= configuration.snapshotAfter { try await makeSnapshot(keys: keys, now: now) }

    // Once the newest snapshot is older than the grace period, every device has had time to see it: what it
    // covers of this device's log, and this device's older snapshots, can go.
    if let date = state.snapshotDate, now.timeIntervalSince(date) >= configuration.gracePeriod {
      let covered = state.snapshotCovered[configuration.device] ?? 0
      for sequence in ownSequences where sequence <= covered {
        try? await configuration.remote.delete(layout.segment(configuration.device, sequence))
      }
      ownSequences.removeAll { $0 <= covered }
      for info in try await listIfPresent(layout.snapshots) where !info.isDirectory {
        guard info.name != state.snapshot, HybridClock(info.name)?.device == configuration.device else { continue }
        try? await configuration.remote.delete(layout.snapshot(info.name))
      }
    }

    if !hadGap, state.lastCleanup.map({ now.timeIntervalSince($0) >= configuration.gracePeriod / 4 }) ?? true {
      try await collectGarbage(now: now)
    }
  }

  private func makeSnapshot(keys: SyncKeys, now: Date) async throws {
    var entries: [SnapshotBody.Entry] = []
    let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
    for path in state.changes.keys.sorted() {
      for head in state.heads(path) {
        // Old deletions needn't be carried: a path missing from the snapshot reads as deleted.
        if head.change.deleted, Double(nowMillis - head.clock.millis) / 1000 > configuration.gracePeriod { continue }
        entries.append(SnapshotBody.Entry(signed: head.signed, device: head.device, sequence: head.sequence))
      }
    }
    let body = SnapshotBody(folder: configuration.folderID, created: now, covered: state.read, changes: entries)
    let bodyData = try SyncCoding.encoder.encode(body)
    let signed = SignedSnapshot(
      body: bodyData, author: configuration.identity.publicIdentity.signingKey,
      signature: try configuration.identity.signature(for: SignedSnapshot.prefix + bodyData))
    let name = nextClock(now).description
    let sealed = try keys.seal(SyncCoding.encoder.encode(signed), context: snapshotContext(name))
    try await configuration.remote.write(sealed, to: layout.snapshot(name))
    // Forget what the snapshot covers but doesn't hold, as every other device will.
    let kept = Set(entries.compactMap { $0.signed.verified(folderID: configuration.folderID)?.clock })
    for (path, changes) in state.changes {
      let remaining = changes.filter { _, known in
        kept.contains(known.clock) || known.sequence > body.covered[known.device] ?? 0
      }
      state.changes[path] = remaining.isEmpty ? nil : remaining
    }
    state.snapshot = name
    state.snapshotCovered = body.covered
    state.snapshotDate = now
    state.facts.lastSnapshot = now
  }

  /// Deletes chunks no known change references once they have been unreferenced, and unchanged on the remote,
  /// for the grace period (so a chunk another device just put, or just reused, survives).
  private func collectGarbage(now: Date) async throws {
    let listing = try await listIfPresent(layout.chunks).filter { !$0.isDirectory }
    var referenced = Set<String>()
    for changes in state.changes.values {
      for known in changes.values { referenced.formUnion(known.change.chunks) }
    }
    var count = 0
    var bytes: Int64 = 0
    var stillUnreferenced: [String: Date] = [:]
    for info in listing {
      let id = info.name
      if referenced.contains(id) {
        count += 1
        bytes += info.size
        continue
      }
      let since = state.unreferencedSince[id] ?? now
      let old = info.modified.map { now.timeIntervalSince($0) >= configuration.gracePeriod } ?? true
      if now.timeIntervalSince(since) >= configuration.gracePeriod, old {
        do {
          try await configuration.remote.delete(layout.chunk(id))
          knownChunks.remove(id)
          continue
        } catch {}
      }
      stillUnreferenced[id] = since
      count += 1
      bytes += info.size
    }
    state.unreferencedSince = stillUnreferenced
    state.facts.chunkCount = count
    state.facts.chunkBytes = bytes
    state.lastCleanup = now
    state.lastFacts = now
  }

  private func refreshFacts() async throws {
    let now = configuration.now()
    guard state.lastFacts.map({ now.timeIntervalSince($0) >= configuration.factsInterval }) ?? true else { return }
    let listing = try await listIfPresent(layout.chunks).filter { !$0.isDirectory }
    state.facts.chunkCount = listing.count
    state.facts.chunkBytes = listing.reduce(0) { $0 + $1.size }
    state.lastFacts = now
  }

  // MARK: Read-only choices

  /// Keeps this device's edit of a conflicted file (read-only devices): the conflict goes away until the remote
  /// changes the file again. The edit stays "changed here" and is never sent.
  public func keepMine(_ path: String) async throws {
    await lock()
    defer { unlock() }
    try await ensureLoaded()
    state.acknowledged[path] = try await resolve(path).heads
    try await refreshStatus()
    try saveState()
  }

  /// Replaces this device's edit (or addition, or deletion) of `path` with the remote's version.
  public func revertToRemote(_ path: String) async throws {
    await lock()
    defer { unlock() }
    try await ensureLoaded()
    try await revert(path)
    try await refreshStatus()
    try saveState()
  }

  /// Reverts every local change ("changed here") to the remote's version.
  public func revertAll() async throws {
    await lock()
    defer { unlock() }
    try await ensureLoaded()
    let local = try scanLocal()
    for change in try findDirty(local) { try await revert(change.path) }
    try await refreshStatus()
    try saveState()
  }

  private func revert(_ path: String) async throws {
    let resolution = try await resolve(path)
    try await apply(resolution, to: path, localFile: try configuration.local.stat(path), record: false)
  }

  private func ensureLoaded() async throws {
    if keys == nil { try await loadMembers() }
  }

  private func refreshStatus() async throws {
    let local = try scanLocal()
    try await rebuildStatus(dirty: try findDirty(local))
    publish()
  }

  // MARK: Status

  private func rebuildStatus(dirty: [LocalChange]) async throws {
    status.mode = effectiveMode
    status.changedHere = dirty.map {
      FolderSyncStatus.ChangedFile(path: $0.path, change: $0.change, size: $0.file?.size ?? 0, modified: $0.file?.modified)
    }
    var conflicts: [FolderSyncStatus.Conflict] = []
    for change in dirty {
      let resolution = try await resolve(change.path)
      let synced = state.index[change.path]?.heads ?? []
      guard resolution.heads != synced, state.acknowledged[change.path] != resolution.heads else { continue }
      var mine = FolderSyncStatus.Conflict.Side(size: change.file?.size, modified: change.file?.modified)
      if let file = change.file, file.size <= Self.textLimit,
        let data = try? configuration.local.reader(change.path).read(range: 0..<file.size)
      {
        mine.text = Self.text(data)
      }
      var remote = FolderSyncStatus.Conflict.Side()
      switch resolution.content {
      case .absent, .deleted:
        remote.device = state.heads(change.path).first?.clock.device
      case .change(let known):
        remote.size = known.change.size
        remote.device = known.clock.device
        remote.modified = Date(timeIntervalSince1970: Double(known.clock.millis) / 1000)
        remote.text = try? await text(of: known)
      case .text(let text, let winner):
        remote.size = Int64(text.utf8.count)
        remote.device = winner.clock.device
        remote.modified = Date(timeIntervalSince1970: Double(winner.clock.millis) / 1000)
        remote.text = text
      }
      conflicts.append(FolderSyncStatus.Conflict(path: change.path, mine: mine, remote: remote))
    }
    status.conflicts = conflicts
    state.conflictCopies = state.conflictCopies.filter { ((try? configuration.local.stat($0)) ?? nil) != nil }
    status.conflictCopies = state.conflictCopies.sorted()
    status.receivedRecently = state.received
    status.remote = state.facts
    status.ignoredChanges = state.ignored
  }

  private func setPhase(_ phase: FolderSyncStatus.Phase) {
    guard status.phase != phase else { return }
    status.phase = phase
    publish()
  }

  private func publish() { observer?(status) }

  // MARK: State

  private var stateContext: Data {
    Data("dev.v57.sync.state|\(configuration.folderID)|\(configuration.device)".utf8)
  }

  /// The saved state, or nil when there is none or it doesn't open (then the folder syncs again from the start).
  private func loadState(_ keyring: FolderKeyring) -> SyncState? {
    guard let url = configuration.stateURL, let data = try? Data(contentsOf: url),
      let plain = try? EncryptedFile.open(data, key: SyncKeys.stateKey(keyring), context: stateContext)
    else { return nil }
    return try? SyncCoding.decoder.decode(SyncState.self, from: plain)
  }

  private func saveState() throws {
    guard let url = configuration.stateURL, let keys else { return }
    let plain = try SyncCoding.encoder.encode(state)
    let sealed = try EncryptedFile.seal(
      plain, key: SyncKeys.stateKey(keys.keyring), keyID: "state", context: stateContext)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try sealed.write(to: url, options: .atomic)
  }

  // MARK: Contexts

  private func chunkContext(_ id: String) -> Data {
    Data("dev.v57.sync.chunk|\(configuration.folderID)|\(id)".utf8)
  }

  private func segmentContext(_ device: String, _ sequence: Int) -> Data {
    Data("dev.v57.sync.log|\(configuration.folderID)|\(device)|\(sequence)".utf8)
  }

  private func snapshotContext(_ name: String) -> Data {
    Data("dev.v57.sync.snapshot|\(configuration.folderID)|\(name)".utf8)
  }

  // MARK: One operation at a time

  private func lock() async {
    if busy {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      busy = true
    }
  }

  private func unlock() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}
