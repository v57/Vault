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

    #expect(store.fileURL.lastPathComponent == "Vault.v2.sqlite")
    #expect(!store.isWaitingToMigrate)
    #expect(try format1Rows(store) == 0)
    try expectEverythingReadable(store, rows: 5)
    let status = store.formatStatus
    #expect(status.resealed == everyKind.count + 5)
    #expect(status.unreadable == 0)
    #expect(status.error == nil)
    // It hasn't seen the server yet.
    #expect(!status.isFinished)
    // Everything goes up, so the other devices get format 2.
    #expect(try store.pendingCount() == everyKind.count + 5)
  }

  @Test func theOldFileIsNeverWritten() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys, rows: 5)
    let dump = {
      try ["SELECT id, version, payload, change_tag, modified FROM items ORDER BY id", "SELECT id, version FROM outbox ORDER BY id", "SELECT key, value FROM meta ORDER BY key"]
        .map { "\(try old.database.query($0))" }
    }
    let before = try dump()

    let store = try open(old.directory, keys: keys)
    try store.save(id: "id-host", kind: "host", changes: ["port": .int(22)])
    try store.delete(id: "id-login")
    _ = try store.catchUp()
    _ = try open(old.directory, keys: keys)

    #expect(try dump() == before)
  }

  @Test func nothingOpensAnOldFileForWriting() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let store = try open(directory, keys: keys, fileName: "Vault.sqlite")
    #expect(store.fileURL.lastPathComponent == "Vault.v2.sqlite")
    let account = try open(directory, keys: keys, fileName: "acme.sqlite", account: "acme")
    #expect(account.fileURL.lastPathComponent == "acme.v2.sqlite")
    #expect(account.legacyFileURL.lastPathComponent == "acme.sqlite")
  }

  @Test func removingAStoreRemovesBothFilesAndWhatAKillLeft() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let store = try open(old.directory, keys: keys)
    let leftover = old.directory.appendingPathComponent("Vault.v2.sqlite.ABC.tmp")
    try Data("x".utf8).write(to: leftover)
    VaultStore.removeFiles(at: store.fileURL)
    let names = try FileManager.default.contentsOfDirectory(atPath: old.directory.path)
    #expect(names.isEmpty, "\(names)")
  }

  @Test func tombstonesAndBookkeepingMoveOver() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let cloud = FakeCloud()
    try old.push(cloud)
    try old.delete(id: "id-login")
    let row = try old.database.query("SELECT change_tag, system_fields, version FROM items WHERE id = 'id-host'")[0]
    let clock = try old.database.query("SELECT value FROM meta WHERE key = 'clock'")[0][0].text
    let store = try open(old.directory, keys: keys)
    #expect(try store.item(id: "id-login")?.isDeleted == true)
    #expect(try store.items(kind: "login").isEmpty)
    let moved = try store.database.query("SELECT change_tag, system_fields, version FROM items WHERE id = 'id-host'")[0]
    #expect(moved[0].text == row[0].text)
    #expect(moved[1].blob == row[1].blob)
    #expect(moved[2].int == (row[2].int ?? 0) + 1)
    #expect(try store.meta("clock") == clock)
  }

  @Test func fieldsAndClocksComeOverExactly() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    try old.save(id: "id-host", kind: "host", changes: ["later": .string("x")])
    let before = try #require(old.read("id-host"))
    let store = try open(old.directory, keys: keys)
    #expect(try store.item(id: "id-host")?.fields == before.fields)
  }

  @Test func whatAnEngineFetchedIsAskedForAgainButHubStateStays() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    try old.database.query("INSERT INTO engines(name, state) VALUES('dev.v57.app', x'01'), ('hub-sync:abc', x'02')")
    try old.database.query("INSERT INTO engines(name, state) VALUES('dev.v57.app.subscription', x'03')")
    let store = try open(old.directory, keys: keys)
    #expect(try store.engineState("dev.v57.app") == nil)
    #expect(try store.engineState("hub-sync:abc") == Data([2]))
    #expect(try store.engineState("dev.v57.app.subscription") == Data([3]))
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
    store.fetchCompleted()
    #expect(store.isFormatFinished)
    #expect(store.formatStatus.unreadable == 1)
    #expect(try store.item(id: "theirs") == nil)
    #expect(try format1Rows(store) == 1)
    // A row that came over unopened never goes up in format 1.
    #expect(try store.outgoing(id: "theirs") == nil)

    keys.add(try #require(try other.key(id: "ffff")), id: "ffff")
    // It opens, though the store finished and it's format 1: it's on the sealed list.
    #expect(try store.item(id: "theirs")?.fields["a"]?.stringValue == "b")
    #expect(try store.catchUp() == ["theirs"])
    #expect(try format1Rows(store) == 0)
    #expect(store.formatStatus.unreadable == 0)
    #expect(try store.item(id: "theirs")?.kind == "login")
  }

  /// Keys haven't arrived on this device: it keeps the old file, which an old app can go on using too.
  @Test func aStoreWithNoKeysYetWaitsReadsAndThenMigrates() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let empty = MemoryKeyProvider(keys: [:])
    let store = try open(old.directory, keys: empty)
    #expect(store.isWaitingToMigrate)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(empty.allKeys.isEmpty)
    #expect(store.formatStatus.error == nil)
    #expect(try store.pendingIDs().isEmpty == false)
    #expect(try store.claimOutbox().isEmpty)
    // Nothing from elsewhere goes in the old file.
    var fields = ItemFields()
    _ = fields.apply(["a": .string("b")], clock: HybridClock.zero.next(now: .now, device: "pad"))
    let record = try OldBuildStore.format1(id: "n", kind: "host", fields: fields, keys: keys)
    #expect(throws: (any Error).self) {
      try store.apply(RemoteRecord(id: "n", keyID: record.keyID, payload: record.payload, changeTag: "t", systemFields: nil))
    }
    #expect(try old.database.query("SELECT 1 FROM items WHERE id = 'n'").isEmpty)

    // The keys arrive, and the same store carries on.
    try empty.addKeys(keys.allKeys)
    #expect(try store.catchUp().isEmpty)
    #expect(!store.isWaitingToMigrate)
    #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    try expectEverythingReadable(store)
  }

  @Test func aKeychainOutOfReachReadsNothingWrongAndBuildsNothing() throws {
    let base = MemoryKeyProvider()
    let old = try oldStore(keys: base)
    let keys = FlakyKeys(base)
    keys.failing = true
    let store = try open(old.directory, keys: keys)
    #expect(store.isWaitingToMigrate)
    #expect(store.formatStatus.error != nil)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(throws: (any Error).self) { try store.save(id: "x", kind: "host", changes: ["a": .string("b")]) }
    #expect(try old.database.query("SELECT 1 FROM items WHERE id = 'x'").isEmpty)

    keys.failing = false
    #expect(try store.item(id: "id-host")?.fields["name"]?.stringValue == "host")
    try store.save(id: "x", kind: "host", changes: ["a": .string("b")])
    #expect(!store.isWaitingToMigrate)
    #expect(try store.item(id: "x")?.fields["a"]?.stringValue == "b")
    try expectEverythingReadable(store)
    #expect(try old.database.query("SELECT 1 FROM items WHERE id = 'x'").isEmpty)
  }

  /// A write on an empty keychain makes a key, as it always did. The rows that came over wait for the real one, and no
  /// id is made until it's here: it would be wrong.
  @Test func aWriteWithNoKeysKeepsTheRowsAndTheWrite() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let empty = MemoryKeyProvider(keys: [:])
    let store = try open(old.directory, keys: empty)
    #expect(throws: VaultCrypto.CryptoError.self) { try store.derivedID("x") }

    try store.save(id: "typed", kind: "host", changes: ["a": .string("b")])
    #expect(!store.isWaitingToMigrate)
    #expect(try store.item(id: "typed")?.fields["a"]?.stringValue == "b")
    #expect(store.formatStatus.unreadable == everyKind.count)
    #expect(throws: VaultCrypto.CryptoError.self) { try store.derivedID("x") }

    try empty.addKeys(keys.allKeys)
    #expect(try store.catchUp().count == everyKind.count)
    try expectEverythingReadable(store)
    #expect(try store.item(id: "typed")?.fields["a"]?.stringValue == "b")
    #expect(try store.derivedID("x") == VaultCrypto.derivedID("x", keys: keys))
  }

  @Test func accountsMigrateInTheirOwnFile() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let personal = try open(directory, keys: keys)
    _ = personal
    // An old build's account store: the same tables under another name.
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("server")])
    try old.database.checkpointFully()
    try FileManager.default.copyItem(
      at: old.directory.appendingPathComponent(OldBuildStore.fileName), to: directory.appendingPathComponent("acme.sqlite"))
    let account = try open(directory, keys: keys, fileName: "acme.sqlite", account: "acme")
    #expect(!account.isWaitingToMigrate)
    #expect(account.fileURL.lastPathComponent == "acme.v2.sqlite")
    #expect(try account.item(id: "h")?.fields["name"]?.stringValue == "server")
  }

  // MARK: Interrupted

  /// A copy of the files taken at each step, as a power cut at that moment could leave them. `VaultStoreCrashTests` kills
  /// a real process too.
  @Test func anInterruptedMigrationFinishesFromEveryStep() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys, rows: 20)
    let directory = old.directory
    let images = temporaryDirectory()
    let names = LockedList()
    let testing = FormatTesting(stage: { stage in
      let name = "\(stage)"
      names.append(name)
      try copyStoreFiles(of: directory, to: images.appendingPathComponent(name))
    })
    _ = try open(directory, keys: keys, testing: testing)
    #expect(names.values == ["copied", "beforeMove", "moved"])

    for name in names.values {
      let image = images.appendingPathComponent(name)
      let reopened = try open(image, keys: keysCopy(keys))
      #expect(!reopened.isWaitingToMigrate, "\(name)")
      #expect(try format1Rows(reopened) == 0, "\(name)")
      try expectEverythingReadable(reopened, rows: 20)
      #expect(try reopened.pendingCount() == everyKind.count + 20, "\(name)")
    }
  }

  private struct Stop: Error {}

  @Test func aFailureAtAnyStepLeavesEverythingReadableAndTheNextOpenFinishes() throws {
    for target in [FormatTesting.Stage.copied, .beforeMove] {
      let keys = MemoryKeyProvider()
      let old = try oldStore(keys: keys, rows: 20)
      let testing = FormatTesting(stage: { stage in
        if stage == target { throw Stop() }
      })
      let stopped = try open(old.directory, keys: keys, testing: testing)
      #expect(stopped.isWaitingToMigrate, "\(target)")
      #expect(stopped.formatStatus.error != nil, "\(target)")
      #expect(!FileManager.default.fileExists(atPath: stopped.fileURL.path), "\(target)")
      // Its temporary file went, and every row still reads, from the old file.
      let names = try FileManager.default.contentsOfDirectory(atPath: old.directory.path)
      #expect(names.allSatisfy { !$0.contains(".tmp") }, "\(names)")
      try expectEverythingReadable(stopped, rows: 20)
      // A write fails rather than touching the old file or getting lost.
      #expect(throws: Stop.self) { try stopped.save(id: "id-host", kind: "host", changes: ["more": .string("x")]) }

      let again = try open(old.directory, keys: keys)
      #expect(!again.isWaitingToMigrate, "\(target)")
      #expect(try format1Rows(again) == 0)
      try expectEverythingReadable(again, rows: 20)
    }
  }

  @Test func aFullDiskLeavesTheOldFileReadable() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let before = try old.database.query("SELECT payload FROM items ORDER BY id").map(\.[0].blob)
    // A folder that takes no new files makes the build fail, as a full disk would.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: old.directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.directory.path) }
    let store = try open(old.directory, keys: keys)
    #expect(store.isWaitingToMigrate)
    #expect(store.formatStatus.error != nil)
    let after = try old.database.query("SELECT payload FROM items ORDER BY id").map(\.[0].blob)
    #expect(after == before)
    try expectEverythingReadable(store)
  }

  @Test func concurrentOpensGetOneWinner() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys, rows: 300)
    let directory = old.directory
    let failures = LockedList()
    DispatchQueue.concurrentPerform(iterations: 4) { index in
      do {
        let store = try open(directory, keys: keys)
        if store.isWaitingToMigrate { failures.append("\(index) waits: \(store.formatStatus.error ?? "")") }
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
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".tmp") }
    #expect(leftovers.isEmpty, "\(leftovers)")
  }

  @Test func whatAKillLeftGoesOnceItsOldEnough() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let clock = TestClock()
    let testing = FormatTesting(now: { clock.now })
    let leftover = directory.appendingPathComponent("Vault.v2.sqlite.ABC.tmp")
    try Data("x".utf8).write(to: leftover)
    _ = try open(directory, keys: keys, testing: testing)
    #expect(FileManager.default.fileExists(atPath: leftover.path))
    clock.advance(3600)
    _ = try open(directory, keys: keys, testing: testing)
    #expect(!FileManager.default.fileExists(atPath: leftover.path))
  }

  // MARK: An old app beside a new one, on one device

  /// Finding 1a: the old app's fetch never touches the new file, so an unsent edit there stays.
  @Test func anOldAppsFetchDoesntTouchTheNewApp() throws {
    let cloud = FakeCloud()
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("x")])
    try old.push(cloud)
    let other = try OldBuildStore(keys: keysCopy(keys), device: "pad")
    try other.pull(cloud)
    let app = try FakeApp(directory: old.directory, keys: keys, device: "mac", name: "new")
    try app.store.save(id: "h", kind: "host", changes: ["port": .int(22)])
    try other.save(id: "h", kind: "host", changes: ["user": .string("pad")])
    try other.push(cloud)
    try old.pull(cloud)
    #expect(try app.store.item(id: "h")?.fields["port"] == .int(22))
    #expect(try app.store.pendingIDs().contains("h"))
    app.sync(cloud)
    #expect(try app.store.item(id: "h")?.fields["user"]?.stringValue == "pad")
    #expect(try app.store.item(id: "h")?.fields["port"] == .int(22))
  }

  /// Finding 1b: nothing an old app sends is format 2, and format 2 records carry no key id.
  @Test func anOldAppNeverSendsFormat2() throws {
    let cloud = FakeCloud()
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("x")])
    _ = try FakeApp(directory: old.directory, keys: keys, device: "mac", name: "new")
    try old.push(cloud)
    #expect(cloud.records.values.allSatisfy { VaultItemSeal.parse($0.payload) == nil })
  }

  /// Both apps syncing on one device, for a while, against a second device on an old build: nothing is lost, and an old
  /// build keeps every row readable.
  @Test func anOldAppAndANewOneSyncSideBySide() throws {
    let cloud = FakeCloud()
    let keys = MemoryKeyProvider()
    let oldApp = try OldBuildStore(keys: keys, device: "mac")
    try oldApp.save(id: "h", kind: "host", changes: ["name": .string("x")])
    try oldApp.push(cloud)
    let pad = try OldBuildStore(keys: keysCopy(keys), device: "pad")
    try pad.pull(cloud)

    let newApp = try FakeApp(directory: oldApp.directory, keys: keys, device: "mac", name: "new")
    newApp.sync(cloud)
    #expect(cloud.records.values.allSatisfy { VaultItemSeal.parse($0.payload) != nil })

    // Each edits, in turn, with everything syncing in between.
    try oldApp.save(id: "h", kind: "host", changes: ["byOldApp": .string("1")])
    try oldApp.save(id: "fromOldApp", kind: "host", changes: ["a": .string("1")])
    try newApp.store.save(id: "h", kind: "host", changes: ["byNewApp": .string("1")])
    try pad.save(id: "h", kind: "host", changes: ["byPad": .string("1")])
    for _ in 0..<3 {
      try oldApp.push(cloud)
      try oldApp.pull(cloud)
      try pad.push(cloud)
      try pad.pull(cloud)
      newApp.sync(cloud)
    }

    // The old builds keep what they had: nothing was blanked, by a key id or otherwise.
    #expect(oldApp.read("h")?.fields["byOldApp"]?.stringValue == "1")
    #expect(pad.read("h")?.fields["byPad"]?.stringValue == "1")

    // The new app picks up the old app's edits on its next open, and sends them.
    let reopened = try FakeApp(directory: oldApp.directory, keys: keys, device: "mac", name: "new")
    #expect(try reopened.store.item(id: "h")?.fields["byOldApp"]?.stringValue == "1")
    #expect(try reopened.store.item(id: "h")?.fields["byNewApp"]?.stringValue == "1")
    #expect(try reopened.store.item(id: "fromOldApp")?.fields["a"]?.stringValue == "1")
    reopened.sync(cloud)
    #expect(try format1Rows(reopened.store) == 0)

    // The pad updates last, and everything converges.
    let padApp = try FakeApp(directory: pad.directory, keys: keysCopy(keys), device: "pad", name: "new")
    padApp.sync(cloud)
    reopened.sync(cloud)
    padApp.sync(cloud)
    for store in [reopened.store, padApp.store] {
      let item = try #require(try store.item(id: "h"))
      for field in ["byOldApp", "byNewApp", "byPad"] { #expect(item.fields[field]?.stringValue == "1", "\(field)") }
      #expect(try store.item(id: "fromOldApp")?.fields["a"]?.stringValue == "1")
    }
    #expect(cloud.records.values.allSatisfy { VaultItemSeal.parse($0.payload) != nil })
  }

  /// Finding 1c, and an old app's deletion.
  @Test func whatAnOldAppWritesLaterComesOverOnce() throws {
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("x")])
    try old.save(id: "gone", kind: "host", changes: ["name": .string("x")])
    let first = try open(old.directory, keys: keys)
    try first.save(id: "h", kind: "host", changes: ["byNew": .string("1")])
    try old.save(id: "later", kind: "host", changes: ["name": .string("y")])
    try old.save(id: "h", kind: "host", changes: ["byOld": .string("1")])
    try old.delete(id: "gone")

    let again = try open(old.directory, keys: keys)
    #expect(try again.item(id: "later")?.fields["name"]?.stringValue == "y")
    #expect(try again.item(id: "h")?.fields["byNew"]?.stringValue == "1")
    #expect(try again.item(id: "h")?.fields["byOld"]?.stringValue == "1")
    #expect(try again.item(id: "gone")?.isDeleted == true)
    #expect(try again.pendingIDs().isSuperset(of: ["later", "h", "gone"]))

    // Imported already: a later edit here isn't undone, and nothing repeats.
    try again.save(id: "later", kind: "host", changes: ["name": .string("newer")])
    let versions = try again.database.query("SELECT version FROM items WHERE id = 'later'")[0][0].int
    let third = try open(old.directory, keys: keys)
    #expect(try third.item(id: "later")?.fields["name"]?.stringValue == "newer")
    #expect(try third.database.query("SELECT version FROM items WHERE id = 'later'")[0][0].int == versions)
  }

  /// An old app can send a brand new row, and the store that should have it would then refuse it.
  @Test func anEditAnOldAppManagedToSendStillComesOver() throws {
    let cloud = FakeCloud()
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("x")])
    let app = try FakeApp(directory: old.directory, keys: keys, device: "mac", name: "new")
    app.sync(cloud)
    try old.save(id: "sent", kind: "host", changes: ["a": .string("1")])
    try old.push(cloud)
    #expect(cloud.records["sent"].map { VaultItemSeal.parse($0.payload) == nil } == true)
    #expect(try old.database.query("SELECT 1 FROM outbox WHERE id = 'sent'").isEmpty)
    let again = try FakeApp(directory: old.directory, keys: keys, device: "mac", name: "new")
    #expect(try again.store.item(id: "sent")?.fields["a"]?.stringValue == "1")
    again.sync(cloud)
    #expect(VaultItemSeal.parse(try #require(cloud.records["sent"]).payload) != nil)
  }

  /// What a row fetched by the old app holds isn't an edit: only CloudKit put it there.
  @Test func whatAnOldAppFetchedDoesntComeOver() throws {
    let cloud = FakeCloud()
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("x")])
    try old.push(cloud)
    let store = try open(old.directory, keys: keys)
    store.fetchCompleted()
    let pad = try OldBuildStore(keys: keysCopy(keys), device: "pad")
    try pad.pull(cloud)
    try pad.save(id: "fromPad", kind: "host", changes: ["a": .string("1")])
    try pad.push(cloud)
    try old.pull(cloud)
    #expect(old.read("fromPad") != nil)
    #expect(try open(old.directory, keys: keys).item(id: "fromPad") == nil)
  }

  @Test func theOldFileIsIgnoredAfterItsMonth() throws {
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("x")])
    let clock = TestClock()
    let testing = FormatTesting(now: { clock.now })
    _ = try open(old.directory, keys: keys, testing: testing)
    try old.save(id: "late", kind: "host", changes: ["a": .string("1")])
    clock.advance(31 * 24 * 3600)
    let store = try open(old.directory, keys: keys, testing: testing)
    #expect(try store.item(id: "late") == nil)
  }

  /// Finding 4: there's no keychain mark to disagree with. Putting the old file back with no new file migrates again.
  @Test func rollingBackMeansRemovingTheNewFile() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let store = try open(old.directory, keys: keys)
    let files = old.directory
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: store.fileURL.path + suffix) }
    let again = try open(files, keys: keys)
    #expect(!again.isWaitingToMigrate)
    try expectEverythingReadable(again)
    #expect(again.formatStatus.resealed == everyKind.count)
  }

  /// Finding 4: every mark any device set says nothing about a store's own rows.
  @Test func aMigratedVaultsMarkDoesntRefuseARestoredOldFile() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let store = try open(old.directory, keys: keys)
    store.fetchCompleted()
    #expect(store.isFormatFinished)

    // The same keychain, and a restored copy of the old file somewhere else.
    let restored = temporaryDirectory()
    try old.database.checkpointFully()
    try FileManager.default.copyItem(
      at: old.directory.appendingPathComponent(OldBuildStore.fileName), to: restored.appendingPathComponent(OldBuildStore.fileName))
    let reopened = try open(restored, keys: keys)
    try expectEverythingReadable(reopened)
    #expect(reopened.formatStatus.refused == 0)
  }

  // MARK: Records from the server in format 1

  private func format1Record(_ id: String, tag: String = "t1", keys: VaultKeyProvider, device: String = "pad", changes: [String: JSONValue] = ["name": .string("from an old build")]) throws -> RemoteRecord {
    var fields = ItemFields()
    _ = fields.apply(changes, clock: HybridClock.zero.next(now: .now, device: device))
    let sealed = try OldBuildStore.format1(id: id, kind: "host", fields: fields, keys: keys)
    return RemoteRecord(id: id, keyID: sealed.keyID, payload: sealed.payload, changeTag: tag, systemFields: Data(tag.utf8))
  }

  @Test func untilItsFirstFetchCompletesAStoreReadsFormat1AndAfterItRefusesIt() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let fresh = try open(directory, keys: keys)
    #expect(!fresh.isFormatFinished)

    #expect(try fresh.apply(try format1Record("first", keys: keys)) == .merged(needsSend: true))
    #expect(try fresh.item(id: "first")?.kind == "host")
    // Sealed for here, and going up as format 2.
    #expect(try format1Rows(fresh) == 0)
    #expect(try fresh.pendingIDs().contains("first"))

    // Reopening doesn't finish it, however long it takes.
    #expect(try open(directory, keys: keys).isFormatFinished == false)
    fresh.fetchCompleted()
    #expect(fresh.isFormatFinished)
    let finished = try open(directory, keys: keys)
    #expect(finished.isFormatFinished)
    #expect(try finished.item(id: "first")?.fields["name"]?.stringValue == "from an old build")

    #expect(try finished.apply(try format1Record("second", tag: "t2", keys: keys)) == .refused(needsSend: false))
    #expect(try finished.item(id: "second") == nil)
    #expect(try finished.allIDs().contains("second") == false)
    #expect(try finished.applyFromPeer(id: "second", keyID: "", payload: try format1Record("second", keys: keys).payload) == .refused)
    #expect(try finished.item(id: "second") == nil)
    #expect(finished.formatStatus.refused == 1)
    #expect(finished.formatStatus.fromOldDevices == 1)
    #expect(finished.formatStatus.note?.contains("hasn’t updated") == true)
  }

  /// Finding 2: an edit on the server when a device migrates merges, rather than being overwritten.
  @Test func anEditWaitingOnTheServerMergesWhenADeviceMigrates() throws {
    let cloud = FakeCloud()
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("x")])
    try old.push(cloud)
    let other = try OldBuildStore(keys: keysCopy(keys), device: "pad")
    try other.pull(cloud)
    try other.save(id: "h", kind: "host", changes: ["user": .string("pad")])
    try other.save(id: "brandnew", kind: "host", changes: ["user": .string("pad")])
    try other.push(cloud)

    let app = try FakeApp(directory: old.directory, keys: keys, device: "mac", name: "new")
    app.sync(cloud)
    #expect(try app.store.item(id: "h")?.fields["user"]?.stringValue == "pad")
    #expect(try app.store.item(id: "h")?.fields["name"]?.stringValue == "x")
    #expect(try app.store.item(id: "brandnew")?.fields["user"]?.stringValue == "pad")
    #expect(app.store.isFormatFinished)
    #expect(cloud.records.values.allSatisfy { VaultItemSeal.parse($0.payload) != nil })
  }

  /// Finding 2: the count survives, and it's counted once however many apps fetch the record.
  @Test func theRefusedCountSurvivesAndCountsEachRecordOnce() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let store = try open(directory, keys: keys)
    store.fetchCompleted()
    _ = try store.apply(try format1Record("n", keys: keys))
    _ = try store.apply(try format1Record("n", keys: keys))
    let other = try open(directory, keys: keys)
    _ = try other.apply(try format1Record("n", keys: keys))
    #expect(other.formatStatus.refused == 1)
    #expect(try open(directory, keys: keys).formatStatus.fromOldDevices == 1)

    // That device updates, and its record arrives in format 2.
    let writer = try open(temporaryDirectory(), keys: keys, device: "pad")
    try writer.save(id: "n", kind: "host", changes: ["name": .string("x")])
    let sealed = try payload(writer, "n")
    _ = try other.apply(RemoteRecord(id: "n", keyID: sealed.keyID, payload: sealed.payload, changeTag: "t2", systemFields: nil))
    #expect(try open(directory, keys: keys).formatStatus.refused == 0)
  }

  /// A record in the old format is its writer's copy: only a local edit goes over it.
  @Test func aRefusedOldRecordStaysOnTheServerUnlessAnEditIsWaiting() throws {
    let keys = MemoryKeyProvider()
    let store = try open(temporaryDirectory(), keys: keys)
    try store.save(id: "h", kind: "host", changes: ["a": .string("1")])
    try store.setServerFields(id: "h", changeTag: "t0", systemFields: Data("t0".utf8))
    let id = "h"
    let version = try store.database.query("SELECT version FROM items WHERE id = 'h'")[0][0].int ?? 0
    try store.markSent(id: id, version: version, changeTag: "t0", systemFields: Data("t0".utf8))
    store.fetchCompleted()

    // No edit waiting: nothing to send, the row and its tag untouched.
    #expect(try store.apply(try format1Record("h", tag: "v1", keys: keys)) == .refused(needsSend: false))
    #expect(try store.pendingIDs().isEmpty)
    #expect(try store.database.query("SELECT change_tag FROM items WHERE id = 'h'")[0][0].text == "t0")

    // An edit is a normal conflict: it takes the tag, so it lands, and the old device still has its own copy.
    try store.save(id: "h", kind: "host", changes: ["a": .string("2")])
    #expect(try store.apply(try format1Record("h", tag: "v1", keys: keys)) == .refused(needsSend: true))
    #expect(try store.database.query("SELECT change_tag FROM items WHERE id = 'h'")[0][0].text == "v1")
    // Applying it again changes nothing: the tag's the same.
    #expect(try store.apply(try format1Record("h", tag: "v1", keys: keys)) == .unchanged)
  }

  /// Finding 5: time alone refuses nothing, online or off, however long.
  @Test func aStoreThatHasntFetchedYetDoesntRefuseAfterAnHour() throws {
    let keys = MemoryKeyProvider()
    let clock = TestClock()
    let testing = FormatTesting(now: { clock.now })
    let directory = temporaryDirectory()
    _ = try open(directory, keys: keys, testing: testing)
    clock.advance(7200)
    let store = try open(directory, keys: keys, testing: testing)
    #expect(!store.isFormatFinished)
    #expect(try store.apply(try format1Record("n", keys: keys)) == .merged(needsSend: true))
    #expect(try store.item(id: "n")?.fields["name"]?.stringValue == "from an old build")
  }

  /// Beyond the vault's month, an attacker's old-format write gets nowhere, even on a store that never completed a fetch.
  @Test func pastTheVaultsMonthAStoreFinishesAsSoonAsItCan() throws {
    let keys = MemoryKeyProvider()
    let clock = TestClock()
    let testing = FormatTesting(now: { clock.now })
    let directory = temporaryDirectory()
    let first = try open(directory, keys: keys, testing: testing)
    #expect(!first.isFormatFinished)
    clock.advance(31 * 24 * 3600)
    #expect(try first.apply(try format1Record("n", keys: keys)) == .refused(needsSend: false))
    #expect(first.isFormatFinished)
    #expect(try open(directory, keys: keys, testing: testing).isFormatFinished)
  }

  /// Finding 9a: a mark set once by the first device, holding a date. The next device, whenever it comes, counts from it.
  @Test func theVaultsMarkIsSharedAndHoldsNoDevice() throws {
    let keys = MemoryKeyProvider()
    let clock = TestClock()
    let testing = FormatTesting(now: { clock.now })
    _ = try open(temporaryDirectory(), keys: keys, device: "mac", testing: testing)
    let marks = try keys.marks(prefix: "format2.vault.", synced: true)
    #expect(marks.count == 1)
    #expect(!marks[0].name.contains("mac"))
    #expect(try keys.marks(prefix: "format2", synced: false).isEmpty)

    // A second device with what iCloud Keychain brought, 40 days later: nothing old-format from the server is read.
    clock.advance(40 * 24 * 3600)
    let other = keysCopy(keys)
    other.items.receive(from: keys.items)
    let pad = try open(temporaryDirectory(), keys: other, device: "pad", testing: testing)
    #expect(pad.isFormatFinished)
    #expect(try other.marks(prefix: "format2.vault.", synced: true).count == 1)
    #expect(try pad.apply(try format1Record("n", keys: other)) == .refused(needsSend: false))
  }

  @Test func twoMarksConvergeOnTheEarliest() throws {
    let a = MemoryKeyProvider()
    let b = keysCopy(a)
    let clock = TestClock()
    let testing = FormatTesting(now: { clock.now })
    _ = try open(temporaryDirectory(), keys: a, device: "a", testing: testing)
    clock.advance(25 * 24 * 3600)
    let directory = temporaryDirectory()
    _ = try open(directory, keys: b, device: "b", testing: testing)
    // Before they meet, B counts from its own, and after, from A's.
    clock.advance(10 * 24 * 3600)
    b.items.receive(from: a.items)
    let store = try open(directory, keys: b, device: "b", testing: testing)
    #expect(store.isFormatFinished)
    #expect(try b.marks(prefix: "format2.vault.", synced: true).count == 2)
  }

  /// A store that finished before a device updated doesn't begin to read format 1 again, and clearing the flag gives no
  /// more than the server window: a local row needs the sealed list.
  @Test func editingTheFileDoesntUndoIt() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let oldPayload = try old.database.query("SELECT key_id, payload FROM items WHERE id = 'id-host'")[0]
    let store = try open(old.directory, keys: keys)
    store.fetchCompleted()
    #expect(store.isFormatFinished)
    // Someone clears the flag and puts an old row back, from the old file.
    try store.database.query("DELETE FROM meta WHERE key LIKE 'format'")
    try store.database.query(
      "UPDATE items SET payload = ?, key_id = ? WHERE id = 'id-host'", [.blob(oldPayload[1].blob ?? Data()), .text(oldPayload[0].text ?? "")])

    let again = try open(old.directory, keys: keys)
    #expect(try again.item(id: "id-host") == nil)
    // Not gone: the row is there, and a save replaces it.
    #expect(try again.allIDs().contains("id-host"))
  }

  @Test func aSingleOldRowPlantedInAFinishedStoreIsRefused() throws {
    let keys = MemoryKeyProvider()
    let old = try oldStore(keys: keys)
    let store = try open(old.directory, keys: keys)
    store.fetchCompleted()
    let planted = try OldBuildStore.format1(id: "x", kind: "host", fields: ItemFields(), keys: keys)
    try store.database.query(
      "INSERT INTO items(id, kind, key_id, payload) VALUES('x', 'host', ?, ?)", [.text(planted.keyID), .blob(planted.payload)])
    #expect(try store.item(id: "x") == nil)
    #expect(try store.items(kind: "host").map(\.id).contains("x") == false)
    // A save replaces it rather than failing forever.
    try store.save(id: "x", kind: "host", changes: ["a": .string("b")])
    #expect(try store.item(id: "x")?.fields["a"]?.stringValue == "b")
  }

  // MARK: Rows that won't move

  /// Finding 10: it's carried over and counted, and doesn't stop the store.
  @Test func aRowThatWontRewriteDoesntStopTheStore() throws {
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "ok", kind: "host", changes: ["name": .string("x")])
    try old.save(id: "toolong", kind: String(repeating: "k", count: 300), changes: ["name": .string("y")])
    let store = try open(old.directory, keys: keys)
    #expect(store.formatStatus.error == nil)
    #expect(!store.isWaitingToMigrate)
    #expect(store.formatStatus.notRewritten == 1)
    #expect(try store.item(id: "ok")?.fields["name"]?.stringValue == "x")
    #expect(try store.item(id: "toolong")?.fields["name"]?.stringValue == "y")
    #expect(try store.outgoing(id: "toolong") == nil)
    _ = try store.catchUp()
    #expect(store.formatStatus.error == nil)
    #expect(try store.item(id: "toolong")?.fields["name"]?.stringValue == "y")
  }

  /// Finding 10: a sweep over rows whose key is missing reads the keychain once, not once a row.
  @Test func aSweepReadsTheKeychainOnce() throws {
    let base = MemoryKeyProvider()
    let old = try OldBuildStore(keys: base, device: "mac")
    let other = MemoryKeyProvider(keys: ["ffff": SymmetricKey(size: .bits256)])
    let writer = try OldBuildStore(keys: other, device: "pad")
    for index in 0..<200 { try writer.save(id: "m\(index)", kind: "host", changes: ["a": .int(Int64(index))]) }
    for row in try writer.database.query("SELECT id, key_id, payload FROM items") {
      try old.database.query("INSERT INTO items(id, kind, key_id, payload) VALUES(?, 'host', ?, ?)", [row[0], row[1], row[2]])
    }
    let keys = FlakyKeys(base)
    let store = try open(old.directory, keys: keys)
    #expect(store.formatStatus.unreadable == 200)
    #expect(keys.reads < 20, "\(keys.reads)")
    keys.reads = 0
    _ = try store.catchUp()
    #expect(keys.reads < 20, "\(keys.reads)")
    keys.reads = 0
    _ = try store.items(kind: "host")
    #expect(keys.reads < 20, "\(keys.reads)")
  }

  // MARK: A keychain out of reach

  private func withKeychainDown() throws -> (VaultStore, FlakyKeys, MemoryKeyProvider, RemoteRecord) {
    let base = MemoryKeyProvider()
    let keys = FlakyKeys(base)
    let store = try open(temporaryDirectory(), keys: keys)
    try store.save(id: "h", kind: "host", changes: ["a": .string("local")])
    try store.setServerFields(id: "h", changeTag: "t0", systemFields: nil)
    let writer = try open(temporaryDirectory(), keys: keysCopy(base), device: "pad")
    try writer.save(id: "h", kind: "host", changes: ["b": .string("remote")])
    let sealed = try payload(writer, "h")
    return (store, keys, base, RemoteRecord(id: "h", keyID: sealed.keyID, payload: sealed.payload, changeTag: "t9", systemFields: nil))
  }

  /// Finding 6: `apply`, retried by `catchUp`.
  @Test func aKeychainErrorIsNotARefusal() throws {
    let (store, keys, _, record) = try withKeychainDown()
    keys.failing = true
    #expect(try store.apply(record) == .deferred)
    keys.failing = false
    #expect(store.formatStatus.refused == 0)
    #expect(try store.database.query("SELECT change_tag FROM items WHERE id = 'h'")[0][0].text == "t0")
    #expect(try store.item(id: "h")?.fields["b"] == nil)

    // It comes back on its own, and takes its tag.
    _ = try store.catchUp()
    #expect(try store.item(id: "h")?.fields["a"]?.stringValue == "local")
    #expect(try store.item(id: "h")?.fields["b"]?.stringValue == "remote")
    #expect(try store.database.query("SELECT change_tag FROM items WHERE id = 'h'")[0][0].text == "t9")
    #expect(try store.engineState("retry:h") == nil)
  }

  @Test func aDeferredRecordSurvivesAReopen() throws {
    let base = MemoryKeyProvider()
    let keys = FlakyKeys(base)
    let directory = temporaryDirectory()
    let store = try open(directory, keys: keys)
    let writer = try open(temporaryDirectory(), keys: keysCopy(base), device: "pad")
    try writer.save(id: "h", kind: "host", changes: ["b": .string("remote")])
    let sealed = try payload(writer, "h")
    keys.failing = true
    #expect(try store.apply(RemoteRecord(id: "h", keyID: sealed.keyID, payload: sealed.payload, changeTag: "t", systemFields: nil)) == .deferred)
    keys.failing = false
    let again = try open(directory, keys: keys)
    _ = try again.catchUp()
    #expect(try again.item(id: "h")?.fields["b"]?.stringValue == "remote")
  }

  /// A later record at the id is what counts, not the deferred one.
  @Test func aLaterRecordReplacesADeferredOne() throws {
    let (store, keys, _, record) = try withKeychainDown()
    keys.failing = true
    _ = try store.apply(record)
    keys.failing = false
    _ = try store.apply(record)
    #expect(try store.engineState("retry:h") == nil)
  }

  @Test func aDeletionMetByAKeychainErrorComesBack() throws {
    let (store, keys, _, _) = try withKeychainDown()
    try store.markSent(id: "h", version: 1, changeTag: "t0", systemFields: nil)
    #expect(try store.pendingIDs().isEmpty)
    keys.failing = true
    try store.applyDeletion(id: "h")
    keys.failing = false
    #expect(try store.allIDs().contains("h"))
    _ = try store.catchUp()
    #expect(try store.allIDs().contains("h") == false)
  }

  /// Every other path through a decode.
  @Test func aKeychainErrorNeverLooksLikeAnEmptyStoreOrAMissingItem() throws {
    let (store, keys, _, record) = try withKeychainDown()
    try store.setServerCopy(id: "h", keyID: record.keyID, payload: record.payload)
    keys.failing = true
    #expect(throws: VaultKeychain.KeychainError.self) { try store.item(id: "h") }
    #expect(throws: VaultKeychain.KeychainError.self) { try store.items(kind: "host") }
    #expect(throws: VaultKeychain.KeychainError.self) { try store.serverCopy(id: "h") == nil || true }
    #expect(throws: VaultKeychain.KeychainError.self) { try store.holdsUnreadableRow(id: "h") }
    #expect(throws: VaultKeychain.KeychainError.self) { try store.save(id: "h", kind: "host", changes: ["c": .int(1)]) }
    #expect(throws: VaultKeychain.KeychainError.self) { try store.catchUp() }
    #expect(throws: VaultKeychain.KeychainError.self) {
      try store.applyFromPeer(id: record.id, keyID: record.keyID, payload: record.payload)
    }
    keys.failing = false
    #expect(try store.item(id: "h")?.fields["a"]?.stringValue == "local")
    #expect(store.formatStatus.refused == 0)
  }

  /// `catchUp`'s own paths: a row waiting for its key, and a copy waiting for its key, stay waiting, not refused.
  @Test func aKeychainErrorDuringCatchUpLeavesEverythingWaiting() throws {
    let base = MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(size: .bits256)])
    let otherKey = SymmetricKey(size: .bits256)
    let other = MemoryKeyProvider(keys: ["ffff": otherKey])
    let old = try oldStore(keys: base)
    let writer = try OldBuildStore(keys: other, device: "other")
    try writer.save(id: "theirs", kind: "login", changes: ["a": .string("b")])
    let theirs = try writer.database.query("SELECT key_id, payload FROM items WHERE id = 'theirs'")[0]
    try old.database.query(
      "INSERT INTO items(id, kind, key_id, payload) VALUES('theirs', '', ?, ?)", [.text(theirs[0].text ?? ""), .blob(theirs[1].blob ?? Data())])
    let keys = FlakyKeys(base)
    let store = try open(old.directory, keys: keys)

    var fields = ItemFields()
    _ = fields.apply(["newer": .string("x")], clock: HybridClock.zero.next(now: .now.addingTimeInterval(100), device: "x"))
    let sealed = try VaultItemSeal.seal(
      kind: "host", fields: try JSONEncoder().encode(fields), id: "id-host", account: "personal", keyID: "ffff", key: otherKey)
    #expect(try store.apply(RemoteRecord(id: "id-host", keyID: "ffff", payload: sealed, changeTag: "t", systemFields: nil)) == .undecryptable)

    try base.addKeys(["ffff": otherKey])
    keys.failing = true
    #expect(throws: VaultKeychain.KeychainError.self) { try store.catchUp() }
    keys.failing = false
    #expect(store.formatStatus.refused == 0)
    #expect(store.formatStatus.unreadable == 1)

    let written = try store.catchUp()
    #expect(Set(written) == ["theirs", "id-host"])
    #expect(try store.item(id: "theirs")?.fields["a"]?.stringValue == "b")
    #expect(try store.item(id: "id-host")?.fields["newer"]?.stringValue == "x")
    #expect(store.formatStatus.refused == 0)
  }

  /// An old app's edit waits out the keychain error too.
  @Test func aKeychainErrorDuringTheImportTriesAgainNextOpen() throws {
    let base = MemoryKeyProvider()
    let old = try OldBuildStore(keys: base, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("x")])
    _ = try open(old.directory, keys: base)
    try old.save(id: "later", kind: "host", changes: ["a": .string("1")])

    let keys = FailingAfter(base, reads: 0)
    let stopped = try open(old.directory, keys: keys)
    #expect(stopped.formatStatus.error != nil)
    #expect(stopped.formatStatus.refused == 0)
    keys.reads = -1
    // The store that's open tries again too, and says so.
    _ = try stopped.catchUp()
    #expect(stopped.formatStatus.error == nil)
    #expect(try stopped.item(id: "later")?.fields["a"]?.stringValue == "1")
    #expect(try open(old.directory, keys: keys).item(id: "later")?.fields["a"]?.stringValue == "1")
  }

  /// A fetch isn't complete until what it deferred was read.
  @Test func aDeferredRecordHoldsUpFinishing() throws {
    let (store, keys, base, _) = try withKeychainDown()
    let record = try format1Record("v1", keys: base)
    keys.failing = true
    #expect(try store.apply(record) == .deferred)
    keys.failing = false
    store.fetchCompleted()
    #expect(!store.isFormatFinished)
    _ = try store.catchUp()
    #expect(store.isFormatFinished)
    #expect(try store.item(id: "v1")?.fields["name"]?.stringValue == "from an old build")
    #expect(store.formatStatus.refused == 0)
  }

  /// The coordinator's conflict path: a resend now would only meet the same conflict.
  @Test func aConflictMetByAKeychainErrorWaits() throws {
    let (store, keys, _, record) = try withKeychainDown()
    let sync = SyncCoordinator(store: store)
    keys.failing = true
    #expect(sync.failed(id: "h", .conflict(server: record)) == .retryLater)
    keys.failing = false
  }

  /// A store on the old file can't even write a record down: the coordinator holds it.
  @Test func aStoreWaitingOnKeysLosesNothingItFetched() throws {
    let cloud = FakeCloud()
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("x")])
    try old.push(cloud)
    let pad = try OldBuildStore(keys: keysCopy(keys), device: "pad")
    try pad.pull(cloud)
    try pad.save(id: "h", kind: "host", changes: ["user": .string("pad")])
    try pad.push(cloud)

    let empty = MemoryKeyProvider(keys: [:])
    let app = try FakeApp(directory: old.directory, keys: empty, device: "mac", name: "new")
    #expect(app.store.isWaitingToMigrate)
    app.pull(cloud)
    #expect(!app.store.isFormatFinished)
    #expect(try old.database.query("SELECT 1 FROM items WHERE id = 'h'").count == 1)

    try empty.addKeys(keys.allKeys)
    _ = try app.store.catchUp()
    app.push(cloud)
    #expect(!app.store.isWaitingToMigrate)
    #expect(app.store.isFormatFinished)
    #expect(try app.store.item(id: "h")?.fields["user"]?.stringValue == "pad")
  }

  /// A fresh device on its first fetch with no keys yet makes none of its own for an old-format record.
  @Test func anOldFormatRecordBeforeAnyKeyArrivesDoesntMakeAKey() throws {
    let keys = MemoryKeyProvider()
    let empty = MemoryKeyProvider(keys: [:])
    let store = try open(temporaryDirectory(), keys: empty)
    #expect(try store.apply(try format1Record("v1", keys: keys)) == .deferred)
    #expect(empty.allKeys.isEmpty)
    store.fetchCompleted()
    #expect(!store.isFormatFinished)
    try empty.addKeys(keys.allKeys)
    _ = try store.catchUp()
    #expect(store.isFormatFinished)
    #expect(try store.item(id: "v1")?.fields["name"]?.stringValue == "from an old build")
  }

  /// A migration mustn't count a keychain error as a row that won't rewrite.
  @Test func aKeychainErrorDuringTheBuildStopsItAndLeavesNoFile() throws {
    let base = MemoryKeyProvider()
    let old = try oldStore(keys: base)
    let keys = FailingAfter(base, reads: 2)
    let store = try open(old.directory, keys: keys)
    #expect(store.isWaitingToMigrate)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    keys.reads = -1
    _ = try store.catchUp()
    #expect(!store.isWaitingToMigrate)
    #expect(store.formatStatus.notRewritten == 0)
    #expect(store.formatStatus.resealed == everyKind.count)
    try expectEverythingReadable(store)
  }

  // MARK: Deleting and replaying

  private func sealed(_ store: VaultStore, _ id: String, tag: String = "t") throws -> RemoteRecord {
    let row = try payload(store, id)
    return RemoteRecord(id: id, keyID: row.keyID, payload: row.payload, changeTag: tag, systemFields: nil)
  }

  /// Finding 9b: CloudKit deletes a pin, then puts an older payload of it back.
  @Test func aDeleteAndAReplayDoesntRollBackAPin() throws {
    let keys = MemoryKeyProvider()
    let store = try open(temporaryDirectory(), keys: keys)
    try store.save(id: "pin", kind: "knownHost", changes: ["fingerprint": .string("old")])
    let old = try sealed(store, "pin")
    try store.save(id: "pin", kind: "knownHost", changes: ["fingerprint": .string("new")])
    try store.markSent(id: "pin", version: 2, changeTag: "t2", systemFields: nil)
    #expect(try store.pendingIDs().isEmpty)

    try store.applyDeletion(id: "pin")
    #expect(try store.allIDs().contains("pin") == false)
    #expect(try store.apply(old) == .refused(needsSend: false))
    #expect(try store.item(id: "pin") == nil)
    #expect(try store.applyFromPeer(id: "pin", keyID: old.keyID, payload: old.payload) == .refused)
    #expect(try store.item(id: "pin") == nil)
    #expect(try open(store.directory, keys: keys).apply(old) == .refused(needsSend: false))
  }

  /// A purged tombstone counts too, and a later record or save at the id still goes in, on every device that dropped it.
  @Test func anIDThatWasDroppedTakesWhatsLater() throws {
    let keys = MemoryKeyProvider()
    let store = try open(temporaryDirectory(), keys: keys)
    let other = try open(temporaryDirectory(), keys: keys, device: "pad")
    try store.save(id: "pin", kind: "knownHost", changes: ["fingerprint": .string("one")])
    let record = try sealed(store, "pin")
    _ = try other.apply(record)
    try store.markSent(id: "pin", version: 1, changeTag: "t1", systemFields: nil)
    try other.database.query("DELETE FROM outbox")
    try other.applyDeletion(id: "pin")

    try store.database.query("DELETE FROM outbox")
    try store.delete(id: "pin")
    try store.database.query("DELETE FROM outbox")
    store.fetchCompleted()
    let purged = try store.purgeTombstones(olderThan: -100, now: .now)
    #expect(purged == ["pin"])
    #expect(try store.apply(record) == .refused(needsSend: false))

    // Saved again, with a clock past what it dropped, whatever the wall clock says.
    Thread.sleep(forTimeInterval: 0.01)
    try other.save(id: "pin", kind: "knownHost", changes: ["fingerprint": .string("two")])
    #expect(try #require(try other.item(id: "pin")).fields.latestClock > #require(try record.opened(by: other)).fields.latestClock)
    let later = try sealed(other, "pin", tag: "t2")
    #expect(try store.apply(later).isMerged)
    #expect(try store.item(id: "pin")?.fields["fingerprint"]?.stringValue == "two")
  }

  /// Finding 9b: revocations are out of CloudKit's reach.
  @Test func deletingTheRecordDoesntUnrevokeADevice() throws {
    let keys = MemoryKeyProvider()
    let store = try open(temporaryDirectory(), keys: keys)
    let device = VaultDeviceKey(id: "dead", deviceName: "Lost", publicKey: "ssh-ed25519 AAAA lost", platform: "mac")
    try store.save(device)
    try store.revokeDevice(device)
    try store.database.query("DELETE FROM outbox")
    try store.applyDeletion(id: try store.revokedDeviceID("dead"))
    #expect(try store.isRevoked(device: "dead"))
    #expect(try store.revokedDevices().map(\.deviceID) == ["dead"])
    #expect(try store.revokedDevices().first?.name == "Lost")

    // Finding 7: its device key coming back, as it does when a device that missed the deletion sends it again, or under
    // another id with the same key, trusts nothing.
    try store.save(VaultDeviceKey(id: "dead", deviceName: "Lost", publicKey: "ssh-ed25519 AAAA lost", platform: "mac"))
    try store.save(VaultDeviceKey(id: "other", deviceName: "Lost", publicKey: "ssh-ed25519 AAAA lost", platform: "mac"))
    #expect(try store.deviceKeysByTrust().trusted.isEmpty)
    #expect(try store.deviceKeysByTrust().revoked.count == 2)

    // Trusting it again is the user's, and it does take.
    try store.trustAgain(device: "dead")
    #expect(try store.isRevoked(device: "dead") == false)
    #expect(try store.revokedDevices().isEmpty)
    #expect(try store.deviceKeysByTrust().trusted.count == 2)
  }

  @Test func aRevocationInOneVaultIsntOneInAnother() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let personal = try open(directory, keys: keys)
    let account = try open(directory, keys: keys, fileName: "acme.sqlite", account: "acme")
    let device = VaultDeviceKey(id: "dead", deviceName: "Lost", publicKey: "ssh-ed25519 AAAA lost", platform: "mac")
    try account.save(device)
    try account.revokeDevice(device)
    #expect(try account.isRevoked(device: "dead"))
    #expect(try personal.isRevoked(device: "dead") == false)
  }

  /// A revocation from before the marks gets one when the store first opens.
  @Test func anOldRevocationIsMarkedOnMigrating() throws {
    let keys = MemoryKeyProvider()
    let old = try OldBuildStore(keys: keys, device: "mac")
    let earlier = try open(temporaryDirectory(), keys: keys)
    let id = try earlier.revokedDeviceID("dead")
    try old.save(id: id, kind: VaultRevokedDevice.kind, changes: VaultRevokedDevice(id: id, deviceID: "dead", name: "Lost", publicKey: "ssh-ed25519 AAAA lost").values)
    let store = try open(old.directory, keys: keys)
    try store.database.query("DELETE FROM outbox")
    try store.applyDeletion(id: id)
    #expect(try store.isRevoked(device: "dead"))
  }

  /// Finding 9c: a record naming a missing key doesn't take the place of a row waiting for its own.
  @Test func aRecordNamingAMissingKeyKeepsARowWaitingForItsOwn() throws {
    let keys = MemoryKeyProvider()
    let store = try open(temporaryDirectory(), keys: keys)
    let real = SymmetricKey(size: .bits256)
    var fields = ItemFields()
    _ = fields.apply(["a": .string("b")], clock: HybridClock.zero.next(now: .now, device: "pad"))
    let body = try JSONEncoder().encode(fields)
    let genuine = try VaultItemSeal.seal(kind: "host", fields: body, id: "h", account: "personal", keyID: "k1", key: real)
    #expect(try store.apply(RemoteRecord(id: "h", keyID: "k1", payload: genuine, changeTag: "t1", systemFields: nil)) == .undecryptable)
    let forged = try VaultItemSeal.seal(kind: "host", fields: body, id: "h", account: "personal", keyID: "k2", key: SymmetricKey(size: .bits256))
    #expect(try store.apply(RemoteRecord(id: "h", keyID: "k2", payload: forged, changeTag: "t2", systemFields: nil)) == .undecryptable)

    keys.add(real, id: "k1")
    #expect(try store.item(id: "h")?.fields["a"]?.stringValue == "b")
  }

  /// And the other way: the second key arrives first, and what it opens is authentic.
  @Test func aWaitingCopyThatOpensFirstTakesARowStillWaiting() throws {
    let keys = MemoryKeyProvider()
    let store = try open(temporaryDirectory(), keys: keys)
    let newer = SymmetricKey(size: .bits256)
    var fields = ItemFields()
    _ = fields.apply(["a": .string("newer")], clock: HybridClock.zero.next(now: .now, device: "pad"))
    let body = try JSONEncoder().encode(fields)
    let first = try VaultItemSeal.seal(kind: "host", fields: body, id: "h", account: "personal", keyID: "k1", key: SymmetricKey(size: .bits256))
    _ = try store.apply(RemoteRecord(id: "h", keyID: "k1", payload: first, changeTag: "t1", systemFields: nil))
    let second = try VaultItemSeal.seal(kind: "host", fields: body, id: "h", account: "personal", keyID: "k2", key: newer)
    _ = try store.apply(RemoteRecord(id: "h", keyID: "k2", payload: second, changeTag: "t2", systemFields: nil))
    keys.add(newer, id: "k2")
    _ = try store.catchUp()
    #expect(try store.item(id: "h")?.fields["a"]?.stringValue == "newer")
    #expect(try store.pendingIDs().isEmpty)
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
    #expect(!appA.store.isFormatFinished)
    try oldB.save(id: "edited-before-a-pushed", kind: "login", changes: ["byB": .string("kept")])
    try oldB.push(cloud)

    // A's push meets B's format 1 record during its first fetch: it merges it and puts its format 2 copy over it.
    appA.sync(cloud)
    #expect(appA.store.isFormatFinished)
    #expect(try appA.store.item(id: "edited-before-a-pushed")?.fields["byB"]?.stringValue == "kept")
    #expect(try format1Rows(appA.store) == 0)
    #expect(cloud.records.values.allSatisfy { VaultItemSeal.parse($0.payload) != nil })

    // B, still old, sees nothing of it: its row stays readable and its edit stays with it.
    try oldB.pull(cloud)
    #expect(oldB.read("shared")?.fields["user"]?.stringValue == "from a")
    #expect(oldB.read("edited-before-a-pushed")?.fields["byB"]?.stringValue == "kept")

    // B writes on. A new record reaches the server in format 1, which A refuses and leaves there.
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
    appB.sync(cloud)
    #expect(appB.store.isFormatFinished)
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
    #expect(!storeB.isWaitingToMigrate)
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

/// A keychain that goes out of reach after some reads.
final class FailingAfter: VaultKeyProvider, @unchecked Sendable {
  let base: MemoryKeyProvider
  /// Reads left. Negative: never fails.
  var reads: Int

  init(_ base: MemoryKeyProvider, reads: Int) {
    self.base = base
    self.reads = reads
  }

  private func check() throws {
    if reads == 0 { throw VaultKeychain.KeychainError.status(-25308) }
    if reads > 0 { reads -= 1 }
  }

  func primary() throws -> (id: String, key: SymmetricKey) { try base.primary() }
  func key(id: String) throws -> SymmetricKey? { try check(); return try base.key(id: id) }
  var allKeys: [String: SymmetricKey] { get throws { base.allKeys } }
  var keyEpochs: [VaultKeyEpoch] { get throws { try base.keyEpochs } }
  func rotate(kitCheck: String?) throws -> VaultKeyEpoch { try base.rotate(kitCheck: kitCheck) }
  func kitCheck(forKey id: String) throws -> String? { try base.kitCheck(forKey: id) }
  func isRetired(_ id: String) throws -> Bool { try base.isRetired(id) }
  func addKeys(_ keys: [String: SymmetricKey]) throws { try base.addKeys(keys) }
  func stableIDKey() throws -> SymmetricKey { try base.stableIDKey() }
  func stableIDKeySource() throws -> String? { try base.stableIDKeySource() }
  func restoreStableIDKey(_ key: SymmetricKey) throws { try base.restoreStableIDKey(key) }
  func marks(prefix: String, synced: Bool) throws -> [(name: String, data: Data)] { try base.marks(prefix: prefix, synced: synced) }
  func setMark(_ name: String, data: Data, synced: Bool) throws { try base.setMark(name, data: data, synced: synced) }
  func removeMark(_ name: String, synced: Bool) throws { try base.removeMark(name, synced: synced) }
}

extension RemoteRecord {
  func opened(by store: VaultStore) throws -> VaultItem? {
    try store.decodeIfItOpens(id: id, keyID: keyID, payload: payload, from: .local)
  }
}

extension VaultStore.ApplyResult {
  var isMerged: Bool {
    if case .merged = self { true } else { false }
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
