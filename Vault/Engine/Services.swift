import ComponentKit
import Foundation
import VaultKit

// The parts of the design VaultKit doesn't do yet are drawn against these protocols. Each has a demo
// implementation (sample data, for screenshots and design checks) and a live one that says what isn't there yet.

// MARK: - Folder sync over plain storage

/// What syncing a folder through a remote is doing: files arriving, edits kept here on a read-only device,
/// conflicts, what came in today. The engine (logs and chunks on plain storage, see the idea doc) is a follow-up;
/// until then the live engine reports nothing.
@MainActor
protocol FolderSyncEngine: AnyObject {
  func activity(for folderID: String) -> FolderSyncActivity?
  func keepMine(_ path: String, in folderID: String)
  func revert(_ path: String, in folderID: String)
  func revertAll(in folderID: String)
}

struct FolderSyncActivity: Hashable {
  struct Transfer: Hashable, Identifiable {
    var name: String
    var detail: String
    /// 0…1 while it moves, nil while it waits.
    var progress: Double?
    var id: String { name }
  }

  struct ChangedFile: Hashable, Identifiable {
    var name: String
    var detail: String
    var id: String { name }
  }

  struct Conflict: Hashable, Identifiable {
    var name: String
    var meta: [String]
    var mine: String
    var mineRef: String
    var theirs: String
    var theirsRef: String
    var id: String { name }
  }

  struct Received: Hashable, Identifiable {
    var name: String
    var detail: String
    var time: String
    var id: String { name }
  }

  var folderName: String
  var receiving: [Transfer] = []
  var receivingDone = 0
  var receivingTotal = 0
  var receivingBytes = ""
  var source = ""
  var sending: [String: Double] = [:]
  var changedHere: [ChangedFile] = []
  var conflicts: [Conflict] = []
  var receivedToday: [Received] = []
  var receivedSummary = ""
  /// Rows for the remote's card ("Chunks", "6,412 · 3.1 GB").
  var remoteFacts: [(String, String)] = []
  var checked = ""

  var isReceiving: Bool { receivingTotal > receivingDone }
  var progressLine: String { "\(receivingDone) of \(receivingTotal)" }

  static func == (a: Self, b: Self) -> Bool {
    a.folderName == b.folderName && a.receiving == b.receiving && a.changedHere == b.changedHere
      && a.conflicts == b.conflicts && a.receivingDone == b.receivingDone
  }

  func hash(into hasher: inout Hasher) { hasher.combine(folderName) }
}

/// The live engine until folder sync is built: no activity anywhere.
final class NoFolderSync: FolderSyncEngine {
  func activity(for folderID: String) -> FolderSyncActivity? { nil }
  func keepMine(_ path: String, in folderID: String) {}
  func revert(_ path: String, in folderID: String) {}
  func revertAll(in folderID: String) {}
}

// MARK: - Remotes

/// Where folders live: this device and the remotes the user added.
enum LocationKind: String, Hashable, CaseIterable {
  case thisDevice, sftp, s3, smb, icloud, ftp

  init(_ kind: VaultRemote.Kind) {
    switch kind {
    case .s3: self = .s3
    case .sftp: self = .sftp
    case .smb: self = .smb
    case .icloud: self = .icloud
    case .ftp: self = .ftp
    }
  }

  var title: String {
    switch self {
    case .thisDevice: "This device"
    case .sftp: "SFTP"
    case .s3: "S3"
    case .smb: "SMB"
    case .icloud: "iCloud"
    case .ftp: "FTP"
    }
  }

  var systemImage: String {
    switch self {
    case .thisDevice: "house"
    case .sftp: "server.rack"
    case .s3: "archivebox"
    case .smb: "externaldrive.connected.to.line.below"
    case .icloud: "icloud"
    case .ftp: "network"
    }
  }
}

struct LocationItem: Identifiable, Hashable {
  var id: String
  var name: String
  var kind: LocationKind
  var detail: String
  var isOffline = false
}

/// A remote the Add Remote sheet is filling in.
struct RemoteDraft: Hashable {
  var kind = VaultRemote.Kind.s3
  var name = ""
  var endpoint = ""
  var bucket = ""
  var path = ""
  var hostID: String?
  var accessKeyID = ""
  var secret = ""
}

/// Remotes: the list (records in the vault), adding one, testing it, and browsing it. Each remote kind needs its
/// own `RemoteFileSystem` backend (SFTP over libssh2, S3 with SigV4, SMB); none ships yet, so the live library
/// browses only this device.
@MainActor
protocol RemoteService: AnyObject {
  var locations: [LocationItem] { get }
  /// The file system for a location, or nil while its backend isn't built.
  func fileSystem(for locationID: String) -> (any RemoteFileSystem)?
  /// Reaches the remote once, on the user's request (Test in the sheet).
  func test(_ draft: RemoteDraft) async -> Result<String, Error>
  func add(_ draft: RemoteDraft) throws
}

/// What isn't built yet, said plainly in the UI.
struct NotYetAvailable: LocalizedError {
  var what: String
  var errorDescription: String? { "\(what) comes in a later version of Vault." }
}

/// Remotes from the vault's records; browsing only this device until the backends exist.
@MainActor
final class RemoteLibrary: RemoteService {
  let vault: Vault
  private let backends: [String: any RemoteFileSystem]
  private let offline: Set<String>
  /// What "This Mac" browses: the home folder (the demo's own folder in demo runs).
  private let home: URL

  init(
    vault: Vault, backends: [String: any RemoteFileSystem] = [:], offline: Set<String> = [],
    home: URL = URL(fileURLWithPath: NSHomeDirectory())
  ) {
    self.vault = vault
    self.backends = backends
    self.offline = offline
    self.home = home
  }

  var locations: [LocationItem] {
    [LocationItem(id: "this-device", name: KitDevice.name.contains("iPad") ? "This iPad" : "This Mac", kind: .thisDevice, detail: "local folders")]
      + vault.remotes.map { remote in
        LocationItem(
          id: remote.id, name: remote.name, kind: LocationKind(remote.kind), detail: remote.displayName,
          isOffline: offline.contains(remote.id))
      }
  }

  func fileSystem(for locationID: String) -> (any RemoteFileSystem)? {
    if locationID == "this-device" { return LocalRemoteFileSystem(root: home) }
    return backends[locationID]
  }

  func test(_ draft: RemoteDraft) async -> Result<String, Error> {
    if backends.isEmpty { return .failure(NotYetAvailable(what: "Connecting to \(LocationKind(draft.kind).title) remotes")) }
    try? await Task.sleep(for: .milliseconds(600))
    return .success("Reached \(draft.bucket.isEmpty ? draft.name : draft.bucket) · 2.1 GB used")
  }

  func add(_ draft: RemoteDraft) throws {
    guard let store = vault.store else { return }
    let remote = VaultRemote(
      name: draft.name, kind: draft.kind, endpoint: draft.endpoint, bucket: draft.bucket, path: draft.path,
      hostID: draft.hostID, accessKeyID: draft.accessKeyID)
    try store.save(remote)
    if !draft.secret.isEmpty { try store.setSecret(draft.secret, forRemote: remote.id) }
    vault.reload()
  }
}

// MARK: - Recovery key

/// The optional recovery key: off by default, made only on request, never nagged about. Wrapping every key to it
/// and storing the blobs (CloudKit and each remote) is a follow-up; the live service says so.
@MainActor
protocol RecoveryService: AnyObject {
  var isOn: Bool { get }
  var isAvailable: Bool { get }
  /// Makes a new key and returns its 24 words (shown once).
  func create() throws -> [String]
}

final class UnavailableRecovery: RecoveryService {
  var isOn: Bool { false }
  var isAvailable: Bool { false }
  func create() throws -> [String] { throw NotYetAvailable(what: "The recovery key") }
}
