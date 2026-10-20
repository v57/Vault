import Foundation
import VaultFiles
import VaultKit

@testable import VaultSync

/// A temporary directory removed when the test ends.
final class TemporaryDirectory: @unchecked Sendable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("VaultSyncTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// A clock tests move by hand: the engines' `now` and the remote's modification dates.
final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date()

  var now: Date { lock.withLock { current } }

  func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// One shared folder on an in-memory remote, with people and their devices.
final class SyncWorld: @unchecked Sendable {
  let clock = TestClock()
  let remote: MemoryRemoteFileSystem
  let directory: TemporaryDirectory
  let alice = PersonalIdentity()
  let bob = PersonalIdentity()
  let carol = PersonalIdentity()
  let folderID = "folder-1"
  let remotePath = "sync/folder-1"
  let firstKey = FolderKey()
  static let day: TimeInterval = 24 * 3600

  init() async throws {
    let clock = clock
    remote = MemoryRemoteFileSystem(clock: { clock.now })
    directory = try TemporaryDirectory()
    try await FolderSync.createRemoteFolder(
      remote: remote, remotePath: remotePath, folderID: folderID, owner: alice, ownerName: "Alice", key: firstKey)
  }

  /// Adds someone as the owner would, straight on the remote.
  func addMember(_ identity: PersonalIdentity, role: VaultPerson.Role) async throws {
    var list = try await FolderMembers.read(
      from: remote, folderPath: remotePath, folderID: folderID, ownerSigningKey: alice.publicIdentity.signingKey)
    try list.add(identity.publicIdentity, name: "someone", role: role, owner: alice)
    try await list.write(to: remote, folderPath: remotePath)
  }

  func device(
    _ name: String, person: PersonalIdentity? = nil, mode: VaultFolder.Mode = .readWrite, encrypted: Bool = false,
    persistent: Bool = false, configure: (inout FolderSync.Configuration) -> Void = { _ in }
  ) throws -> Device {
    let folderURL = directory.file("devices/\(name)/Folder")
    let local: any SyncLocalFolder
    var encryptedFolder: EncryptedFolder?
    if encrypted {
      let folder = try EncryptedFolder(url: folderURL, key: firstKey)
      encryptedFolder = folder
      local = EncryptedSyncFolder(folder)
    } else {
      local = try PlainSyncFolder(url: folderURL)
    }
    let clock = clock
    var configuration = FolderSync.Configuration(
      folderID: folderID, remote: remote, remotePath: remotePath, local: local, device: name,
      identity: person ?? alice, ownerSigningKey: alice.publicIdentity.signingKey, mode: mode,
      stateURL: persistent ? directory.file("devices/\(name)/state.v57sync") : nil)
    configuration.chunkSize = 1000
    configuration.now = { clock.now }
    configure(&configuration)
    return Device(sync: try FolderSync(configuration), url: folderURL, encrypted: encryptedFolder)
  }

  /// Every remote file that isn't the member list, for checking nothing readable is there.
  func remoteData() async throws -> [String: Data] {
    var result: [String: Data] = [:]
    for path in await remote.allFiles { result[path] = try await remote.read(path) }
    return result
  }
}

final class Device: @unchecked Sendable {
  let sync: FolderSync
  let url: URL
  let encrypted: EncryptedFolder?

  init(sync: FolderSync, url: URL, encrypted: EncryptedFolder?) {
    self.sync = sync
    self.url = url
    self.encrypted = encrypted
  }

  func write(_ path: String, _ text: String, modified: Date? = nil) throws {
    try write(path, Data(text.utf8), modified: modified)
  }

  func write(_ path: String, _ data: Data, modified: Date? = nil) throws {
    if let encrypted {
      try encrypted.write(data, to: path)
      return
    }
    let file = url.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
  }

  func data(_ path: String) -> Data? {
    if let encrypted { return try? encrypted.read(path) }
    return try? Data(contentsOf: url.appendingPathComponent(path))
  }

  func text(_ path: String) -> String? { data(path).map { String(decoding: $0, as: UTF8.self) } }

  func remove(_ path: String) throws {
    if let encrypted {
      try encrypted.remove(path)
    } else {
      try FileManager.default.removeItem(at: url.appendingPathComponent(path))
    }
  }

  /// Every file's path, sorted.
  func files() throws -> [String] {
    let local: any SyncLocalFolder = try encrypted.map { EncryptedSyncFolder($0) } ?? PlainSyncFolder(url: url)
    return try local.scan().map(\.path)
  }

  var status: FolderSyncStatus { get async { await sync.status } }
}
