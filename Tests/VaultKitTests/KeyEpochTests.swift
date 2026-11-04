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
    for item in try a.items.all(synced: true) where !item.name.hasPrefix(VaultKeyRing.idKeyName) {
      _ = try b.items.add(item.data, named: item.name, synced: true, label: "")
    }
    #expect(try b.ring.primary().id == a.ring.primary().id)
    #expect(try VaultCrypto.derivedID("project", keys: b) == oldDerivedID("project", key: key))
  }

  @Test func theIDKeySyncsAsOneItem() throws {
    let a = MemoryKeyProvider()
    _ = try VaultCrypto.derivedID("x", keys: a)
    #expect(try a.items.read(VaultKeyRing.idKeyPrefix + "0000000000000001", synced: true) != nil)
    // Old builds read `key.` items as keys: nothing else may start with that.
    let names = try a.items.all(synced: true).map(\.name)
    #expect(names.filter { $0.hasPrefix(VaultKeyRing.keyPrefix) }.count == 1)
  }

  // MARK: Ids, and the keys they come from

  /// The first key's id comes from a rotation's claim: only a later key is here, so nothing is made up.
  @Test func aDeviceWithOnlyALaterKeyWaitsAndThenGetsTheSameIDs() throws {
    let first = SymmetricKey(size: .bits256)
    let a = MemoryKeyProvider(keys: ["0000000000000001": first])
    let id = try VaultCrypto.derivedID("project", keys: a)
    let epoch = try a.rotate(kitCheck: nil)
    let later = try #require(try a.key(id: epoch.keyID))

    // The rotation's key is the only item that arrived; its id says what it is.
    let alone = MemoryKeyProvider(keys: [epoch.keyID: later])
    #expect(throws: VaultCrypto.CryptoError.self) { try VaultCrypto.derivedID("project", keys: alone) }
    #expect(try alone.items.read(VaultKeyRing.idKeyName, synced: true) == nil)
    #expect(try alone.items.all(synced: true).allSatisfy { !$0.name.hasPrefix(VaultKeyRing.idKeyPrefix) })

    // The rotation's item arrives too, naming a first key that isn't here.
    let claim = try a.items.all(synced: true).first { $0.name.hasPrefix(VaultKeyRing.epochPrefix) }
    _ = try alone.items.add(try #require(claim).data, named: try #require(claim).name, synced: true, label: "")
    #expect(throws: VaultCrypto.CryptoError.self) { try VaultCrypto.derivedID("project", keys: alone) }

    // The id key alone is enough.
    let idKey = try #require(try a.items.read(VaultKeyRing.idKeyPrefix + "0000000000000001", synced: true))
    _ = try alone.items.add(idKey, named: VaultKeyRing.idKeyPrefix + "0000000000000001", synced: true, label: "")
    #expect(try VaultCrypto.derivedID("project", keys: alone) == id)
  }

  /// Two devices make different id keys in a first-key race, in the order that used to leave it to iCloud Keychain.
  @Test func twoIDKeysConvergeOnTheSmallerFirstKey() throws {
    let a = MemoryKeyProvider(keys: ["aaaa": SymmetricKey(size: .bits256)])
    let b = MemoryKeyProvider(keys: ["bbbb": SymmetricKey(size: .bits256)])
    let idA = try VaultCrypto.derivedID("x", keys: a)
    let idB = try VaultCrypto.derivedID("x", keys: b)
    #expect(idA != idB)
    a.items.receive(from: b.items)
    b.items.receive(from: a.items)
    #expect(try VaultCrypto.derivedID("x", keys: a) == idA)
    #expect(try VaultCrypto.derivedID("x", keys: b) == idA)
  }

  /// A device that found its keychain empty made a key before the vault's arrived. That can't move anyone's ids.
  @Test func aKeyMadeOnAnEmptyKeychainMovesNobodysIDs() throws {
    let vault = MemoryKeyProvider(keys: ["ffffffffffffffff": SymmetricKey(size: .bits256)])
    let id = try VaultCrypto.derivedID("x", keys: vault)
    let fresh = MemoryKeyProvider(keys: [:])
    let early = try VaultCrypto.derivedID("x", keys: fresh)
    let made = try fresh.primary().id
    #expect(made.hasPrefix("n") && made > "ffffffffffffffff")
    #expect(early != id)

    fresh.items.receive(from: vault.items)
    vault.items.receive(from: fresh.items)
    #expect(try VaultCrypto.derivedID("x", keys: vault) == id)
    #expect(try VaultCrypto.derivedID("x", keys: fresh) == id)
    #expect(try vault.primary().id == "ffffffffffffffff")
    #expect(try fresh.primary().id == "ffffffffffffffff")
  }

  /// Two first keys on empty keychains: the earlier wins on both, whichever arrives where.
  @Test func twoNewVaultsConvergeOnTheEarlierKey() throws {
    let earlier = VaultKeyRing.newFirstKeyID(now: Date(timeIntervalSince1970: 1_000))
    let later = VaultKeyRing.newFirstKeyID(now: Date(timeIntervalSince1970: 2_000))
    #expect(earlier < later)
    let a = MemoryKeyProvider(keys: [earlier: SymmetricKey(size: .bits256)])
    let b = MemoryKeyProvider(keys: [later: SymmetricKey(size: .bits256)])
    let id = try VaultCrypto.derivedID("x", keys: a)
    _ = try VaultCrypto.derivedID("x", keys: b)
    a.items.receive(from: b.items)
    b.items.receive(from: a.items)
    #expect(try a.primary().id == earlier && b.primary().id == earlier)
    #expect(try VaultCrypto.derivedID("x", keys: b) == id)
  }

  @Test func aRestoredIDKeyGoesFirst() throws {
    let a = MemoryKeyProvider()
    let restored = SymmetricKey(size: .bits256)
    _ = try a.stableIDKey()
    try a.restoreStableIDKey(restored)
    #expect(try a.stableIDKey() == restored)
    #expect(try a.stableIDKeySource() == nil)
  }

  /// A rotation's key without its item isn't current: another device's write can't be sealed under a key some haven't got.
  @Test func aRotationsKeyIsNeverCurrentWithoutItsItem() throws {
    let a = MemoryKeyProvider(keys: ["ffffffffffffffff": SymmetricKey(size: .bits256)])
    a.add(SymmetricKey(size: .bits256), id: VaultKeyRing.newRotationKeyID())
    #expect(try a.primary().id == "ffffffffffffffff")
  }

  @Test func marksStayWhereTheyWerePut() throws {
    let a = MemoryKeyProvider()
    try a.setMark("one", data: Data("1".utf8), synced: false)
    try a.setMark("two.a", data: Data("2".utf8), synced: true)
    try a.setMark("two.a", data: Data("3".utf8), synced: true)
    #expect(try a.marks(prefix: "one", synced: false).map(\.name) == ["one"])
    #expect(try a.marks(prefix: "one", synced: true).isEmpty)
    #expect(try a.marks(prefix: "two.", synced: true).map(\.data) == [Data("2".utf8)])
    #expect(try a.marks(prefix: "two", synced: false).isEmpty)
    try a.removeMark("two.a", synced: true)
    #expect(try a.marks(prefix: "two", synced: true).isEmpty)
  }
}
