import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Findings X2 and U6 of the second review: what an old app on this device wrote after the migration.
struct OldFileImportTests {
  let keys = MemoryKeyProvider()

  private func oldStore() throws -> OldBuildStore {
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("first")])
    return old
  }

  /// X2: a rotation retires a key on the server and in the old file alike.
  @Test func anOldAppsWriteUnderARetiredKeyDoesntComeOver() throws {
    let old = try oldStore()
    _ = try openStore(old.directory, keys: keys)
    try keys.rotate(kitCheck: nil)
    try old.save(id: "late", kind: "host", changes: ["a": .string("1")])
    try old.save(id: "h", kind: "host", changes: ["byOld": .string("1")])

    let again = try openStore(old.directory, keys: keys)
    #expect(try again.item(id: "late") == nil)
    #expect(try again.item(id: "h")?.fields["byOld"] == nil)
    #expect(again.formatStatus.refused == 2)
    // Once.
    let versions = try again.meta("format.imported")
    #expect(try openStore(old.directory, keys: keys).meta("format.imported") == versions)
  }

  /// U6: a text merge stamps `<device>+merge`, and that's this device's edit too.
  @Test func anEditStampedAsAMergeComesOver() throws {
    let old = try oldStore()
    _ = try openStore(old.directory, keys: keys)
    let fields = ItemFields(["text": StampedValue(.string("merged"), clock: HybridClock(
      millis: Int64((Date.now.timeIntervalSince1970 + 2) * 1000), counter: 0, device: "mac+merge"))])
    let sealed = try OldBuildStore.format1(id: "note", kind: "note", fields: fields, keys: keys)
    try old.database.query(
      "INSERT INTO items(id, kind, key_id, payload, version, modified) VALUES('note', 'note', ?, ?, 1, ?)",
      [.text(sealed.keyID), .blob(sealed.payload), .double(Double(fields.latestClock.millis) / 1000)])

    #expect(try openStore(old.directory, keys: keys).item(id: "note")?.fields["text"]?.stringValue == "merged")
  }

  /// And `mac2`, which starts the same, isn't this device.
  @Test func anotherDevicesStampDoesntComeOver() throws {
    let old = try oldStore()
    _ = try openStore(old.directory, keys: keys)
    let fields = stampedFields(["a": .string("x")], device: "mac2", at: Date.now.addingTimeInterval(2))
    let sealed = try OldBuildStore.format1(id: "theirs", kind: "host", fields: fields, keys: keys)
    try old.database.query(
      "INSERT INTO items(id, kind, key_id, payload, version, modified) VALUES('theirs', 'host', ?, ?, 1, ?)",
      [.text(sealed.keyID), .blob(sealed.payload), .double(Double(fields.latestClock.millis) / 1000)])
    #expect(try openStore(old.directory, keys: keys).item(id: "theirs") == nil)
  }

  /// U6: an old app stamped an edit ahead, having seen a fast peer. A later edit in the new store still wins.
  @Test func aLaterEditHereBeatsAnOldAppsEditStampedAhead() throws {
    let old = try oldStore()
    let store = try openStore(old.directory, keys: keys)
    let ahead = Date.now.addingTimeInterval(600)
    try old.apply(try format1Remote("peer", keys: keys, at: ahead))
    try old.save(id: "h", kind: "host", changes: ["name": .string("old app, earlier")])

    try store.save(id: "h", kind: "host", changes: ["name": .string("new app, later")])
    #expect(try store.item(id: "h")?.fields["name"]?.stringValue == "new app, later")
    #expect(try openStore(old.directory, keys: keys).item(id: "h")?.fields["name"]?.stringValue == "new app, later")
  }

  /// The same, with a clock so far ahead this store won't follow it.
  @Test func aLaterEditHereBeatsAnOldAppsEditStampedFarAhead() throws {
    let old = try oldStore()
    let store = try openStore(old.directory, keys: keys)
    try old.apply(try format1Remote("peer", keys: keys, at: Date.now.addingTimeInterval(365 * 24 * 3600)))
    try old.save(id: "h", kind: "host", changes: ["name": .string("old app, earlier")])

    try store.save(id: "h", kind: "host", changes: ["name": .string("new app, later")])
    #expect(try openStore(old.directory, keys: keys).item(id: "h")?.fields["name"]?.stringValue == "new app, later")
  }

  /// An app that stays open picks up what an old app wrote, without waiting to be opened again.
  @Test func catchUpBringsOverWhatAnOldAppWrote() throws {
    let old = try oldStore()
    let store = try openStore(old.directory, keys: keys)
    try old.save(id: "later", kind: "host", changes: ["a": .string("1")])
    #expect(try store.item(id: "later") == nil)
    #expect(try store.catchUp().contains("later"))
    #expect(try store.item(id: "later")?.fields["a"]?.stringValue == "1")
    #expect(try store.pendingIDs().contains("later"))
    #expect(try store.catchUp().contains("later") == false)
  }

  /// A device id made up because the keychain was out of reach doesn't match any stamp. Nothing is recorded, so the edit
  /// comes over when a later launch has the real one.
  @Test func aMadeUpDeviceIDImportsNothingAndRecordsNothing() throws {
    let old = try oldStore()
    let first = try openStore(old.directory, keys: keys)
    let versions = try first.meta("format.imported")
    try old.save(id: "later", kind: "host", changes: ["a": .string("1")])
    try old.save(id: "h", kind: "host", changes: ["edit": .string("2")])

    let madeUp = "made-up-\(UUID().uuidString)"
    VaultDevice.noteProvisional(madeUp)
    let store = try openStore(old.directory, keys: keys, device: madeUp)
    #expect(try store.item(id: "later") == nil)
    #expect(try store.meta("format.imported") == versions)
    _ = try store.catchUp()
    try store.save(id: "x", kind: "host", changes: ["a": .string("1")])
    #expect(try store.item(id: "later") == nil)
    #expect(try store.meta("format.imported") == versions)

    let again = try openStore(old.directory, keys: keys)
    #expect(try again.item(id: "later") != nil)
    #expect(try again.item(id: "h")?.fields["edit"]?.stringValue == "2")
  }
}
