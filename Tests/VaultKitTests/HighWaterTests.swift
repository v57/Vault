import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Finding U7 of the second review: a dropped record's high-water mark and the id key can't leave a record stuck.
struct HighWaterTests {
  let keys = MemoryKeyProvider()
  let year: TimeInterval = 365 * 24 * 3600

  private func oneFarAheadRecord() throws -> (dropper: VaultStore, replay: RemoteRecord) {
    let dropper = try openStore(keys: keys)
    try dropper.save(id: "d", kind: "host", changes: ["plain": .string("first")])
    let replay = try sealedRemote(dropper, "d", tag: "old")
    try dropper.save(id: "d", kind: "host", changes: ["plain": .string("second")])

    let fast = try openStore(keys: keys, device: "fast")
    fast.wallClock = { Date.now.addingTimeInterval(60 * self.year) }
    _ = try fast.apply(try sealedRemote(dropper, "d"))
    try fast.save(id: "d", kind: "host", changes: ["ahead": .string("from the future")])
    _ = try dropper.apply(try sealedRemote(fast, "d", tag: "t2"))
    try markEverythingSent(dropper)
    try dropper.applyDeletion(id: "d")
    #expect(try dropper.item(id: "d") == nil)
    return (dropper, replay)
  }

  /// A record dropped with a far-future field: a device that never held it writes the same derived id, with an ordinary clock.
  @Test func aFarFutureClockDoesntShutTheIDOut() throws {
    let (dropper, _) = try oneFarAheadRecord()
    let fresh = try openStore(keys: keys, device: "fresh")
    try fresh.save(id: "d", kind: "host", changes: ["plain": .string("again")])
    #expect(try dropper.apply(try sealedRemote(fresh, "d", tag: "t3")).isMerged)
    #expect(try dropper.item(id: "d")?.fields["plain"]?.stringValue == "again")
    #expect(try dropper.meta("hw.d") == nil)
  }

  /// What the mark is for still holds: an older payload put back after a delete.
  @Test func anOlderPayloadStaysRefusedWithAFarFutureFieldBeside() throws {
    let (dropper, replay) = try oneFarAheadRecord()
    #expect(try dropper.apply(replay) == .refused(needsSend: false))
    #expect(try dropper.item(id: "d") == nil)
    #expect(try dropper.applyFromPeer(id: "d", keyID: replay.keyID, payload: replay.payload) == .refused)
  }

  /// A mark that a build before this left past the bound is ignored too.
  @Test func aRememberedFarFutureMarkDoesntCount() throws {
    let store = try openStore(keys: keys)
    let far = HybridClock(millis: Int64(Date.now.addingTimeInterval(60 * year).timeIntervalSince1970 * 1000), counter: 0, device: "fast")
    try store.setMeta("hw.d", far.description)
    let fresh = try openStore(keys: keys, device: "fresh")
    try fresh.save(id: "d", kind: "host", changes: ["plain": .string("again")])
    #expect(try store.apply(try sealedRemote(fresh, "d")).isMerged)
  }

  /// Three devices end the same, whichever dropped what.
  @Test func devicesConvergeAfterAFarFutureDrop() throws {
    let cloud = FakeCloud()
    let shared = MemoryKeyProvider()
    let a = try FakeApp(directory: temporaryDirectory(), keys: shared, device: "a", name: "a")
    let b = try FakeApp(directory: temporaryDirectory(), keys: shared, device: "b", name: "b")
    let fast = try FakeApp(directory: temporaryDirectory(), keys: shared, device: "fast", name: "fast")
    fast.store.wallClock = { Date.now.addingTimeInterval(60 * self.year) }
    try fast.store.save(id: "d", kind: "host", changes: ["ahead": .string("x")])
    fast.sync(cloud)
    a.sync(cloud)
    b.sync(cloud)
    #expect(try a.store.item(id: "d") != nil)

    // Gone from the server: a drops it, the mark stays. b writes over it with its ordinary clock.
    cloud.delete("d")
    a.pull(cloud)
    #expect(try a.store.item(id: "d") == nil)
    try b.store.database.query("DELETE FROM items WHERE id = 'd'")
    try b.store.save(id: "d", kind: "host", changes: ["plain": .string("again")])
    for _ in 0..<3 {
      for app in [a, b, fast] {
        app.push(cloud)
        app.pull(cloud)
      }
    }
    #expect(try a.store.item(id: "d")?.fields["plain"]?.stringValue == "again")
    #expect(try b.store.item(id: "d")?.fields["plain"]?.stringValue == "again")
    #expect(try a.store.item(id: "d")?.fields == b.store.item(id: "d")?.fields)
  }

  // MARK: The id key

  /// A device with only a key it made itself, and a record here naming a key it hasn't got: ids wait for that key.
  @Test func idsWaitWhileARowNamesAnEarlierKey() throws {
    let real = try openStore(keys: keys, device: "real")
    let wanted = try real.derivedID("deviceHost|x")
    try real.save(id: "h", kind: "host", changes: ["a": .string("b")])

    let empty = MemoryKeyProvider(keys: [:])
    let fresh = try openStore(keys: empty, device: "fresh")
    #expect(try fresh.apply(try sealedRemote(real, "h")) == .undecryptable)
    #expect(throws: VaultCrypto.CryptoError.self) { try fresh.derivedID("deviceHost|x") }
    #expect(empty.allKeys.isEmpty)

    // A save makes a key of its own, which isn't where ids come from.
    try fresh.save(id: "mine", kind: "host", changes: ["a": .string("b")])
    #expect(empty.allKeys.count == 1)
    #expect(throws: VaultCrypto.CryptoError.self) { try fresh.derivedID("deviceHost|x") }
    #expect(throws: VaultCrypto.CryptoError.self) { try fresh.hubVaultID() }

    try empty.addKeys(keys.allKeys)
    #expect(try fresh.derivedID("deviceHost|x") == wanted)
  }

  /// Beside a readable row, what names the earlier key waits as a server copy.
  @Test func idsWaitWhileAServerCopyNamesAnEarlierKey() throws {
    let real = try openStore(keys: keys, device: "real")
    try real.save(id: "h", kind: "host", changes: ["a": .string("b")])
    let wanted = try real.derivedID("x")

    let empty = MemoryKeyProvider(keys: [:])
    let fresh = try openStore(keys: empty, device: "fresh")
    try fresh.save(id: "h", kind: "host", changes: ["a": .string("mine")])
    #expect(try fresh.derivedID("x") != wanted)
    #expect(try fresh.apply(try sealedRemote(real, "h")) == .undecryptable)
    #expect(throws: VaultCrypto.CryptoError.self) { try fresh.derivedID("x") }
    try empty.addKeys(keys.allKeys)
    #expect(try fresh.derivedID("x") == wanted)
  }

  /// A vault's first device has nothing naming anything else, and goes by the key it made.
  @Test func aNewVaultDerivesFromTheKeyItMade() throws {
    let empty = MemoryKeyProvider(keys: [:])
    let first = try openStore(keys: empty)
    let id = try first.derivedID("x")
    try first.save(id: "h", kind: "host", changes: ["a": .string("b")])
    #expect(try first.derivedID("x") == id)
    #expect(empty.allKeys.keys.allSatisfy { $0.hasPrefix("n") })
  }

  /// A row of a recovery key's own doesn't say another key exists.
  @Test func aRowWithNoKeyNameOrARecoveryKeyDoesntHoldIDsUp() throws {
    let empty = MemoryKeyProvider(keys: [:])
    let first = try openStore(keys: empty)
    try first.save(id: "h", kind: "host", changes: ["a": .string("b")])
    try first.database.query("INSERT INTO items(id, kind, key_id, payload) VALUES('r', '', 'recovery-00', x'00'), ('e', '', '', x'00')")
    #expect(throws: Never.self) { try first.derivedID("x") }
  }

  // MARK: Ids with no id key

  private func waitingForTheIDKey() throws -> VaultStore {
    let real = try openStore(keys: keys, device: "real")
    try real.save(id: "h", kind: "host", changes: ["a": .string("b")])
    let store = try openStore(keys: MemoryKeyProvider(keys: [:]))
    _ = try store.apply(try sealedRemote(real, "h"))
    return store
  }

  /// A second clone can't look up an id nobody can make yet: it's a separate copy by what's here.
  @Test func aSecondCloneWithNoIDKeyKeepsBothPaths() throws {
    let store = try waitingForTheIDKey()
    let remote = "git@github.com:v57/Shell.git"
    let first = try store.addProject(path: "/work/one/Shell", remoteURL: remote)
    let second = try store.addProject(path: "/work/two/Shell", remoteURL: remote)
    #expect(first.id != second.id)
    #expect(second.separateCopy != nil)
    let paths = try store.records(VaultProject.self).compactMap { $0.paths["mac"] }.sorted()
    #expect(paths == ["/work/one/Shell", "/work/two/Shell"])
  }

  /// A keychain that's out of reach isn't an id key that's absent: nothing is made up, and it says so.
  @Test func aKeychainErrorMakesNoRandomID() throws {
    let base = MemoryKeyProvider()
    let flaky = FlakyKeys(base)
    let store = try openStore(keys: flaky)
    try store.save(id: "seed", kind: "host", changes: ["a": .string("b")])
    flaky.failing = true
    #expect(throws: (any Error).self) { try VaultHubServer.newID(url: "ws://192.168.1.2:1", in: store) }
    #expect(throws: (any Error).self) { try store.addProject(path: "/work/Shell", remoteURL: "git@github.com:v57/Shell.git") }
    flaky.failing = false
    #expect(try store.records(VaultProject.self).isEmpty)
  }

  /// Only an id key that's absent gets a random id, which the record's identity folds later.
  @Test func anAbsentIDKeyStillGetsARandomID() throws {
    let store = try waitingForTheIDKey()
    let id = try VaultHubServer.newID(url: "ws://192.168.1.2:1", in: store)
    #expect(id.contains("-"))
    let project = try store.addProject(path: "/work/Shell", remoteURL: "git@github.com:v57/Shell.git")
    #expect(project.id.contains("-"))
  }
}
