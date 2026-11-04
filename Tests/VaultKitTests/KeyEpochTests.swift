import CryptoKit
import Foundation
import Testing

@testable import VaultKit

@Suite struct KeyEpochTests {
  /// The formula ids came from before the id key.
  private func oldDerivedID(_ text: String, key: SymmetricKey) -> String {
    let idKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, info: Data("dev.v57.vault.ids".utf8), outputByteCount: 32)
    let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: idKey)
    return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  @Test func aVaultThatNeverRotatedKeepsTheSmallestIDAsCurrent() throws {
    let keys = MemoryKeyProvider(keys: ["bb": SymmetricKey(size: .bits256), "aa": SymmetricKey(size: .bits256)])
    #expect(try keys.primary().id == "aa")
    #expect(try keys.keyEpochs.isEmpty)
    #expect(try keys.isRetired("aa") == false)
    #expect(try keys.isRetired("bb") == false)
  }

  @Test func aRotationMakesANewKeyCurrentEvenWithALargerID() throws {
    let keys = MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(size: .bits256)])
    let epoch = try keys.rotate(kitCheck: nil)
    #expect(epoch.epoch == 1)
    #expect(try keys.primary().id == epoch.keyID)
    #expect(try keys.isRetired("0000000000000001"))
    #expect(try keys.isRetired(epoch.keyID) == false)
    // The old key stays: encrypted notes and rows not re-sealed yet still open with it.
    #expect(try keys.key(id: "0000000000000001") != nil)

    let next = try keys.rotate(kitCheck: nil)
    #expect(next.epoch == 2)
    #expect(try keys.primary().id == next.keyID)
    #expect(try keys.isRetired(epoch.keyID))
  }

  @Test func concurrentRotationsSettleOnTheSameKey() throws {
    let first = SymmetricKey(size: .bits256)
    let a = MemoryKeyProvider(keys: ["0000000000000001": first])
    let b = MemoryKeyProvider(keys: ["0000000000000001": first])
    let fromA = try a.rotate(kitCheck: nil)
    let fromB = try b.rotate(kitCheck: nil)
    #expect(fromA.epoch == fromB.epoch)
    a.items.receive(from: b.items)
    b.items.receive(from: a.items)
    #expect(try a.primary().id == max(fromA.keyID, fromB.keyID))
    #expect(try b.primary().id == max(fromA.keyID, fromB.keyID))
    // Neither is retired: both devices sealed under theirs in the meantime.
    #expect(try a.isRetired(fromA.keyID) == false)
    #expect(try a.isRetired(fromB.keyID) == false)
    #expect(try a.isRetired("0000000000000001"))
  }

  @Test func aNewKeyWhoseRotationHasNotArrivedIsNotCurrentOrRetired() throws {
    let first = SymmetricKey(size: .bits256)
    let a = MemoryKeyProvider(keys: ["0000000000000001": first])
    let b = MemoryKeyProvider(keys: ["0000000000000001": first])
    let epoch = try a.rotate(kitCheck: nil)
    let second = try a.rotate(kitCheck: nil)
    // b has the first rotation, and the second's key but not its epoch item: they arrive one by one.
    b.items.receive(from: a.items)
    let partial = MemoryKeyProvider(keys: [
      "0000000000000001": first, epoch.keyID: try #require(try a.key(id: epoch.keyID)),
      second.keyID: try #require(try a.key(id: second.keyID)),
    ])
    #expect(try b.primary().id == second.keyID)
    #expect(try partial.keyEpochs.isEmpty)
    #expect(try partial.isRetired(second.keyID) == false)
  }

  @Test func kitCheckStaysWithItsRotation() throws {
    let keys = MemoryKeyProvider()
    let epoch = try keys.rotate(kitCheck: "abc")
    #expect(try keys.kitCheck(forKey: epoch.keyID) == "abc")
    let plain = try keys.rotate(kitCheck: nil)
    #expect(try keys.kitCheck(forKey: plain.keyID) == nil)
  }

  @Test func idsAreTheOnesTheyAlwaysWere() throws {
    let key = SymmetricKey(size: .bits256)
    let keys = MemoryKeyProvider(keys: ["0000000000000001": key])
    #expect(try VaultCrypto.derivedID("hello", keys: keys) == oldDerivedID("hello", key: key))
  }

  @Test func idsDoNotChangeWithARotation() throws {
    let key = SymmetricKey(size: .bits256)
    let keys = MemoryKeyProvider(keys: ["0000000000000001": key])
    let before = try VaultCrypto.derivedID("project", keys: keys)
    try keys.rotate(kitCheck: nil)
    #expect(try VaultCrypto.derivedID("project", keys: keys) == before)
  }

  /// A first use after someone else's rotation arrived: the id key still comes from the key from before it.
  @Test func aDeviceThatFirstHashesAfterARotationGetsTheSameIDs() throws {
    let key = SymmetricKey(size: .bits256)
    let a = MemoryKeyProvider(keys: ["0000000000000001": key])
    let b = MemoryKeyProvider(keys: ["0000000000000001": key])
    try a.rotate(kitCheck: nil)
    // Everything but the id key arrived.
    for item in try a.items.all(synced: true) where item.name != VaultKeyRing.idKeyName {
      _ = try b.items.add(item.data, named: item.name, synced: true, label: "")
    }
    #expect(try b.ring.primary().id == a.ring.primary().id)
    #expect(try VaultCrypto.derivedID("project", keys: b) == oldDerivedID("project", key: key))
  }

  @Test func theIDKeySyncsAsOneItem() throws {
    let a = MemoryKeyProvider()
    _ = try VaultCrypto.derivedID("x", keys: a)
    #expect(try a.items.read(VaultKeyRing.idKeyName, synced: true) != nil)
    // Old builds read `key.` items as keys: nothing else may start with that.
    let names = try a.items.all(synced: true).map(\.name)
    #expect(names.filter { $0.hasPrefix(VaultKeyRing.keyPrefix) }.count == 1)
  }

  @Test func marksStayWhereTheyWerePut() throws {
    let a = MemoryKeyProvider()
    try a.setMark("one", synced: false)
    try a.setMark("two", synced: true)
    try a.setMark("two", synced: true)
    #expect(try a.hasMark("one", synced: false))
    #expect(try a.hasMark("one", synced: true) == false)
    #expect(try a.hasMark("two", synced: true))
    #expect(try a.hasMark("two", synced: false) == false)
  }
}
