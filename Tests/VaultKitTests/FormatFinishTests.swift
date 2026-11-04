import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Finding U4 of the second review: a store finishes only with what it was given read.
struct FormatFinishTests {
  let keys = MemoryKeyProvider()

  /// A format 1 record naming a key this device hasn't got, beside a row: refused and deleted once the key came.
  @Test func aFormat1CopyWaitingForItsKeyHoldsUpFinishing() throws {
    let store = try openStore(keys: keys)
    try store.save(id: "h", kind: "host", changes: ["a": .string("local")])
    let otherKey = SymmetricKey(size: .bits256)
    let other = MemoryKeyProvider(keys: ["ffff": otherKey])
    let record = try format1Remote("h", keys: other, changes: ["byPad": .string("edit")])
    #expect(try store.apply(record) == .undecryptable)

    store.fetchCompleted()
    #expect(!store.isFormatFinished)

    keys.add(otherKey, id: "ffff")
    _ = try store.catchUp()
    #expect(try store.item(id: "h")?.fields["byPad"]?.stringValue == "edit")
    #expect(try store.item(id: "h")?.fields["a"]?.stringValue == "local")
    #expect(store.isFormatFinished)
    #expect(store.formatStatus.refused == 0)
  }

  /// Up to the vault's month, and no further.
  @Test func aWaitingCopyHoldsUpFinishingForAMonthAtMost() throws {
    let clock = TestClock()
    let directory = temporaryDirectory()
    let store = try openStore(directory, keys: keys, testing: FormatTesting(now: { clock.now }))
    try store.save(id: "h", kind: "host", changes: ["a": .string("local")])
    let otherKey = SymmetricKey(size: .bits256)
    let record = try format1Remote("h", keys: MemoryKeyProvider(keys: ["ffff": otherKey]))
    _ = try store.apply(record)
    store.fetchCompleted()
    #expect(!store.isFormatFinished)

    clock.advance(31 * 24 * 3600)
    _ = try store.catchUp()
    #expect(store.isFormatFinished)
    keys.add(otherKey, id: "ffff")
    _ = try store.catchUp()
    #expect(store.formatStatus.refused == 1)
    #expect(try store.item(id: "h")?.fields["a"]?.stringValue == "local")
  }

  /// One that's in format 2 can't be refused for its format, so there's nothing to hold up.
  @Test func aFormat2CopyWaitingForItsKeyDoesntHoldUpFinishing() throws {
    let store = try openStore(keys: keys)
    try store.save(id: "h", kind: "host", changes: ["a": .string("local")])
    let fields = try JSONEncoder().encode(stampedFields(["b": .string("x")]))
    let payload = try VaultItemSeal.seal(kind: "host", fields: fields, id: "h", account: "personal", keyID: "ffff", key: SymmetricKey(size: .bits256))
    #expect(try store.apply(RemoteRecord(id: "h", keyID: "ffff", payload: payload, changeTag: "t1", systemFields: nil)) == .undecryptable)
    store.fetchCompleted()
    #expect(store.isFormatFinished)
  }

  // MARK: Records with nothing read of them

  /// An asset's file that couldn't be read: the record is on the server, and this store hasn't seen it.
  @Test func aRecordWithAnUnreadableAssetHoldsUpFinishingUntilItIsRead() throws {
    let store = try openStore(keys: keys)
    let coordinator = SyncCoordinator(store: store)
    _ = coordinator.fetched(modified: [], deleted: [], unread: [UnreadRecord(id: "big", changeTag: "t1", hasPayload: true)])
    coordinator.fetchCompleted()
    #expect(!store.isFormatFinished)
    #expect(store.needsFullFetch)
    #expect(!store.isSettled)
    _ = try store.catchUp()
    #expect(!store.isFormatFinished)

    // The next launch's full fetch brings it, and this time it opens.
    _ = coordinator.fetched(modified: [try format1Remote("big", keys: keys)], deleted: [])
    _ = try store.catchUp()
    #expect(store.isFormatFinished)
    #expect(!store.needsFullFetch)
    #expect(try store.item(id: "big") != nil)
  }

  @Test func aFinishedStoreFetchesEverythingAgainForAnUnreadRecord() throws {
    let store = try openStore(keys: keys)
    store.fetchCompleted()
    #expect(!store.needsFullFetch)
    try store.noteUnread(UnreadRecord(id: "big", changeTag: "t1", hasPayload: true))
    #expect(store.needsFullFetch)
    // Delivered unchanged, it still counts as delivered.
    let writer = try openStore(keys: keys, device: "pad")
    try writer.save(id: "big", kind: "host", changes: ["a": .string("b")])
    #expect(try store.apply(try sealedRemote(writer, "big", tag: "t1")).isMerged)
    #expect(!store.needsFullFetch)
  }

  /// One that's still out of reach after a month stops being waited for.
  @Test func anUnreadRecordIsWaitedForAMonthAtMost() throws {
    let clock = TestClock()
    let store = try openStore(keys: keys, testing: FormatTesting(now: { clock.now }))
    store.fetchCompleted()
    try store.noteUnread(UnreadRecord(id: "big", changeTag: "t1", hasPayload: true))
    clock.advance(20 * 24 * 3600)
    // Meeting it again doesn't start the month over.
    try store.noteUnread(UnreadRecord(id: "big", changeTag: "t2", hasPayload: true))
    clock.advance(11 * 24 * 3600)
    _ = try store.catchUp()
    #expect(!store.needsFullFetch)
  }

  /// A record with no payload at all has nothing to wait for. It's counted, rather than vanishing.
  @Test func aRecordWithNoPayloadIsRefused() throws {
    let store = try openStore(keys: keys)
    let coordinator = SyncCoordinator(store: store)
    _ = coordinator.fetched(modified: [], deleted: [], unread: [UnreadRecord(id: "empty", changeTag: "t1", hasPayload: false)])
    store.fetchCompleted()
    #expect(store.isFormatFinished)
    #expect(store.formatStatus.refused == 1)
  }

  // MARK: Per zone

  /// A zone finishes by its own event. Before this any fetch's return finished every attached zone, read or not.
  @Test func aZoneFinishesByItsOwnEvent() throws {
    let directory = temporaryDirectory()
    let personal = try openStore(directory, keys: keys)
    let accounts = VaultAccountStores(personal: personal, notifier: nil)
    let account = try accounts.create(name: "Acme")
    let store = try accounts.store(forAccount: account.id)
    let zones = SyncZones(accounts: accounts)
    let zone = SyncZones.zoneName(forAccount: account.id)
    #expect(zones.activeZones().contains(zone))

    zones.zoneFetched(SyncZones.personalZone, fromNothing: true)
    #expect(personal.isFormatFinished)
    #expect(!store.isFormatFinished)
    #expect(zones.needsFullFetch)

    // An engine with a saved position has seen only what changed.
    zones.zoneFetched(zone, fromNothing: false)
    #expect(!store.isFormatFinished)

    zones.zoneFetched(zone, fromNothing: true)
    #expect(store.isFormatFinished)
    #expect(!zones.needsFullFetch)
  }
}
