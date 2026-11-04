import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Finding U8 and U3's variant of the second review.
struct SyncResetTests {
  let keys = MemoryKeyProvider()

  // MARK: An Apple ID switch

  /// A new account's server hasn't been seen: format 1 there merges, rather than being refused and written over.
  @Test func anotherAccountsServerIsReadAgain() throws {
    let store = try openStore(keys: keys)
    try store.save(id: "h", kind: "host", changes: ["a": .string("local")])
    store.fetchCompleted()
    #expect(store.isFormatFinished)

    try store.resetServerState(forAnotherAccount: true)
    #expect(!store.isFormatFinished)
    #expect(store.needsFullFetch)
    #expect(try store.apply(try format1Remote("h", keys: keys, changes: ["b": .string("there")])) == .merged(needsSend: true))
    #expect(try store.item(id: "h")?.fields["b"]?.stringValue == "there")
    store.fetchCompleted()
    #expect(store.isFormatFinished)
    #expect(try openStore(store.directory, keys: keys).isFormatFinished)
  }

  /// Past the vault's month it finishes at once, as any store does.
  @Test func pastTheMonthAResetDoesntReopenFormat1() throws {
    let clock = TestClock()
    let store = try openStore(keys: keys, testing: FormatTesting(now: { clock.now }))
    store.fetchCompleted()
    clock.advance(31 * 24 * 3600)
    try store.resetServerState(forAnotherAccount: true)
    #expect(try store.apply(try format1Remote("h", keys: keys)) == .refused(needsSend: false))
    #expect(store.isFormatFinished)
  }

  /// What was fetched and not read yet is still the user's data: only what it said about the old server goes.
  @Test func aResetKeepsADeferredRecordButNotItsTagOrADeletion() throws {
    let flaky = FlakyKeys(keys)
    let store = try openStore(keys: flaky)
    try store.save(id: "gone", kind: "host", changes: ["a": .string("still here")])
    try markEverythingSent(store)
    let writer = try openStore(keys: keys, device: "pad")
    try writer.save(id: "h", kind: "host", changes: ["b": .string("remote")])
    let record = try sealedRemote(writer, "h", tag: "old-account-tag")
    try store.deferRecord(VaultStore.DeferredRecord(record))
    try store.deferRecord(VaultStore.DeferredRecord(deletionOf: "gone"))
    try store.setEngineState(Data("x".utf8), for: "some.app")

    try store.resetServerState(forAnotherAccount: true)
    #expect(try store.engineState("some.app") == nil)
    _ = try store.catchUp()
    #expect(try store.item(id: "h")?.fields["b"]?.stringValue == "remote")
    #expect(try store.database.query("SELECT change_tag FROM items WHERE id = 'h'")[0][0].text == nil)
    #expect(try store.item(id: "gone")?.fields["a"]?.stringValue == "still here")
  }

  // MARK: Retrying

  /// A record that can't be applied doesn't keep the ones after it waiting.
  @Test func oneDeferredRecordDoesntHoldUpTheRest() throws {
    let flaky = FlakyKeys(keys)
    let store = try openStore(keys: flaky)
    flaky.failingIDs = ["bad"]
    let fields = stampedFields(["a": .string("x")])
    let bad = try VaultItemSeal.seal(
      kind: "host", fields: try JSONEncoder().encode(fields), id: "a-first", account: "personal", keyID: "bad", key: SymmetricKey(size: .bits256))
    #expect(try store.apply(RemoteRecord(id: "a-first", keyID: "bad", payload: bad, changeTag: "t1", systemFields: nil)) == .deferred)
    let writer = try openStore(keys: keys, device: "pad")
    try writer.save(id: "b-second", kind: "host", changes: ["b": .string("good")])
    try store.deferRecord(VaultStore.DeferredRecord(try sealedRemote(writer, "b-second")))

    _ = try store.catchUp()
    #expect(try store.item(id: "b-second")?.fields["b"]?.stringValue == "good")
    #expect(try store.engineState("retry:b-second") == nil)
    #expect(try store.engineState("retry:a-first") != nil)
  }

  // MARK: What counts as refused

  /// A store's own purged tombstone, fetched before its delete lands, isn't a refusal.
  @Test func aPurgedTombstoneComingBackIsntCounted() throws {
    let store = try openStore(keys: keys)
    try store.save(id: "t", kind: "host", changes: ["a": .string("b")])
    try store.delete(id: "t")
    try markEverythingSent(store)
    let tombstone = try sealedRemote(store, "t")
    store.fetchCompleted()
    #expect(try store.purgeTombstones(olderThan: -100) == ["t"])

    #expect(try store.apply(tombstone) == .refused(needsSend: false))
    #expect(try store.applyFromPeer(id: "t", keyID: tombstone.keyID, payload: tombstone.payload) == .refused)
    #expect(store.formatStatus.refused == 0)
    #expect(try store.item(id: "t") == nil)
  }

  /// A live record put back after a delete is what the mark is there to catch, and still counts.
  @Test func aReplayOverADropStillCounts() throws {
    let store = try openStore(keys: keys)
    try store.save(id: "pin", kind: "knownHost", changes: ["fingerprint": .string("old")])
    let replay = try sealedRemote(store, "pin")
    try store.save(id: "pin", kind: "knownHost", changes: ["fingerprint": .string("new")])
    try markEverythingSent(store)
    try store.applyDeletion(id: "pin")
    #expect(try store.apply(replay) == .refused(needsSend: false))
    #expect(store.formatStatus.refused == 1)
  }

  /// A zone anyone with CloudKit access can delete isn't another account: it doesn't reopen format 1.
  @Test func aDeletedZoneDoesntReopenFormat1() throws {
    let store = try openStore(keys: keys)
    store.fetchCompleted()
    try store.resetServerState()
    #expect(store.isFormatFinished)
    #expect(try store.apply(try format1Remote("h", keys: keys)) == .refused(needsSend: false))
  }

  // MARK: Purging

  /// U3's variant: a tombstone whose record on the server is a format 1 edit this store refused. Deleting it would take
  /// that edit from the device that made it.
  @Test func aPurgeLeavesARefusedRecordOnTheServer() throws {
    let store = try openStore(keys: keys)
    try store.save(id: "t", kind: "host", changes: ["a": .string("b")])
    try store.delete(id: "t")
    try markEverythingSent(store)
    store.fetchCompleted()
    #expect(try store.apply(try format1Remote("t", keys: keys)) == .refused(needsSend: false))

    #expect(try store.purgeTombstones(olderThan: -100).isEmpty)
    #expect(try store.item(id: "t")?.isDeleted == true)

    // Once it has been dealt with, the tombstone can go.
    try store.clearRefused(id: "t")
    #expect(try store.purgeTombstones(olderThan: -100) == ["t"])
  }

  /// A store that hasn't fetched doesn't know what's on the server at that id, and `attach` runs before the first fetch.
  @Test func aStoreStillInItsFirstFetchPurgesNothing() throws {
    let store = try openStore(keys: keys)
    try store.save(id: "t", kind: "host", changes: ["a": .string("b")])
    try store.delete(id: "t")
    try markEverythingSent(store)
    #expect(try store.purgeTombstones(olderThan: -100).isEmpty)
    store.fetchCompleted()
    #expect(try store.purgeTombstones(olderThan: -100) == ["t"])
  }
}
