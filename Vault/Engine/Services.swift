import ComponentKit
import Foundation
import VaultKit

// The parts of the design VaultKit doesn't do yet are drawn against these protocols. Each has a demo
// implementation (sample data, for screenshots and design checks) and a live one that says what isn't there yet.

// MARK: - Folder sync over plain storage

/// What syncing a folder through a remote is doing: files arriving, edits kept here on a read-only device,
/// conflicts, what came in today, and the member list a share writes to. The live engine is `LiveFolderSync`
/// (VaultSync's `FolderSync`, one per folder); the demo's shows sample data.
@MainActor
protocol FolderSyncEngine: AnyObject {
  func activity(for folderID: String) -> FolderSyncActivity?
  func keepMine(_ path: String, in folderID: String)
  func revert(_ path: String, in folderID: String)
  func revertAll(in folderID: String)
  /// The library whose folders it syncs (the encrypted ones are opened through it).
  func attach(_ library: FolderLibrary)
  /// Makes a folder of the user's own on its remote (its member list, with the user as the owner), then syncs it.
  func start(_ folderID: String) async throws
  /// One pass for a folder: receive, send, tidy up. Errors show in its activity.
  func sync(_ folderID: String) async
  /// One pass for every folder with a remote.
  func syncAll() async
  /// Whether sharing the folder can hand a new member its key: it syncs through a remote and the user owns it.
  func deliversKeys(for folderID: String) -> Bool
  /// Adds someone to the folder's signed member list (the owner only), or changes their role.
  func addMember(_ identity: PublicIdentity, name: String, role: VaultPerson.Role, to folderID: String) async throws
  /// Removes someone from the member list and rotates the folder key (the owner only).
  func removeMember(_ identity: PublicIdentity, from folderID: String) async throws
}

extension FolderSyncEngine {
  func attach(_ library: FolderLibrary) {}
  func start(_ folderID: String) async throws {}
  func sync(_ folderID: String) async {}
  func syncAll() async {}
  func deliversKeys(for folderID: String) -> Bool { true }
  func addMember(_ identity: PublicIdentity, name: String, role: VaultPerson.Role, to folderID: String) async throws {}
  func removeMember(_ identity: PublicIdentity, from folderID: String) async throws {}
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
    /// The path in the folder, which Keep Mine and Revert act on.
    var path: String
    var id: String { path }
  }

  struct Conflict: Hashable, Identifiable {
    var name: String
    var meta: [String]
    var mine: String
    var mineRef: String
    var theirs: String
    var theirsRef: String
    var path: String
    var id: String { path }
  }

  struct Received: Hashable, Identifiable {
    var name: String
    var detail: String
    var time: String
    var id: String { name + time }
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
  /// Checking, receiving, sending or tidying up right now.
  var isWorking = false
  /// What stopped the last pass (the remote refused, this person isn't a member yet…).
  var error: String?
  /// Set on a shared folder whose owner hasn't added this person yet: what it waits for.
  var waiting: String?

  var isReceiving: Bool { receivingTotal > receivingDone }
  var progressLine: String { "\(receivingDone) of \(receivingTotal)" }

  static func == (a: Self, b: Self) -> Bool {
    a.folderName == b.folderName && a.receiving == b.receiving && a.changedHere == b.changedHere
      && a.conflicts == b.conflicts && a.receivingDone == b.receivingDone && a.error == b.error
      && a.isWorking == b.isWorking && a.checked == b.checked
  }

  func hash(into hasher: inout Hasher) { hasher.combine(folderName) }
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
    case .thisDevice: String(localized: "This device")
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

/// Remotes: the list (records in the vault), adding one, testing it, and browsing it. S3 has a backend
/// (`RemoteConnections`); SFTP, SMB, iCloud and FTP don't yet, so those can be added but not reached.
@MainActor
protocol RemoteService: AnyObject {
  var locations: [LocationItem] { get }
  /// The file system for a location, or nil while its backend isn't built or the remote is off.
  func fileSystem(for locationID: String) -> (any RemoteFileSystem)?
  /// Reaches the remote once, on the user's request (Test in the sheet).
  func test(_ draft: RemoteDraft) async -> Result<String, Error>
  func add(_ draft: RemoteDraft) throws
  /// Turns a remote on (Vault may reach it) or off (nothing contacts it).
  func setEnabled(_ enabled: Bool, for remoteID: String)
}

/// What isn't built yet, said plainly in the UI.
struct NotYetAvailable: LocalizedError {
  var what: String
  var errorDescription: String? { "\(what) comes in a later version of Vault." }
}

/// Remotes from the vault's records, reached through VaultKit's backends (S3 today). The demo passes sample
/// listings instead (`backends`).
@MainActor
final class RemoteLibrary: RemoteService {
  let vault: Vault
  private let backends: [String: any RemoteFileSystem]
  private let offline: Set<String>
  /// What "This Mac" browses: the home folder (the demo's own folder in demo runs).
  private let home: URL
  private let isDemo: Bool

  init(
    vault: Vault, backends: [String: any RemoteFileSystem] = [:], offline: Set<String> = [],
    home: URL = URL(fileURLWithPath: NSHomeDirectory()), isDemo: Bool = false
  ) {
    self.vault = vault
    self.backends = backends
    self.offline = offline
    self.home = home
    self.isDemo = isDemo
  }

  var locations: [LocationItem] {
    [LocationItem(id: "this-device", name: String(localized: "This \(ThisDevice.word)"), kind: .thisDevice, detail: String(localized: "local folders"))]
      + vault.remotes.map { remote in
        LocationItem(
          id: remote.id, name: remote.name, kind: LocationKind(remote.kind), detail: remote.displayName,
          isOffline: offline.contains(remote.id))
      }
  }

  func fileSystem(for locationID: String) -> (any RemoteFileSystem)? {
    if locationID == "this-device" { return LocalRemoteFileSystem(root: home) }
    if isDemo { return backends[locationID] }
    guard let remote = vault.remote(id: locationID), remote.enabled else { return nil }
    return try? LiveFolderSync.backend(for: remote)
  }

  func test(_ draft: RemoteDraft) async -> Result<String, Error> {
    if isDemo {
      try? await Task.sleep(for: .milliseconds(600))
      return .success("Reached \(draft.bucket.isEmpty ? draft.name : draft.bucket) · 2.1 GB used")
    }
    do {
      let remote = VaultRemote(
        name: draft.name, kind: draft.kind, endpoint: draft.endpoint, bucket: draft.bucket, path: draft.path,
        hostID: draft.hostID, accessKeyID: draft.accessKeyID, enabled: true)
      guard let backend = try RemoteConnections.fileSystem(for: remote, secret: draft.secret) else {
        return .failure(NotYetAvailable(what: "Connecting to \(LocationKind(draft.kind).title) remotes"))
      }
      let entries = try await backend.list("")
      let place = draft.bucket.isEmpty ? draft.name : draft.bucket
      switch entries.count {
      case 0: return .success(String(localized: "Reached \(place) · empty"))
      case 1: return .success(String(localized: "Reached \(place) · 1 item"))
      default: return .success(String(localized: "Reached \(place) · \(entries.count) items"))
      }
    } catch {
      return .failure(error)
    }
  }

  func add(_ draft: RemoteDraft) throws {
    guard let store = vault.store else { return }
    // Added by the user, so it's on: Vault reaches it only for folders that sync through it, or when browsed.
    let remote = VaultRemote(
      name: draft.name, kind: draft.kind, endpoint: draft.endpoint, bucket: draft.bucket, path: draft.path,
      hostID: draft.hostID, accessKeyID: draft.accessKeyID, enabled: true)
    try store.save(remote)
    if !draft.secret.isEmpty { try store.setSecret(draft.secret, forRemote: remote.id) }
    vault.reload()
  }

  func setEnabled(_ enabled: Bool, for remoteID: String) {
    guard var remote = vault.remote(id: remoteID), remote.enabled != enabled else { return }
    remote.enabled = enabled
    vault.save(remote)
  }
}

// MARK: - Recovery key

/// The optional recovery key: off by default, made only on request, never nagged about. The live one (`LiveRecovery`)
/// keeps it in Personal's store, so its sealed copies sync to CloudKit like any record.
@MainActor
protocol RecoveryService: AnyObject {
  var isOn: Bool { get }
  var isAvailable: Bool { get }
  /// Makes a new key and returns its 24 words (shown once).
  func create() throws -> [String]
  /// Whether typed or scanned words are the current kit; throws for words that aren't a kit.
  func check(_ text: String) throws -> Bool
  /// A new kit for a lost or leaked one: a new vault key, everything sealed to the new kit, the old copies deleted.
  func replace() async throws -> [String]
  /// Deletes the kit's public key and every sealed copy.
  func turnOff() async throws
  /// Opens the sealed copies with the words and writes back the keys, the identity and the secrets; says what came back.
  func recover(_ text: String) async throws -> String
}

final class UnavailableRecovery: RecoveryService {
  var isOn: Bool { false }
  var isAvailable: Bool { false }
  func create() throws -> [String] { throw NotYetAvailable(what: "The recovery key") }
  func check(_ text: String) throws -> Bool { throw NotYetAvailable(what: "The recovery key") }
  func replace() async throws -> [String] { throw NotYetAvailable(what: "The recovery key") }
  func turnOff() async throws {}
  func recover(_ text: String) async throws -> String { throw NotYetAvailable(what: "The recovery key") }
}
