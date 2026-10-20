import Foundation
import Testing

@testable import VaultKit

struct FolderRecordTests {
  let keys = MemoryKeyProvider()

  init() { VaultSecrets.useInMemoryStore() }

  /// Sends an item from one device's store to another's, as sync would.
  func send(_ id: String, from: VaultStore, to: VaultStore) throws {
    let record = try #require(try from.outgoing(id: id))
    try to.apply(
      RemoteRecord(id: id, keyID: record.keyID, payload: record.payload, changeTag: UUID().uuidString, systemFields: nil))
  }

  @Test func perDeviceSettingsMerge() throws {
    let mac = try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
    let ipad = try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "ipad", notifier: nil, owner: "ipad")
    let folder = VaultFolder(name: "Work", encrypted: true, wrappedKey: "AQID", remoteID: "r1", remotePath: "work")
    try mac.save(folder)
    try send(folder.id, from: mac, to: ipad)

    // Each device changes its own settings at the same time.
    var onMac = try #require(try mac.record(VaultFolder.self, id: folder.id))
    onMac.setPath("/Users/me/Work", for: "mac")
    onMac.setStorage(.plain, for: "mac")
    try mac.save(onMac)
    var onIPad = try #require(try ipad.record(VaultFolder.self, id: folder.id))
    onIPad.setPath("Work", for: "ipad")
    onIPad.setMode(.readOnly, for: "ipad")
    onIPad.setBookmark(Data([1, 2, 3]), for: "ipad")
    try ipad.save(onIPad)
    try send(folder.id, from: ipad, to: mac)

    let read = try #require(try mac.record(VaultFolder.self, id: folder.id))
    #expect(read.path(for: "mac") == "/Users/me/Work")
    #expect(read.path(for: "ipad") == "Work")
    #expect(read.mode(for: "mac") == .readWrite)
    #expect(read.mode(for: "ipad") == .readOnly)
    #expect(read.storage(for: "mac") == .plain)
    #expect(read.storage(for: "ipad") == .encrypted)
    #expect(read.bookmark(for: "ipad") == Data([1, 2, 3]))
    #expect(read.wrappedKey == "AQID")
    #expect(!read.isShared)

    // Removing a device's path clears its field.
    var removed = read
    removed.setPath(nil, for: "ipad")
    try mac.save(removed)
    #expect(try mac.item(id: folder.id)?.values["path.ipad"] == .null)
  }

  @Test func plainFoldersDefaultToPlainStorage() {
    #expect(VaultFolder(name: "Docs", encrypted: false).storage(for: "any") == .plain)
  }

  @Test func remotesStartOff() throws {
    let store = try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
    let remote = VaultRemote(
      name: "Backups", kind: .s3, endpoint: "https://s3.example.com", bucket: "b", region: "eu", path: "vault",
      accessKeyID: "AKIA")
    #expect(!remote.enabled)
    try store.save(remote)
    try store.setSecret("s3cret", forRemote: remote.id)
    let read = try #require(try store.record(VaultRemote.self, id: remote.id))
    #expect(read == remote)
    #expect(read.secret == "s3cret")
    #expect(VaultRemote(kind: .sftp, hostID: "h1").hostID == "h1")
    try store.deleteRemote(id: remote.id)
    #expect(VaultSecrets.password(for: remote.id) == nil)
  }

  @Test func anUnknownKindIsKeptAndOff() throws {
    let store = try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
    try store.save(id: "r", kind: VaultRemote.kind, changes: ["kind": "webdav", "enabled": true, "name": "Dav"])
    var remote = try #require(try store.record(VaultRemote.self, id: "r"))
    #expect(!remote.enabled)
    remote.name = "WebDAV"
    try store.save(remote)
    let values = try #require(try store.item(id: "r")?.values)
    #expect(values["kind"] == "webdav")
    #expect(values["enabled"] == true)
    #expect(values["name"] == "WebDAV")
  }

  @MainActor @Test func theVaultListsFoldersAndRemotes() throws {
    let store = try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
    try store.save(VaultFolder(name: "b", paths: ["mac": "/b"]))
    try store.save(VaultFolder(name: "A"))
    try store.save(VaultRemote(name: "NAS", kind: .smb, endpoint: "nas.local"))
    let vault = Vault(store: store)
    #expect(vault.folders.map(\.name) == ["A", "b"])
    #expect(vault.localFolders.map(\.name) == ["b"])
    #expect(vault.remotes.map(\.displayName) == ["NAS"])
    #expect(vault.remote(id: vault.remotes.first?.id)?.kind == .smb)
  }
}

struct RemotePathTests {
  @Test func normalizes() throws {
    #expect(try RemotePath.normalize("/a//b/./c/") == "a/b/c")
    #expect(try RemotePath.normalize("") == "")
    #expect(try RemotePath.normalize("/") == "")
    #expect(throws: RemoteFileError.self) { try RemotePath.normalize("a/../b") }
    #expect(RemotePath.parent("a/b/c") == "a/b")
    #expect(RemotePath.parent("a") == "")
    #expect(RemotePath.join("", "x") == "x")
    #expect(RemotePath.join("a", "x") == "a/x")
  }
}

/// The same rules for every backend.
struct RemoteFileSystemTests {
  static func backends() -> [any RemoteFileSystem] {
    [MemoryRemoteFileSystem(), LocalRemoteFileSystem(root: temporaryDirectory())]
  }

  @Test(arguments: [0, 1]) func writeReadList(_ index: Int) async throws {
    let fs = Self.backends()[index]
    try await fs.write(Data("hello world".utf8), to: "/docs/notes/a.txt")
    try await fs.write(Data("b".utf8), to: "docs/b.txt")
    #expect(try await fs.read("docs/notes/a.txt") == Data("hello world".utf8))
    #expect(try await fs.list("").map(\.name) == ["docs"])
    let entries = try await fs.list("docs")
    #expect(entries.map(\.path) == ["docs/b.txt", "docs/notes"])
    #expect(entries.map(\.isDirectory) == [false, true])
    let info = try #require(try await fs.stat("docs/notes/a.txt"))
    #expect(info.size == 11 && !info.isDirectory && info.name == "a.txt")
    #expect(try await fs.stat("missing") == nil)
    #expect(try await fs.stat("")?.isDirectory == true)
    // Writing again replaces the file.
    try await fs.write(Data("new".utf8), to: "docs/b.txt")
    #expect(try await fs.read("docs/b.txt") == Data("new".utf8))
  }

  @Test(arguments: [0, 1]) func rangeReads(_ index: Int) async throws {
    let fs = Self.backends()[index]
    try await fs.write(Data("0123456789".utf8), to: "f")
    #expect(try await fs.read("f", range: 2..<5) == Data("234".utf8))
    #expect(try await fs.read("f", range: 8..<20) == Data("89".utf8))
    #expect(try await fs.read("f", range: 12..<20) == Data())
    #expect(try await fs.read("f", range: 0..<0) == Data())
  }

  @Test(arguments: [0, 1]) func errors(_ index: Int) async throws {
    let fs = Self.backends()[index]
    try await fs.write(Data("x".utf8), to: "file")
    try await fs.createDirectory("dir/sub")
    await #expect(throws: RemoteFileError.notFound("nope")) { try await fs.read("nope") }
    await #expect(throws: RemoteFileError.notFound("nope")) { try await fs.list("nope") }
    await #expect(throws: RemoteFileError.notADirectory("file")) { try await fs.list("file") }
    await #expect(throws: RemoteFileError.isADirectory("dir")) { try await fs.read("dir") }
    await #expect(throws: RemoteFileError.isADirectory("dir")) { try await fs.write(Data(), to: "dir") }
    await #expect(throws: RemoteFileError.notADirectory("file")) { try await fs.write(Data(), to: "file/inner") }
    await #expect(throws: RemoteFileError.alreadyExists("file")) { try await fs.createDirectory("file") }
    await #expect(throws: RemoteFileError.directoryNotEmpty("dir")) { try await fs.delete("dir") }
    await #expect(throws: RemoteFileError.notFound("gone")) { try await fs.delete("gone") }
    await #expect(throws: RemoteFileError.self) { try await fs.read("../outside") }
    // Creating an existing folder is fine.
    try await fs.createDirectory("dir")
  }

  @Test(arguments: [0, 1]) func renameAndDelete(_ index: Int) async throws {
    let fs = Self.backends()[index]
    try await fs.write(Data("1".utf8), to: "a/one")
    try await fs.write(Data("2".utf8), to: "a/two")
    try await fs.write(Data("old".utf8), to: "target")

    // A file replaces a file.
    try await fs.rename("a/one", to: "target")
    #expect(try await fs.read("target") == Data("1".utf8))
    #expect(try await fs.stat("a/one") == nil)

    // A folder moves with its contents, into folders that don't exist yet.
    try await fs.rename("a", to: "x/y/a")
    #expect(try await fs.read("x/y/a/two") == Data("2".utf8))
    #expect(try await fs.stat("a") == nil)

    await #expect(throws: RemoteFileError.alreadyExists("x")) { try await fs.rename("target", to: "x") }
    await #expect(throws: RemoteFileError.invalidPath("x/y/a/inner")) { try await fs.rename("x/y/a", to: "x/y/a/inner") }
    await #expect(throws: RemoteFileError.notFound("missing")) { try await fs.rename("missing", to: "z") }

    try await fs.delete("x/y/a/two")
    try await fs.delete("x/y/a")
    #expect(try await fs.list("x/y").isEmpty)
    try await fs.delete("target")
    #expect(try await fs.list("").map(\.name) == ["x"])
  }

  @Test func memorySeedFiles() async throws {
    let fs = MemoryRemoteFileSystem(files: ["a/b/c.txt": Data("c".utf8), "d": Data()])
    #expect(await fs.allFiles == ["a/b/c.txt", "d"])
    #expect(try await fs.list("a").map(\.path) == ["a/b"])
  }

  @Test func localStaysInsideItsRoot() async throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fs = LocalRemoteFileSystem(root: root.appendingPathComponent("inner"))
    try await fs.write(Data("x".utf8), to: "/f")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("inner/f").path))
    await #expect(throws: RemoteFileError.self) { try await fs.write(Data(), to: "../escape") }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
  }
}
