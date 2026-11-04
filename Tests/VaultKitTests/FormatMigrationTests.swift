import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Every kind of record there is, by the name its record type writes.
private let everyKind = [
  "account", "appleTeam", "card", "database", "deviceKey", "folder", "gitSettings", "host", "hub", "knownHost", "login",
  "note", "noteFile", "passkey", "person", "profile", "project", "projectGroup", "recoveryKey", "remote", "revokedDevice",
]

private func keysCopy(_ keys: MemoryKeyProvider) -> MemoryKeyProvider {
  MemoryKeyProvider(keys: keys.allKeys)
}

private func open(
  _ directory: URL, keys: VaultKeyProvider, device: String = "mac", fileName: String = VaultStore.fileName,
  account: String? = nil, testing: FormatTesting = FormatTesting()
) throws -> VaultStore {
  try VaultStore(
    directory: directory, fileName: fileName, accountID: account, keys: keys, deviceID: device, notifier: nil, owner: "test",
    formatTesting: testing)
}

/// A store as an old build left it.
private func oldStore(keys: MemoryKeyProvider, rows: Int = 0) throws -> OldBuildStore {
  let old = try OldBuildStore(keys: keys, device: "mac")
  for kind in everyKind { try old.save(id: "id-\(kind)", kind: kind, changes: ["name": .string(kind)]) }
  for index in 0..<rows { try old.save(id: "row-\(index)", kind: "login", changes: ["n": .int(Int64(index))]) }
  return old
}

private func expectEverythingReadable(_ store: VaultStore, rows: Int = 0) throws {
  for kind in everyKind {
    let item = try #require(try store.item(id: "id-\(kind)"))
    #expect(item.kind == kind)
    #expect(item.fields["name"]?.stringValue == kind)
    #expect(try store.items(kind: kind).map(\.id).contains("id-\(kind)"))
  }
  for index in 0..<rows {
    #expect(try store.item(id: "row-\(index)")?.fields["n"] == .int(Int64(index)))
  }
}

private func payload(_ store: VaultStore, _ id: String) throws -> (keyID: String, payload: Data) {
  let row = try #require(try store.database.query("SELECT key_id, payload FROM items WHERE id = ?", [.text(id)]).first)
  return (row[0].text ?? "", row[1].blob ?? Data())
}

private func format1Rows(_ store: VaultStore) throws -> Int {
  Int(try store.database.query("SELECT COUNT(*) FROM items WHERE substr(payload, 1, 5) != x'5635374902'")[0][0].int ?? 0)
}

private func copyStoreFiles(of directory: URL, to image: URL) throws {
  try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
  for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
    try FileManager.default.copyItem(at: directory.appendingPathComponent(name), to: image.appendingPathComponent(name))
  }
}

@Suite struct FormatMigrationTests {
  // MARK: Migrating

  @Test func anOldStoreMovesOverOnOpenWithEveryKindRight() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys, rows: 5)
    let store = try open(old.directory, keys: keys)

    #expect(store.isFormatFinished)
    #expect(try format1Rows(store) == 0)
    try expectEverythingReadable(store, rows: 5)
    let status = store.formatStatus
    #expect(status.resealed == everyKind.count + 5)
    #expect(status.unreadable == 0)
    #expect(status.error == nil)
    // Everything goes up, so the other devices get format 2.
    #expect(try store.pendingCount() == everyKind.count + 5)
  }

  @Test func theBackupHoldsTheOldStoreAndStays() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let before = try old.database.query("SELECT id, payload FROM items ORDER BY id")
    let store = try open(old.directory, keys: keys)

    let backup = try #require(store.formatStatus.backup)
    #expect(backup.lastPathComponent == "Vault.sqlite.format1-backup")
    let copy = try SQLiteConnection(url: backup)
    let rows = try copy.query("SELECT id, payload FROM items ORDER BY id")
    #expect(rows.count == before.count)
    for (a, b) in zip(rows, before) { #expect(a[1].blob == b[1].blob) }

    // It stays through later opens, and a store that had nothing to rewrite makes none.
    _ = try open(old.directory, keys: keys)
    #expect(FileManager.default.fileExists(atPath: backup.path))
    let fresh = try open(temporaryDirectory(), keys: MemoryKeyProvider())
    #expect(fresh.formatStatus.backup == nil)
    // Deleting a store deletes its backup: `removeDeletedAccounts` looks for `.sqlite`, which the name doesn't end in.
    #expect(!backup.path.hasSuffix(".sqlite"))
    VaultStore.removeFiles(at: store.fileURL)
    #expect(!FileManager.default.fileExists(atPath: backup.path))
  }

  @Test func tombstonesAndBookkeepingMoveOver() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let cloud = FakeCloud()
    try old.push(cloud)
    try old.delete(id: "id-login")
    let tag = try old.database.query("SELECT change_tag FROM items WHERE id = 'id-host'")[0][0].text
    let store = try open(old.directory, keys: keys)
    #expect(try store.item(id: "id-login")?.isDeleted == true)
    #expect(try store.items(kind: "login").isEmpty)
    let row = try store.database.query("SELECT change_tag FROM items WHERE id = 'id-host'")[0][0].text
    #expect(row == tag)
  }

  @Test func theTextMergeBaseMovesOver() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let sealed = try OldBuildStore.format1(
      id: "id-note", kind: "note", fields: try #require(old.read("id-note")).fields, keys: keys)
    try old.database.query(
      "INSERT INTO server_copies(id, key_id, payload) VALUES('id-note', ?, ?)", [.text(sealed.keyID), .blob(sealed.payload)])
    let store = try open(old.directory, keys: keys)
    #expect(try store.serverCopy(id: "id-note") != nil)
  }

  @Test func aRowWithNoKindStaysReadableAndIsCounted() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    try old.save(id: "plain", kind: "", changes: ["a": .string("b")])
    let store = try open(old.directory, keys: keys)
    #expect(store.formatStatus.withoutKind == 1)
    #expect(try store.item(id: "plain")?.fields["a"]?.stringValue == "b")
    #expect(try store.item(id: "plain")?.kind == "")
  }

  @Test func thePayloadsKindWinsOverTheColumnAndIsCounted() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    try old.database.query("UPDATE items SET kind = 'login' WHERE id = 'id-host'")
    let store = try open(old.directory, keys: keys)
    #expect(store.formatStatus.kindMismatches == 1)
    #expect(try store.item(id: "id-host")?.kind == "host")
  }

  @Test func aRowWhoseKeyHasntArrivedStaysAndMovesOverWhenItDoes() throws {
    let keys = MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(size: .bits256)])
    let other = MemoryKeyProvider(keys: ["ffff": SymmetricKey(size: .bits256)])
    let old = try oldStore(keys: keys)
    // A row from another device under a key this one doesn't have yet.
    let writer = try OldBuildStore(keys: other, device: "other")
    try writer.save(id: "theirs", kind: "login", changes: ["a": .string("b")])
    let theirs = try writer.database.query("SELECT key_id, payload FROM items WHERE id = 'theirs'")[0]
    try old.database.query(
      "INSERT INTO items(id, kind, key_id, payload) VALUES('theirs', '', ?, ?)", [.text(theirs[0].text ?? ""), .blob(theirs[1].blob ?? Data())])

    let store = try open(old.directory, keys: keys)
    #expect(store.isFormatFinished)
    #expect(store.formatStatus.unreadable == 1)
    #expect(try store.item(id: "theirs") == nil)

    keys.add(try #require(try other.key(id: "ffff")), id: "ffff")
    // It opens, though the store finished and it's format 1: it's on the sealed list.
    #expect(try store.item(id: "theirs")?.fields["a"]?.stringValue == "b")
    #expect(try store.catchUp() == ["theirs"])
    #expect(try format1Rows(store) == 0)
    #expect(store.formatStatus.unreadable == 0)
    #expect(try store.item(id: "theirs")?.kind == "login")
  }

  @Test func aStoreWithNoKeysYetWaitsAndKeepsReading() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let empty = MemoryKeyProvider(keys: [:])
    let store = try open(old.directory, keys: empty)
    #expect(!store.isFormatFinished)
    #expect(store.formatStatus.backup == nil)
    #expect(empty.allKeys.isEmpty)

    let later = try open(old.directory, keys: keys)
    #expect(later.isFormatFinished)
  }

  @Test func accountsMigrateInTheirOwnFile() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let personal = try open(directory, keys: keys)
    _ = personal
    // An old build's account store: the same tables under another name.
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("server")])
    try FileManager.default.copyItem(
      at: old.directory.appendingPathComponent(VaultStore.fileName), to: directory.appendingPathComponent("acme.sqlite"))
    for suffix in ["-wal", "-shm"] {
      try? FileManager.default.copyItem(
        at: old.directory.appendingPathComponent(VaultStore.fileName + suffix),
        to: directory.appendingPathComponent("acme.sqlite" + suffix))
    }
    let account = try open(directory, keys: keys, fileName: "acme.sqlite", account: "acme")
    #expect(account.isFormatFinished)
    #expect(try account.item(id: "h")?.fields["name"]?.stringValue == "server")
    #expect(account.formatStatus.backup?.lastPathComponent == "acme.sqlite.format1-backup")
  }

  // MARK: Interrupted

  /// A copy of the files taken at each step, as a kill at that moment would leave them. A real kill can land inside
  /// SQLite's own commit too, which is SQLite's to survive; this covers every point between transactions, and a killed
  /// transaction leaves no more than the previous step did.
  @Test func anInterruptedMigrationFinishesFromEveryStep() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys, rows: 20)
    let directory = old.directory
    let images = temporaryDirectory()
    let names = LockedList()
    let testing = FormatTesting(
      stage: { stage in
        let name = "\(stage)"
        names.append(name)
        try copyStoreFiles(of: directory, to: images.appendingPathComponent(name))
      }, batchSize: 7)
    _ = try open(directory, keys: keys, testing: testing)

    #expect(names.values.contains("backedUp"))
    #expect(names.values.contains("batch(1)"))
    #expect(names.values.contains("batch(3)"))
    #expect(names.values.contains("beforeFinish"))
    #expect(names.values.contains("finished"))
    #expect(names.values.count >= 6)

    for name in names.values {
      let image = images.appendingPathComponent(name)
      // A fresh keychain each time, so no mark from the run above helps.
      let reopened = try open(image, keys: keysCopy(keys))
      #expect(reopened.isFormatFinished, "\(name)")
      #expect(try format1Rows(reopened) == 0, "\(name)")
      try expectEverythingReadable(reopened, rows: 20)
      #expect(try reopened.pendingCount() == everyKind.count + 20, "\(name)")
      #expect(reopened.formatStatus.backup != nil, "\(name)")
      let backup = try SQLiteConnection(url: reopened.formatBackupURL)
      let inBackup = try backup.query("SELECT COUNT(*) FROM items WHERE substr(payload, 1, 5) != x'5635374902'")[0][0].int
      #expect(inBackup == Int64(everyKind.count + 20), "\(name)")
    }
  }

  private struct Stop: Error {}

  @Test func aFailureAtAnyStepLeavesEverythingReadableAndTheNextOpenFinishes() throws {
    let stages: [FormatTesting.Stage] = [.backedUp, .batch(1), .batch(2), .beforeFinish, .finished]
    for target in stages {
      let keys = MemoryKeyProvider()
      let old = try oldStore(keys: keys, rows: 20)
      let testing = FormatTesting(
        stage: { stage in
          if stage == target { throw Stop() }
        }, batchSize: 7)
      let stopped = try open(old.directory, keys: keys, testing: testing)
      if target != .finished {
        #expect(!stopped.isFormatFinished, "\(target)")
        #expect(stopped.formatStatus.error != nil, "\(target)")
      }
      // Half moved over: both formats read.
      try expectEverythingReadable(stopped, rows: 20)
      // And it can be written to.
      try stopped.save(id: "id-host", kind: "host", changes: ["more": .string("x")])

      let again = try open(old.directory, keys: keys)
      #expect(again.isFormatFinished, "\(target)")
      #expect(try format1Rows(again) == 0)
      try expectEverythingReadable(again, rows: 20)
      #expect(try again.item(id: "id-host")?.fields["more"]?.stringValue == "x")
    }
  }

  @Test func aDiskFullBackupStopsBeforeAnythingIsRewritten() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let before = try old.database.query("SELECT payload FROM items ORDER BY id").map(\.[0].blob)
    // A folder that takes no new files makes the copy fail, as a full disk would.
    let backup = URL(fileURLWithPath: old.directory.appendingPathComponent(VaultStore.fileName).path + VaultStore.formatBackupSuffix)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: old.directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.directory.path) }
    let store = try open(old.directory, keys: keys)
    #expect(!store.isFormatFinished)
    #expect(store.formatStatus.error != nil)
    #expect(!FileManager.default.fileExists(atPath: backup.path))
    let after = try old.database.query("SELECT payload FROM items ORDER BY id").map(\.[0].blob)
    #expect(after == before)
    try expectEverythingReadable(store)
  }

  @Test func concurrentOpensTakeTurnsAndRewriteEachRowOnce() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys, rows: 300)
    let directory = old.directory
    let failures = LockedList()
    DispatchQueue.concurrentPerform(iterations: 4) { index in
      do {
        let store = try open(directory, keys: keys, testing: FormatTesting(batchSize: 25))
        if !store.isFormatFinished { failures.append("\(index) didn't finish: \(store.formatStatus.error ?? "")") }
      } catch {
        failures.append("\(index): \(error)")
      }
    }
    #expect(failures.values.isEmpty, "\(failures.values)")
    let store = try open(directory, keys: keys)
    try expectEverythingReadable(store, rows: 300)
    #expect(store.formatStatus.resealed == everyKind.count + 300)
    let versions = try store.database.query("SELECT MAX(version) FROM items")[0][0].int
    #expect(versions == 2)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
    #expect(leftovers.isEmpty)
  }

  // MARK: One way

  @Test func beforeItFinishesAStoreReadsFormat1AndAfterItRefusesIt() throws {
    let keys = MemoryKeyProvider()
    let clock = TestClock()
    let testing = FormatTesting(now: { clock.now })
    let directory = temporaryDirectory()
    let fresh = try open(directory, keys: keys, testing: testing)
    #expect(!fresh.isFormatFinished)

    var fields = ItemFields()
    _ = fields.apply(["name": .string("from an old build")], clock: HybridClock.zero.next(now: .now, device: "b"))
    let first = try OldBuildStore.format1(id: "first", kind: "host", fields: fields, keys: keys)
    #expect(
      try fresh.apply(RemoteRecord(id: "first", keyID: first.keyID, payload: first.payload, changeTag: "t1", systemFields: nil))
        == .merged(needsSend: false))
    #expect(try fresh.item(id: "first")?.kind == "host")

    // The next open within the hour leaves it reading: the first fetch may still be under way.
    clock.advance(1800)
    #expect(try open(directory, keys: keys, testing: testing).isFormatFinished == false)
    // After it, it finishes, with what it took.
    clock.advance(1801)
    let finished = try open(directory, keys: keys, testing: testing)
    #expect(finished.isFormatFinished)
    #expect(try finished.item(id: "first")?.fields["name"]?.stringValue == "from an old build")
    #expect(try format1Rows(finished) == 0)

    let second = try OldBuildStore.format1(id: "second", kind: "host", fields: fields, keys: keys)
    #expect(
      try finished.apply(RemoteRecord(id: "second", keyID: second.keyID, payload: second.payload, changeTag: "t2", systemFields: nil))
        == .refused(needsSend: false))
    #expect(try finished.item(id: "second") == nil)
    #expect(try finished.allIDs().contains("second") == false)
    #expect(try finished.applyFromPeer(id: "second", keyID: second.keyID, payload: second.payload) == .refused)
    #expect(try finished.item(id: "second") == nil)
    #expect(finished.formatStatus.refused == 2)
  }

  @Test func aNewStoreIsBornFinishedOnceAnyDeviceFinished() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let store = try open(old.directory, keys: keys)
    #expect(store.isFormatFinished)

    // A second device, with what iCloud Keychain brought: the keys and the synced mark.
    let other = keysCopy(keys)
    other.items.receive(from: keys.items)
    let born = try open(temporaryDirectory(), keys: other, device: "pad")
    // The mark names the device that set it; the same store on another device takes the next path.
    #expect(born.isFormatFinished == false)
    let sameDevice = try open(temporaryDirectory(), keys: other, device: "mac")
    #expect(sameDevice.isFormatFinished)
  }

  @Test func editingTheFileDoesntUndoIt() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let store = try open(old.directory, keys: keys)
    #expect(store.isFormatFinished)
    // Someone clears the flag and puts an old row back, from the backup.
    let backup = try SQLiteConnection(url: store.formatBackupURL)
    let oldPayload = try backup.query("SELECT key_id, payload FROM items WHERE id = 'id-host'")[0]
    try store.database.query("DELETE FROM meta WHERE key = 'format'")
    try store.database.query(
      "UPDATE items SET payload = ?, key_id = ? WHERE id = 'id-host'", [.blob(oldPayload[1].blob ?? Data()), .text(oldPayload[0].text ?? "")])

    let again = try open(old.directory, keys: keys)
    #expect(again.isFormatFinished)
    #expect(try again.item(id: "id-host") == nil)
    // Not gone: the row is there, for the backup's sake, and CloudKit is asked for everything again.
    #expect(try again.allIDs().contains("id-host"))
  }

  @Test func aSingleOldRowPlantedInAFinishedStoreIsRefused() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let store = try open(old.directory, keys: keys)
    let planted = try OldBuildStore.format1(id: "x", kind: "host", fields: ItemFields(), keys: keys)
    try store.database.query(
      "INSERT INTO items(id, kind, key_id, payload) VALUES('x', 'host', ?, ?)", [.text(planted.keyID), .blob(planted.payload)])
    #expect(try store.item(id: "x") == nil)
    #expect(try store.items(kind: "host").map(\.id).contains("x") == false)
    // A save replaces it rather than failing forever.
    try store.save(id: "x", kind: "host", changes: ["a": .string("b")])
    #expect(try store.item(id: "x")?.fields["a"]?.stringValue == "b")
  }

  // MARK: Attacks

  private func twoHosts() throws -> (VaultStore, MemoryKeyProvider) {
    let keys = MemoryKeyProvider()
    let store = try open(temporaryDirectory(), keys: keys)
    try store.save(id: "host-a", kind: "host", changes: ["hostname": .string("a.example")])
    try store.save(id: "host-b", kind: "host", changes: ["hostname": .string("b.example")])
    try store.save(id: "known-a", kind: "knownHost", changes: ["fingerprint": .string("SHA256:attacker")])
    return (store, keys)
  }

  @Test func aKnownHostCopiedToAnotherRecordsIDDoesntOpen() throws {
    let (store, _) = try twoHosts()
    let known = try payload(store, "known-a")
    let record = RemoteRecord(id: "host-a", keyID: known.keyID, payload: known.payload, changeTag: "evil", systemFields: nil)
    #expect(try store.apply(record) == .refused(needsSend: true))
    #expect(try store.item(id: "host-a")?.fields["hostname"]?.stringValue == "a.example")
    #expect(try store.item(id: "host-a")?.kind == "host")

    // And to an id the store doesn't have.
    let elsewhere = RemoteRecord(id: "new", keyID: known.keyID, payload: known.payload, changeTag: "evil", systemFields: nil)
    #expect(try store.apply(elsewhere) == .refused(needsSend: false))
    #expect(try store.allIDs().contains("new") == false)
  }

  @Test func swappedHostsDontOpenAndTheRealOnesGoBackUp() throws {
    let (store, _) = try twoHosts()
    let a = try payload(store, "host-a")
    let b = try payload(store, "host-b")
    _ = try store.apply(RemoteRecord(id: "host-a", keyID: b.keyID, payload: b.payload, changeTag: "e1", systemFields: nil))
    _ = try store.apply(RemoteRecord(id: "host-b", keyID: a.keyID, payload: a.payload, changeTag: "e2", systemFields: nil))
    #expect(try store.item(id: "host-a")?.fields["hostname"]?.stringValue == "a.example")
    #expect(try store.item(id: "host-b")?.fields["hostname"]?.stringValue == "b.example")
    #expect(try store.pendingIDs().isSuperset(of: ["host-a", "host-b"]))
  }

  @Test func theSameAttacksFailThroughTheHubPath() throws {
    let (store, _) = try twoHosts()
    let known = try payload(store, "known-a")
    let b = try payload(store, "host-b")
    #expect(try store.applyFromPeer(id: "host-a", keyID: known.keyID, payload: known.payload) == .refused)
    #expect(try store.applyFromPeer(id: "host-a", keyID: b.keyID, payload: b.payload) == .refused)
    #expect(try store.item(id: "host-a")?.fields["hostname"]?.stringValue == "a.example")

    // Through the envelope itself, Sealed{id, keyID, payload}.
    let box = FakeMailbox()
    let sync = HubSync(store: store, mailbox: box.device("this"), deviceID: "this")
    let sealed = HubSync.Sealed(id: "host-a", keyID: known.keyID, payload: known.payload)
    _ = box.join("hub-attacker")
    _ = box.push(
      "hub-attacker",
      [HubEnvelope(id: "x", payload: try JSONEncoder().encode(sealed).base64EncodedString())])
    let result = try awaitResult { try await sync.sync() }
    #expect(result.received == 0)
    #expect(try store.item(id: "host-a")?.fields["hostname"]?.stringValue == "a.example")
  }

  @Test func aPayloadFromAnotherStoreDoesntOpen() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let personal = try open(directory, keys: keys)
    let account = try open(directory, keys: keys, fileName: "acme.sqlite", account: "acme")
    try personal.save(id: "same-id", kind: "host", changes: ["hostname": .string("personal")])
    let sealed = try payload(personal, "same-id")
    #expect(
      try account.apply(RemoteRecord(id: "same-id", keyID: sealed.keyID, payload: sealed.payload, changeTag: "e", systemFields: nil))
        == .refused(needsSend: false))
    #expect(try account.item(id: "same-id") == nil)
  }

  @Test func aChangedHeaderDoesntOpen() throws {
    let (store, _) = try twoHosts()
    var sealed = try payload(store, "host-a").payload
    // The kind box's first byte.
    let parsed = try #require(VaultItemSeal.parse(sealed))
    sealed[sealed.count - parsed.body.count - 1] ^= 1
    #expect(
      try store.apply(RemoteRecord(id: "host-a", keyID: parsed.keyID, payload: sealed, changeTag: "e", systemFields: nil))
        == .refused(needsSend: true))
    #expect(try store.item(id: "host-a")?.fields["hostname"]?.stringValue == "a.example")
  }

  @Test func theKindIsNotInTheClearAndItsLengthIsHidden() throws {
    let keys = MemoryKeyProvider()
    let store = try open(temporaryDirectory(), keys: keys)
    try store.save(id: "a", kind: "knownHost", changes: ["v": .string("x")])
    try store.save(id: "b", kind: "host", changes: ["v": .string("x")])
    let a = try #require(VaultItemSeal.parse(try payload(store, "a").payload))
    let b = try #require(VaultItemSeal.parse(try payload(store, "b").payload))
    #expect(a.sealedKind.count == b.sealedKind.count)
    #expect(!(try payload(store, "a").payload).contains(Data("knownHost".utf8)))
  }

  /// The recovery record key comes from the public key, which an ex-device keeps. It seals blobs and nothing else.
  @Test func theRecoveryRecordKeyOpensBlobsAndNothingElse() throws {
    let keys = MemoryKeyProvider()
    let store = try open(temporaryDirectory(), keys: keys)
    let publicKey = RecoverySecret.random().publicKey
    let recordKey = VaultRecoveryKey(publicKey: publicKey).recordKey
    store.useKey(recordKey.key, id: recordKey.id, sealing: VaultRecoveryBlob.kind)
    var fields = ItemFields()
    _ = fields.apply(["hostname": .string("evil")], clock: HybridClock.zero.next(now: .now, device: "x"))
    let body = try JSONEncoder().encode(fields)
    let forged = try VaultItemSeal.seal(
      kind: "host", fields: body, id: "h", account: "personal", keyID: recordKey.id, key: recordKey.key)
    #expect(
      try store.apply(RemoteRecord(id: "h", keyID: recordKey.id, payload: forged, changeTag: "e", systemFields: nil))
        == .refused(needsSend: false))
    let blob = try VaultItemSeal.seal(
      kind: VaultRecoveryBlob.kind, fields: body, id: "b", account: "personal", keyID: recordKey.id, key: recordKey.key)
    #expect(
      try store.apply(RemoteRecord(id: "b", keyID: recordKey.id, payload: blob, changeTag: "e", systemFields: nil))
        == .merged(needsSend: false))
  }

  @Test func aRecordNamingAKeyThisDeviceLacksDoesntBlankAReadableRow() throws {
    let (store, _) = try twoHosts()
    let other = SymmetricKey(size: .bits256)
    var fields = ItemFields()
    _ = fields.apply(["hostname": .string("newer")], clock: HybridClock.zero.next(now: .now.addingTimeInterval(100), device: "x"))
    let sealed = try VaultItemSeal.seal(
      kind: "host", fields: try JSONEncoder().encode(fields), id: "host-a", account: "personal", keyID: "ffff", key: other)
    #expect(
      try store.apply(RemoteRecord(id: "host-a", keyID: "ffff", payload: sealed, changeTag: "t", systemFields: nil))
        == .undecryptable)
    #expect(try store.item(id: "host-a")?.fields["hostname"]?.stringValue == "a.example")

    // The key arrives: the waiting copy merges.
    (store.keys as! MemoryKeyProvider).add(other, id: "ffff")
    #expect(try store.catchUp() == ["host-a"])
    #expect(try store.item(id: "host-a")?.fields["hostname"]?.stringValue == "newer")
  }

  // MARK: Devices updating at different times

  /// A has updated, B hasn't, and both go on editing. Nothing is lost when B updates.
  @Test func twoDevicesConvergeWhenOneUpdatesLater() throws {
    let cloud = FakeCloud()
    let keysA = MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(size: .bits256)])
    let keysB = MemoryKeyProvider(keys: keysA.allKeys)
    let oldA = try OldBuildStore(keys: keysA, device: "a")
    let oldB = try OldBuildStore(keys: keysB, device: "b")
    try oldA.save(id: "shared", kind: "login", changes: ["user": .string("from a"), "notes": .string("start")])
    try oldA.save(id: "edited-before-a-pushed", kind: "login", changes: ["v": .string("start")])
    try oldA.push(cloud)
    try oldB.pull(cloud)
    #expect(oldB.read("shared")?.fields["user"]?.stringValue == "from a")

    // A updates, but B's edit reaches the server first.
    let appA = try FakeApp(directory: oldA.directory, keys: keysA, device: "a", name: "A")
    #expect(appA.store.isFormatFinished)
    try oldB.save(id: "edited-before-a-pushed", kind: "login", changes: ["byB": .string("kept")])
    try oldB.push(cloud)

    // A's push meets B's format 1 record: it refuses it and puts its format 2 copy over it.
    appA.sync(cloud)
    #expect(try appA.store.item(id: "edited-before-a-pushed")?.fields["byB"] == nil)
    #expect(try format1Rows(appA.store) == 0)
    #expect(cloud.records.values.allSatisfy { VaultItemSeal.parse($0.payload) != nil })

    // B, still old, sees nothing of it: its row stays readable and its edit stays with it.
    try oldB.pull(cloud)
    #expect(oldB.read("shared")?.fields["user"]?.stringValue == "from a")
    #expect(oldB.read("edited-before-a-pushed")?.fields["byB"]?.stringValue == "kept")

    // B writes on. A new record reaches the server in format 1, which A refuses and remembers as seen.
    try oldB.save(id: "new-from-b", kind: "note", changes: ["text": .string("hello")])
    try oldB.save(id: "shared", kind: "login", changes: ["notes": .string("from b")])
    try oldB.push(cloud)
    #expect(cloud.records["new-from-b"].map { VaultItemSeal.parse($0.payload) == nil } == true)
    // The edit of `shared` can't land on A's format 2 copy: it waits in B's outbox.
    #expect(oldB.pending >= 1)
    appA.sync(cloud)
    #expect(try appA.store.item(id: "new-from-b") == nil)
    #expect(appA.store.formatStatus.refused >= 1)
    try appA.store.save(id: "shared", kind: "login", changes: ["user": .string("from a again")])
    appA.sync(cloud)

    // B updates. Its engine state is gone, so it fetches everything, and everything of its own goes up.
    let appB = try FakeApp(directory: oldB.directory, keys: keysB, device: "b", name: "B")
    #expect(appB.store.isFormatFinished)
    appB.sync(cloud)
    appA.sync(cloud)
    appB.sync(cloud)

    for app in [appA, appB] {
      let shared = try #require(try app.store.item(id: "shared"))
      #expect(shared.fields["user"]?.stringValue == "from a again")
      #expect(shared.fields["notes"]?.stringValue == "from b")
      #expect(try app.store.item(id: "edited-before-a-pushed")?.fields["byB"]?.stringValue == "kept")
      #expect(try app.store.item(id: "new-from-b")?.fields["text"]?.stringValue == "hello")
    }
    #expect(try appA.store.pendingCount() == 0)
    #expect(try appB.store.pendingCount() == 0)
    #expect(cloud.records.values.allSatisfy { VaultItemSeal.parse($0.payload) != nil })
  }

  // MARK: What an old build does

  /// Why format 2 records carry no `keyID` field: given one, the old build stores what it can't read over its own row.
  @Test func anOldBuildGivenAKeyIDWouldBlankItsRow() throws {
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "b")
    try old.save(id: "h", kind: "host", changes: ["hostname": .string("server")])
    try old.database.query("DELETE FROM outbox")
    let writer = try open(temporaryDirectory(), keys: keys, device: "a")
    try writer.save(id: "h", kind: "host", changes: ["hostname": .string("server")])
    let sealed = try payload(writer, "h")

    try old.apply(RemoteRecord(id: "h", keyID: sealed.keyID, payload: sealed.payload, changeTag: "t", systemFields: nil))
    #expect(old.read("h") == nil)
  }

  @Test func anOldBuildSkipsFormat2RecordsAndKeepsItsRows() throws {
    let cloud = FakeCloud()
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "b")
    try old.save(id: "h", kind: "host", changes: ["hostname": .string("server")])
    try old.push(cloud)

    let app = try FakeApp(directory: temporaryDirectory(), keys: keys, device: "a", name: "A")
    app.pull(cloud)
    try app.store.save(id: "h", kind: "host", changes: ["port": .int(22)])
    try app.store.save(id: "new", kind: "host", changes: ["hostname": .string("other")])
    app.sync(cloud)

    try old.pull(cloud)
    #expect(old.read("h")?.fields["hostname"]?.stringValue == "server")
    #expect(try old.database.query("SELECT 1 FROM items WHERE id = 'new'").isEmpty)
    // Its edit of the record waits for the update instead of landing on the new copy.
    try old.save(id: "h", kind: "host", changes: ["note": .string("edit")])
    try old.push(cloud)
    #expect(old.pending == 1)
    #expect(VaultItemSeal.parse(try #require(cloud.records["h"]).payload) != nil)
  }

  @Test func anOldBuildGetsNothingFromAFormat2Envelope() throws {
    let keys = MemoryKeyProvider()
    let writer = try open(temporaryDirectory(), keys: keys, device: "a")
    try writer.save(id: "h", kind: "host", changes: ["hostname": .string("server")])
    let sealed = try payload(writer, "h")
    // `applyFromPeer` at c4ba614 is `guard let remote = try? decode(...)`, the same decode.
    #expect(throws: (any Error).self) {
      try VaultCrypto.open(sealed.payload, keyID: sealed.keyID, keys: keys)
    }
  }

  // MARK: Hub

  /// B acknowledged what A sent while it was an old build, without being able to read it.
  @Test func aDeviceThatUpdatesAsksTheOthersToSendAgain() throws {
    let keys = MemoryKeyProvider()
    let box = FakeMailbox()
    let storeA = try open(temporaryDirectory(), keys: keys, device: "a")
    try storeA.save(id: "h", kind: "host", changes: ["hostname": .string("from a")])
    let syncA = HubSync(store: storeA, mailbox: box.device("hub-a"), deviceID: "hub-a")

    let oldB = try OldBuildStore(keys: keys, device: "b")
    try oldB.save(id: "b1", kind: "host", changes: ["hostname": .string("from b")])
    _ = box.join("hub-b")
    try awaitVoid { _ = try await syncA.sync() }
    // B's old build pulls, can't read, acknowledges.
    let pulled = box.pull("hub-b", 0, 100)
    #expect(!pulled.envelopes.isEmpty)
    box.ack("hub-b", pulled.envelopes.map(\.seq).max() ?? 0)

    let storeB = try open(oldB.directory, keys: keys, device: "b")
    #expect(storeB.isFormatFinished)
    let syncB = HubSync(store: storeB, mailbox: box.device("hub-b"), deviceID: "hub-b")
    // Its state says it pulled everything; the old build kept its own.
    try storeB.setEngineState(
      try JSONEncoder().encode(HubSync.State(pulled: pulled.envelopes.map(\.seq).max() ?? 0, members: ["hub-a", "hub-b"])),
      for: "hub-sync:hub-b")
    try awaitVoid { _ = try await syncB.sync() }
    try awaitVoid { _ = try await syncA.sync() }
    try awaitVoid { _ = try await syncB.sync() }

    #expect(try storeB.item(id: "h")?.fields["hostname"]?.stringValue == "from a")
    #expect(try storeA.item(id: "b1")?.fields["hostname"]?.stringValue == "from b")
  }
}

final class LockedList: @unchecked Sendable {
  private let lock = NSLock()
  private var list: [String] = []
  var values: [String] { lock.withLock { list } }
  func append(_ value: String) { lock.withLock { list.append(value) } }
}

final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date.now
  var now: Date { lock.withLock { date } }
  func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

/// Runs async work from a synchronous test.
func awaitResult<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
  let semaphore = DispatchSemaphore(value: 0)
  let box = LockedBox<Result<T, Error>>()
  Task {
    do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
    semaphore.signal()
  }
  semaphore.wait()
  return try box.value!.get()
}

func awaitVoid(_ work: @escaping @Sendable () async throws -> Void) throws {
  try awaitResult(work)
}

final class LockedBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: T?
  var value: T? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
