import CryptoKit
import Foundation
import Testing
import VaultFiles
import VaultKit

@testable import VaultSync

struct FolderSyncTests {
  @Test func devicesExchangeDifferentFilesAndTheRemoteHoldsOnlyCiphertext() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac")
    let ipad = try world.device("ipad", encrypted: true)
    let secret = "the launch code is 0000"
    try mac.write("notes/plan.txt", secret)
    try mac.write("empty", "")
    try ipad.write("photos/cat.bin", Data([0, 1, 2, 3, 255]) + Data(repeating: 7, count: 2500))

    try await mac.sync.sync()
    try await ipad.sync.sync()
    try await mac.sync.sync()

    #expect(try mac.files() == ["empty", "notes/plan.txt", "photos/cat.bin"])
    #expect(try ipad.files() == ["empty", "notes/plan.txt", "photos/cat.bin"])
    #expect(ipad.text("notes/plan.txt") == secret)
    #expect(mac.data("photos/cat.bin") == ipad.data("photos/cat.bin"))
    #expect(ipad.data("empty") == Data())

    // Names and contents never reach the remote in plaintext.
    for (path, data) in try await world.remoteData() {
      #expect(!path.contains("plan") && !path.contains("cat"))
      #expect(data.range(of: Data(secret.utf8)) == nil, "\(path)")
      #expect(data.range(of: Data("notes/plan.txt".utf8)) == nil, "\(path)")
    }
    let files = await world.remote.allFiles
    #expect(files.contains("sync/folder-1/members"))
    #expect(files.contains { $0.hasPrefix("sync/folder-1/log/mac/") })
    #expect(files.contains { $0.hasPrefix("sync/folder-1/log/ipad/") })
    #expect(files.contains { $0.hasPrefix("sync/folder-1/chunks/") })

    let status = await mac.status
    #expect(status.phase == .idle && status.lastError == nil)
    #expect(status.receivedRecently.map(\.path) == ["photos/cat.bin"])
    #expect(status.receivedRecently.first?.device == "ipad")
    #expect(status.remote.changeLogs == 2 && status.remote.chunkCount > 0 && status.remote.lastCheck != nil)

    // A sync with nothing new writes nothing.
    let before = await world.remote.allFiles
    try await mac.sync.sync()
    try await ipad.sync.sync()
    #expect(await world.remote.allFiles == before)
  }

  @Test func editsAndDeletesTravel() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac")
    let ipad = try world.device("ipad")
    try mac.write("a.txt", "one")
    try mac.write("dir/b.txt", "two")
    try await mac.sync.sync()
    try await ipad.sync.sync()
    try ipad.write("a.txt", "one, edited on the iPad")
    try ipad.remove("dir/b.txt")
    try await ipad.sync.sync()
    try await mac.sync.sync()
    #expect(mac.text("a.txt") == "one, edited on the iPad")
    #expect(try mac.files() == ["a.txt"])
    #expect(!FileManager.default.fileExists(atPath: mac.url.appendingPathComponent("dir").path))
    #expect(await mac.status.receivedRecently.contains { $0.path == "dir/b.txt" && $0.deleted })
  }

  @Test func concurrentTextEditsMerge() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac")
    let ipad = try world.device("ipad")
    let laptop = try world.device("laptop", person: world.bob)
    try await world.addMember(world.bob, role: .readWrite)
    try mac.write("notes.md", "# Title\nline one\nline two\nline three\n")
    try await mac.sync.sync()
    try await ipad.sync.sync()
    try await laptop.sync.sync()

    try mac.write("notes.md", "# Title\nline one, from the Mac\nline two\nline three\n")
    try ipad.write("notes.md", "# Title\nline one\nline two\nline three, from the iPad\n")
    try laptop.write("notes.md", "# Title\nline one\nline two, from Bob\nline three\n")
    try await mac.sync.sync()
    try await ipad.sync.sync()
    try await laptop.sync.sync()
    try await mac.sync.sync()
    try await ipad.sync.sync()

    let merged = "# Title\nline one, from the Mac\nline two, from Bob\nline three, from the iPad\n"
    #expect(mac.text("notes.md") == merged)
    #expect(ipad.text("notes.md") == merged)
    #expect(laptop.text("notes.md") == merged)
    #expect(try mac.files() == ["notes.md"])
    #expect(await mac.status.conflictCopies.isEmpty)

    // The resolution was written as a change, so the file has one version again everywhere.
    try await laptop.sync.sync()
    for device in [mac, ipad, laptop] {
      try await device.sync.sync()
      #expect(try await device.sync.resolve("notes.md").contested == false)
    }
    try mac.write("notes.md", merged + "more\n")
    try await mac.sync.sync()
    try await laptop.sync.sync()
    #expect(laptop.text("notes.md") == merged + "more\n")
  }

  @Test func concurrentBinaryEditsKeepTheLaterAndACopy() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac")
    let ipad = try world.device("ipad")
    let original = Data([0, 0, 1]) + Data(repeating: 1, count: 1500)
    try mac.write("image.bin", original)
    try await mac.sync.sync()
    try await ipad.sync.sync()

    let t = Date()
    let macVersion = Data([0, 0, 2]) + Data(repeating: 2, count: 1500)
    let ipadVersion = Data([0, 0, 3]) + Data(repeating: 3, count: 100)
    try mac.write("image.bin", macVersion, modified: t)
    try ipad.write("image.bin", ipadVersion, modified: t + 60)  // the later write
    try await mac.sync.sync()
    try await ipad.sync.sync()
    try await mac.sync.sync()
    try await ipad.sync.sync()

    let copy = FolderSync.conflictCopyPath(
      "image.bin",
      loser: FileChange(
        folder: "", path: "image.bin", clock: HybridClock(millis: Int64((t.timeIntervalSince1970 * 1000).rounded(.down)), counter: 0, device: "mac"),
        parents: [], deleted: false, size: 0, hash: "", chunks: []))
    #expect(copy.hasPrefix("image (conflict from mac ") && copy.hasSuffix(").bin"))
    for device in [mac, ipad] {
      #expect(device.data("image.bin") == ipadVersion)
      #expect(device.data(copy) == macVersion)
      #expect(try device.files() == [copy, "image.bin"].sorted())
      #expect(await device.status.conflictCopies == [copy])
    }
    // Collapsed: one head for the file and one for the copy.
    try await mac.sync.sync()
    #expect(try await mac.sync.resolve("image.bin").contested == false)
    #expect(try await mac.sync.resolve(copy).heads.count >= 1)
  }

  @Test func overlappingTextEditsMakeACopyToo() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac")
    let ipad = try world.device("ipad")
    try mac.write("todo.txt", "buy milk\n")
    try await mac.sync.sync()
    try await ipad.sync.sync()
    let t = Date()
    try mac.write("todo.txt", "buy oat milk\n", modified: t + 30)  // the later write
    try ipad.write("todo.txt", "buy soy milk\n", modified: t)
    try await ipad.sync.sync()
    try await mac.sync.sync()
    try await ipad.sync.sync()
    for device in [mac, ipad] {
      #expect(device.text("todo.txt") == "buy oat milk\n")
      let copies = await device.status.conflictCopies
      #expect(copies.count == 1)
      #expect(copies.first.flatMap { device.text($0) } == "buy soy milk\n")
    }
  }

  @Test func anEditBeatsADeleteMadeAtTheSameTime() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac")
    let ipad = try world.device("ipad")
    try mac.write("keep.txt", "v1")
    try await mac.sync.sync()
    try await ipad.sync.sync()
    try mac.remove("keep.txt")
    try ipad.write("keep.txt", "v2 from the iPad", modified: Date() - 3600)  // even when older
    try await mac.sync.sync()
    try await ipad.sync.sync()
    try await mac.sync.sync()
    #expect(mac.text("keep.txt") == "v2 from the iPad")
    #expect(ipad.text("keep.txt") == "v2 from the iPad")
    #expect(await mac.status.conflictCopies.isEmpty)
  }

  @Test func readOnlyDeviceKeepsItsEditsAndNeverSendsThem() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac")
    let ipad = try world.device("ipad", mode: .readOnly)
    try mac.write("shared.txt", "from the Mac\n")
    try mac.write("other.txt", "other\n")
    try await mac.sync.sync()
    try await ipad.sync.sync()
    #expect(ipad.text("shared.txt") == "from the Mac\n")

    try ipad.write("shared.txt", "edited on the iPad\n")
    try ipad.write("new.txt", "made on the iPad\n")
    try ipad.remove("other.txt")
    try await ipad.sync.sync()
    #expect(!(await world.remote.allFiles).contains { $0.contains("/log/ipad") })
    var status = await ipad.status
    #expect(status.mode == .readOnly)
    #expect(status.changedHere.map(\.path) == ["new.txt", "other.txt", "shared.txt"])
    #expect(status.changedHere.map(\.change) == [.added, .deleted, .modified])
    #expect(status.conflicts.isEmpty)
    try await mac.sync.sync()
    #expect(mac.text("shared.txt") == "from the Mac\n" && mac.text("new.txt") == nil && mac.text("other.txt") == "other\n")

    // The remote changes the file edited here: the edit stays, and both sides show.
    try mac.write("shared.txt", "from the Mac, again\n")
    try await mac.sync.sync()
    try await ipad.sync.sync()
    #expect(ipad.text("shared.txt") == "edited on the iPad\n")
    status = await ipad.status
    #expect(status.conflicts.map(\.path) == ["shared.txt"])
    #expect(status.conflicts.first?.mine.text == "edited on the iPad\n")
    #expect(status.conflicts.first?.remote.text == "from the Mac, again\n")
    #expect(status.conflicts.first?.remote.device == "mac")

    // Keep Mine: the conflict goes, the edit stays changed here, until the remote changes again.
    try await ipad.sync.keepMine("shared.txt")
    status = await ipad.status
    #expect(status.conflicts.isEmpty && status.changedHere.count == 3)
    try await ipad.sync.sync()
    #expect(await ipad.status.conflicts.isEmpty)
    try mac.write("shared.txt", "from the Mac, a third time\n")
    try await mac.sync.sync()
    try await ipad.sync.sync()
    #expect(await ipad.status.conflicts.map(\.path) == ["shared.txt"])
    #expect(ipad.text("shared.txt") == "edited on the iPad\n")

    // Revert to Remote for one file, then everything.
    try await ipad.sync.revertToRemote("shared.txt")
    #expect(ipad.text("shared.txt") == "from the Mac, a third time\n")
    status = await ipad.status
    #expect(status.conflicts.isEmpty && status.changedHere.map(\.path) == ["new.txt", "other.txt"])
    try await ipad.sync.revertAll()
    #expect(try ipad.files() == ["other.txt", "shared.txt"])
    #expect(ipad.text("other.txt") == "other\n")
    #expect(await ipad.status.changedHere.isEmpty)
    try await ipad.sync.sync()
    #expect(await ipad.status.changedHere.isEmpty)
  }

  @Test func readOnlyMembersCantWrite() async throws {
    let world = try await SyncWorld()
    try await world.addMember(world.bob, role: .readOnly)
    let mac = try world.device("mac")
    let bobsMac = try world.device("bobs-mac", person: world.bob, mode: .readWrite)
    try mac.write("doc.txt", "Alice's\n")
    try await mac.sync.sync()
    try await bobsMac.sync.sync()
    #expect(bobsMac.text("doc.txt") == "Alice's\n")
    #expect(await bobsMac.status.mode == .readOnly)
    #expect(await bobsMac.status.role == .readOnly)

    // Bob's device doesn't send, even in read-write mode.
    try bobsMac.write("doc.txt", "Bob's\n")
    try await bobsMac.sync.sync()
    #expect(!(await world.remote.allFiles).contains { $0.contains("/log/bobs-mac") })

    // A log Bob writes by hand (he holds the key) is ignored.
    let keys = SyncKeys(try (try await FolderMembers.read(
      from: world.remote, folderPath: world.remotePath, folderID: world.folderID,
      ownerSigningKey: world.alice.publicIdentity.signingKey)).keyring(for: world.bob))
    let forged = FileChange(
      folder: world.folderID, path: "doc.txt", clock: HybridClock(millis: Int64(Date().timeIntervalSince1970 * 1000) + 999_999, counter: 0, device: "bobs-mac"),
      parents: [], deleted: true, size: 0, hash: "", chunks: [])
    let segment = LogSegment(changes: [try SignedChange.sign(forged, by: world.bob)])
    let sealed = try keys.seal(
      SyncCoding.encoder.encode(segment), context: Data("dev.v57.sync.log|\(world.folderID)|bobs-mac|1".utf8))
    try await world.remote.write(sealed, to: RemoteLayout(root: world.remotePath).segment("bobs-mac", 1))
    try await mac.sync.sync()
    #expect(mac.text("doc.txt") == "Alice's\n")
    #expect(await mac.status.ignoredChanges == 1)
  }

  @Test func aNewDeviceStartsFromASnapshot() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac") { $0.snapshotAfter = 4 }
    for round in 0..<4 {
      try mac.write("file\(round).txt", "round \(round)")
      try mac.write("changing.txt", "version \(round)")
      try await mac.sync.sync()
    }
    try mac.remove("file0.txt")
    try await mac.sync.sync()
    let snapshots = await world.remote.allFiles.filter { $0.contains("/snapshots/") }
    #expect(!snapshots.isEmpty)
    let logsBefore = await world.remote.allFiles.filter { $0.contains("/log/mac/") }.count

    // After the grace period the Mac deletes the log files the snapshot covers.
    world.clock.advance(SyncWorld.day + 60)
    try await mac.sync.sync()
    let logsAfter = await world.remote.allFiles.filter { $0.contains("/log/mac/") }.count
    #expect(logsAfter < logsBefore)

    let ipad = try world.device("ipad", encrypted: true)
    try await ipad.sync.sync()
    #expect(try ipad.files() == ["changing.txt", "file1.txt", "file2.txt", "file3.txt"])
    #expect(ipad.text("changing.txt") == "version 3")
    #expect(await ipad.status.remote.lastSnapshot != nil)
    // And it keeps syncing from there.
    try mac.write("changing.txt", "version 4")
    try await mac.sync.sync()
    try await ipad.sync.sync()
    #expect(ipad.text("changing.txt") == "version 4")
    try ipad.write("from-ipad.txt", "hi")
    try await ipad.sync.sync()
    try await mac.sync.sync()
    #expect(mac.text("from-ipad.txt") == "hi")
  }

  @Test func removingSomeoneRotatesTheKey() async throws {
    let world = try await SyncWorld()
    try await world.addMember(world.bob, role: .readWrite)
    try await world.addMember(world.carol, role: .readWrite)
    let mac = try world.device("mac")
    let bobsMac = try world.device("bobs-mac", person: world.bob)
    let carolsMac = try world.device("carols-mac", person: world.carol, encrypted: true)
    try bobsMac.write("bob.txt", "written before he left")
    try await bobsMac.sync.sync()
    try await mac.sync.sync()
    #expect(await mac.sync.writesUntil(signingKey: world.bob.publicIdentity.signingKey) == ["bobs-mac": 1])

    try await mac.sync.removeMember(world.bob.publicIdentity.signingKey)
    let members = try #require(await mac.sync.memberList)
    #expect(members.epoch == 1 && members.member(signingKey: world.bob.publicIdentity.signingKey) == nil)
    let newKey = try members.keyring(for: world.alice).current
    #expect(newKey != world.firstKey)

    try mac.write("after.txt", "written after Bob left")
    try await mac.sync.sync()
    // New chunks are sealed with the new key.
    let after = try await world.remoteData().filter { $0.key.contains("/chunks/") }
    #expect(after.values.contains { (try? EncryptedFile.Header(parsing: $0).keyID) == newKey.id })

    // Bob is out; what he wrote before stays; what he writes now is ignored.
    await #expect(throws: FolderSyncError.notAMember) { try await bobsMac.sync.sync() }
    let keys = SyncKeys(FolderKeyring(epoch: 0, keys: [0: world.firstKey]))
    let forged = FileChange(
      folder: world.folderID, path: "bob.txt", clock: HybridClock(millis: Int64(Date().timeIntervalSince1970 * 1000) + 999_999, counter: 0, device: "bobs-mac"),
      parents: [], deleted: true, size: 0, hash: "", chunks: [])
    let sealed = try keys.seal(
      SyncCoding.encoder.encode(LogSegment(changes: [try SignedChange.sign(forged, by: world.bob)])),
      context: Data("dev.v57.sync.log|\(world.folderID)|bobs-mac|2".utf8))
    try await world.remote.write(sealed, to: RemoteLayout(root: world.remotePath).segment("bobs-mac", 2))

    try await carolsMac.sync.sync()
    #expect(carolsMac.text("bob.txt") == "written before he left")
    #expect(carolsMac.text("after.txt") == "written after Bob left")
    try await mac.sync.sync()
    #expect(mac.text("bob.txt") == "written before he left")
    #expect(await mac.status.ignoredChanges == 1)
  }

  @Test func unusedChunksGoAfterTheGracePeriod() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac") { $0.snapshotAfter = 1 }
    try mac.write("big.bin", Data(repeating: 1, count: 2500))
    try await mac.sync.sync()
    let first = Set(await world.remote.allFiles.filter { $0.contains("/chunks/") })
    #expect(first.count == 2)  // 1000-byte chunks: two of ones (deduped), one of the rest
    try mac.write("big.bin", Data(repeating: 2, count: 1500))
    try await mac.sync.sync()  // a snapshot drops the old version; its chunks are unreferenced from now
    var chunks = Set(await world.remote.allFiles.filter { $0.contains("/chunks/") })
    #expect(first.isSubset(of: chunks))

    world.clock.advance(SyncWorld.day / 2)
    try await mac.sync.sync()
    chunks = Set(await world.remote.allFiles.filter { $0.contains("/chunks/") })
    #expect(first.isSubset(of: chunks))  // still within the grace period

    world.clock.advance(SyncWorld.day)
    try await mac.sync.sync()
    chunks = Set(await world.remote.allFiles.filter { $0.contains("/chunks/") })
    #expect(chunks.isDisjoint(with: first))
    #expect(chunks.count == 2)
    #expect(await mac.status.remote.chunkCount == 2)

    // The current version still arrives on a new device.
    let ipad = try world.device("ipad")
    try await ipad.sync.sync()
    #expect(ipad.data("big.bin") == Data(repeating: 2, count: 1500))
  }

  @Test func stateSurvivesARelaunch() async throws {
    let world = try await SyncWorld()
    var mac = try world.device("mac", persistent: true)
    try mac.write("a.txt", "a")
    try await mac.sync.sync()
    let files = await world.remote.allFiles
    mac = try world.device("mac", persistent: true)
    try await mac.sync.sync()
    #expect(await world.remote.allFiles == files)
    // The state file is sealed: no names in it.
    let state = try Data(contentsOf: world.directory.file("devices/mac/state.v57sync"))
    #expect(state.range(of: Data("a.txt".utf8)) == nil)
    try mac.write("a.txt", "b")
    try await mac.sync.sync()
    let ipad = try world.device("ipad")
    try await ipad.sync.sync()
    #expect(ipad.text("a.txt") == "b")
  }

  @Test func damagedChunksAreRefused() async throws {
    let world = try await SyncWorld()
    let mac = try world.device("mac")
    try mac.write("a.bin", Data(repeating: 5, count: 900))
    try mac.write("b.bin", Data(repeating: 6, count: 900))
    try await mac.sync.sync()
    let chunks = await world.remote.allFiles.filter { $0.contains("/chunks/") }
    #expect(chunks.count == 2)
    // Swap the two chunks' contents: each is still valid ciphertext, but not of its name.
    let first = try await world.remote.read(chunks[0])
    let second = try await world.remote.read(chunks[1])
    try await world.remote.write(second, to: chunks[0])
    try await world.remote.write(first, to: chunks[1])
    let ipad = try world.device("ipad")
    try await ipad.sync.sync()
    #expect(try ipad.files().isEmpty)
    #expect(await ipad.status.lastError != nil)
  }

  @Test func refusesAnOlderMemberList() async throws {
    let world = try await SyncWorld()
    let old = try await world.remote.read("sync/folder-1/members")
    try await world.addMember(world.bob, role: .readOnly)
    let mac = try world.device("mac")
    try await mac.sync.sync()
    try await world.remote.write(old, to: "sync/folder-1/members")
    await #expect(throws: FolderSyncError.olderMemberList(found: 0, known: 1)) { try await mac.sync.sync() }
  }
}
