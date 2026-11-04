import CryptoKit
import Foundation
import Testing

@testable import VaultKit

@Suite struct RecoveryCoverageTests {
  let keys = MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(size: .bits256)])
  let identity = MemorySecretBacking()
  let secrets = MemorySecretBacking()

  private func makeStore(_ device: String = "mac", keys: MemoryKeyProvider? = nil) throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys ?? self.keys, deviceID: device, notifier: nil, owner: device)
  }

  private func recovery(_ store: VaultStore) -> VaultRecovery {
    VaultRecovery(store: store, identity: identity, secrets: secrets)
  }

  /// A device whose keychain has nothing, with what the store holds.
  private func lostDevice(from store: VaultStore) throws -> (VaultStore, VaultRecovery, MemoryKeyProvider, MemorySecretBacking) {
    let newKeys = MemoryKeyProvider(keys: ["ffffffffffffffff": SymmetricKey(size: .bits256)])
    let phone = try makeStore("phone", keys: newKeys)
    try copy(store, to: phone)
    let lostSecrets = MemorySecretBacking()
    return (phone, VaultRecovery(store: phone, identity: MemorySecretBacking(), secrets: lostSecrets), newKeys, lostSecrets)
  }

  private func copy(_ from: VaultStore, to: VaultStore) throws {
    for id in try from.claimOutbox(limit: 10_000) {
      guard let record = try from.outgoing(id: id) else { continue }
      let tag = UUID().uuidString
      try from.markSent(id: id, version: record.version, changeTag: tag, systemFields: nil, sent: (record.keyID, record.payload))
      try to.apply(RemoteRecord(id: id, keyID: record.keyID, payload: record.payload, changeTag: tag, systemFields: nil))
    }
  }

  private func secretBlobs(_ store: VaultStore) throws -> [VaultRecoveryBlob] {
    try VaultRecovery(store: store, identity: identity, secrets: secrets).blobs().filter { $0.content == .secret }
  }

  // MARK: V4

  @Test func theKitCoversEveryKindOfSecret() async throws {
    let names = [
      "password.login-1", "otp.login-1", "card.number.card-1", "card.code.card-1", "passkey.pk-1", "password.db-1",
      "database.sshkey.\(UUID().uuidString)",
    ]
    for name in names { try secrets.write(Data("value of \(name)".utf8), named: name, label: "") }
    let mac = try makeStore()
    try mac.save(VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy"))
    let kit = try recovery(mac).create()

    #expect(try secretBlobs(mac).map(\.keyID).sorted() == names.sorted())
    #expect(try recovery(mac).wrapMissing() == 0)

    let (_, phoneRecovery, _, lost) = try lostDevice(from: mac)
    let recovered = try await phoneRecovery.recover(kit.qrText)
    #expect(recovered.secrets.count == names.count)
    for name in names { #expect(recovered.secrets[name] == Data("value of \(name)".utf8)) }
    let restored = try phoneRecovery.restore(recovered)
    #expect(restored.restoredSecrets.sorted() == names.sorted())
    for name in names { #expect(try lost.read(name) == Data("value of \(name)".utf8)) }
  }

  /// Passwords will live where only Vault and AutoFill read them: the vault key, which every app reads, must not open them.
  @Test func aSecretBlobDoesntOpenWithTheVaultKey() throws {
    try secrets.write(Data("hunter2".utf8), named: "password.x", label: "")
    let mac = try makeStore()
    _ = try recovery(mac).create()
    let blob = try #require(try secretBlobs(mac).first)
    #expect(!blob.sealed.contains(Data("hunter2".utf8)))
    // Whoever has the vault key has the record's fields, and the blob's box opens for the kit alone.
    for (_, key) in keys.allKeys {
      let raw = blob.sealed.dropFirst(33)
      #expect((try? VaultCrypto.open(Data(raw), key: key)) == nil)
    }
    #expect(RecoverySecret.random().publicKey != (try recovery(mac).key?.publicKey))
    #expect(throws: (any Error).self) { try blob.open(with: RecoverySecret.random()) }
    // The digest says nothing without a secret from the same place as the passwords.
    let unkeyed = Data(SHA256.hash(data: Data("password.x".utf8) + [0] + Data("hunter2".utf8))).map { String(format: "%02x", $0) }.joined()
    #expect(blob.digest != unkeyed)
  }

  @Test func aChangedSecretIsSealedAgain() async throws {
    try secrets.write(Data("first".utf8), named: "password.x", label: "")
    let mac = try makeStore()
    let kit = try recovery(mac).create()
    try secrets.write(Data("second".utf8), named: "password.x", label: "")
    #expect(try recovery(mac).wrapMissing() == 1)
    #expect(try recovery(mac).wrapMissing() == 0)

    try recovery(mac).secretChanged("password.x", value: Data("third".utf8))
    let (_, phone, _, _) = try lostDevice(from: mac)
    #expect(try await phone.recover(kit.qrText).secrets["password.x"] == Data("third".utf8))
  }

  /// A tombstone keeps its fields and syncs: a deleted secret's box has to go from it.
  @Test func aDeletedSecretLeavesNothingBehind() async throws {
    try secrets.write(Data("hunter2".utf8), named: "password.x", label: "")
    try secrets.write(Data("other".utf8), named: "password.y", label: "")
    let mac = try makeStore()
    let kit = try recovery(mac).create()
    let blob = try #require(try secretBlobs(mac).first { $0.keyID == "password.x" })

    try secrets.delete("password.x")
    try recovery(mac).secretChanged("password.x", value: nil)

    let item = try #require(try mac.item(id: blob.id))
    #expect(item.isDeleted)
    #expect(item.fields["sealed"] == .null)
    let (_, phone, _, _) = try lostDevice(from: mac)
    let recovered = try await phone.recover(kit.qrText)
    #expect(recovered.secrets["password.x"] == nil)
    #expect(recovered.secrets["password.y"] != nil)
    #expect(recovered.damaged == 0)
  }

  @Test func theHookReachesTheKit() throws {
    VaultSecrets.useInMemoryStore()
    let mac = try makeStore()
    let shared = VaultRecovery(store: mac, identity: identity, secrets: VaultSecrets.backing)
    _ = try shared.create()
    let name = "password.\(UUID().uuidString)"
    let blobID = try #require(shared.key).publicKey
    let before = VaultSecrets.didChange
    VaultSecrets.didChange = { name, value in try? shared.secretChanged(name, value: value) }
    defer { VaultSecrets.didChange = before }

    try VaultSecrets.setSecret(Data("v".utf8), named: name)
    let id = VaultRecoveryBlob.id(publicKey: blobID, content: .secret, keyID: name, folderID: nil)
    #expect(try mac.record(VaultRecoveryBlob.self, id: id) != nil)
    try VaultSecrets.setSecret(nil, named: name)
    #expect(try mac.record(VaultRecoveryBlob.self, id: id) == nil)
    #expect(try mac.item(id: id)?.fields["sealed"] == .null)
  }

  /// A secret that hasn't arrived here isn't a deleted one.
  @Test func aMissingSecretKeepsItsBlobWhileItsRecordLives() throws {
    let mac = try makeStore()
    let login = VaultHost(id: "x", name: "prod", hostname: "prod.example.com", user: "deploy")
    try mac.save(login)
    try secrets.write(Data("hunter2".utf8), named: "password.x", label: "")
    _ = try recovery(mac).create()
    try secrets.delete("password.x")

    #expect(try recovery(mac).wrapMissing() == 0)
    #expect(try secretBlobs(mac).map(\.keyID) == ["password.x"])

    // The record's gone: so is the blob.
    try mac.delete(id: "x")
    try recovery(mac).wrapMissing()
    #expect(try secretBlobs(mac).isEmpty)
  }

  @Test func nothingReadsTheKeychainWithTheKitOff() throws {
    final class Untouchable: VaultSecretBacking, @unchecked Sendable {
      func read(_ name: String) throws -> Data? { Issue.record("read"); return nil }
      func write(_ data: Data, named name: String, label: String) throws { Issue.record("write") }
      func addNew(_ data: Data, named name: String, label: String) throws -> Bool { Issue.record("add"); return false }
      func delete(_ name: String) throws { Issue.record("delete") }
      func all() throws -> [(name: String, data: Data)] { Issue.record("all"); return [] }
    }
    let mac = try makeStore()
    let off = VaultRecovery(store: mac, identity: Untouchable(), secrets: Untouchable())
    #expect(try off.wrapMissing() == 0)
    try off.secretChanged("password.x", value: Data("v".utf8))
  }

  @Test func aRestoreKeepsWhatTheDeviceHas() async throws {
    try secrets.write(Data("from the kit".utf8), named: "password.x", label: "")
    let mac = try makeStore()
    try mac.save(VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy"))
    let kit = try recovery(mac).create()
    let (_, phone, _, lost) = try lostDevice(from: mac)
    try lost.write(Data("newer here".utf8), named: "password.x", label: "")

    let restored = try phone.restore(try await phone.recover(kit.qrText))
    #expect(restored.keptSecrets == 1)
    #expect(restored.restoredSecrets.isEmpty)
    #expect(try lost.read("password.x") == Data("newer here".utf8))
  }

  // MARK: V5

  @Test func anOldKitDoesntGiveTheKeyThatReplacedIt() async throws {
    let mac = try makeStore()
    try mac.save(VaultHost(id: "h", name: "prod", hostname: "prod.example.com", user: "deploy"))
    let oldKit = try recovery(mac).create()
    // Someone copied the blobs before the kit was replaced.
    let copied = try recovery(mac).blobs()
    let oldKey = try keys.primary().id

    let newKit = try await recovery(mac).replace()
    let current = try keys.primary().id
    #expect(current != oldKey)
    #expect(try keys.isRetired(oldKey))
    #expect(try keys.kitCheck(forKey: current) == newKit.check)
    #expect(try mac.database.query("SELECT key_id FROM items WHERE id = 'h'")[0][0].text == current)
    #expect(try recovery(mac).check(newKit.qrText))

    // The old blobs give the old key and not the new one.
    let oldSecret = try RecoverySecret(parsing: oldKit.qrText)
    let opened = copied.compactMap { try? $0.open(with: oldSecret) }
    let currentBytes = try #require(try keys.key(id: current)).withUnsafeBytes { Data($0) }
    #expect(!opened.isEmpty)
    #expect(!opened.contains(currentBytes))
    // Nothing of the old kit is left, and the tombstones hold no boxes.
    for blob in copied {
      #expect(try mac.item(id: blob.id)?.isDeleted == true)
      #expect(try mac.item(id: blob.id)?.fields["sealed"] == .null)
    }
    // The new one recovers everything.
    let (phoneStore, phone, phoneKeys, _) = try lostDevice(from: mac)
    let recovered = try await phone.recover(newKit.qrText)
    #expect(recovered.vaultKeys[current] != nil)
    let restored = try phone.restore(recovered)
    #expect(restored.restoredKeys.contains(current))
    #expect(try phoneStore.record(VaultHost.self, id: "h")?.name == "prod")
    #expect(try phoneKeys.primary().id == restored.currentKey)
  }

  /// A device that has the new key through iCloud Keychain, before the record of the new kit reaches it.
  @Test func aDeviceThatHasntHeardOfTheNewKitDoesntSealTheNewKeyToTheOldOne() async throws {
    let mac = try makeStore()
    let pad = try makeStore("pad")
    _ = try recovery(mac).create()
    try copy(mac, to: pad)
    #expect(recovery(pad).isOn)
    let oldCheck = try #require(recovery(pad).key?.check)

    _ = try await recovery(mac).replace()
    // pad shares the keychain here, and has none of mac's new records yet.
    #expect(recovery(pad).key?.check == oldCheck)
    try recovery(pad).wrapMissing()
    let current = try keys.primary().id
    #expect(try recovery(pad).blobs().filter { $0.content == .vaultKey }.map(\.keyID).contains(current) == false)
  }

  @Test func turningOffLeavesNoBoxes() async throws {
    try secrets.write(Data("hunter2".utf8), named: "password.x", label: "")
    let mac = try makeStore()
    _ = try recovery(mac).create()
    let blobs = try recovery(mac).blobs()
    #expect(!blobs.isEmpty)
    try await recovery(mac).turnOff()
    for blob in blobs { #expect(try mac.item(id: blob.id)?.fields["sealed"] == .null) }
  }

  // MARK: V8

  /// Someone who kept the public key adds a blob naming a key of their own, to be made current on restore.
  @Test func aForgedBlobsKeyIsNotRestored() async throws {
    let mac = try makeStore()
    try mac.save(VaultHost(id: "h", name: "prod", hostname: "prod.example.com", user: "deploy"))
    let kit = try recovery(mac).create()
    let publicKey = try #require(recovery(mac).key).publicKey

    let forgedKey = SymmetricKey(size: .bits256)
    // Smaller than any real id: under the old rule it would have become the primary key.
    let forgedID = "0000000000000000"
    let forged = try VaultRecoveryBlob.seal(
      forgedKey.withUnsafeBytes { Data($0) }, publicKey: publicKey, content: .vaultKey, keyID: forgedID, folderID: nil)
    try mac.save(forged)

    let (phone, phoneRecovery, phoneKeys, _) = try lostDevice(from: mac)
    let recovered = try await phoneRecovery.recover(kit.qrText)
    #expect(recovered.vaultKeys[forgedID] == forgedKey)

    let restored = try phoneRecovery.restore(recovered)
    #expect(restored.refusedKeys == [forgedID])
    #expect(try phoneKeys.key(id: forgedID) == nil)
    #expect(try phoneKeys.primary().id == restored.currentKey)
    #expect(restored.currentKey != forgedID)
    #expect(try phone.record(VaultHost.self, id: "h")?.name == "prod")
  }

  /// A blob and a record under the same made-up key get the key back, as the kit can't tell who sealed a blob. Still it
  /// isn't current, and what arrives under it later is refused.
  @Test func aForgedKeyWithAForgedRecordIsNeverCurrent() async throws {
    let mac = try makeStore()
    try mac.save(VaultHost(id: "h", name: "prod", hostname: "prod.example.com", user: "deploy"))
    let kit = try recovery(mac).create()
    let publicKey = try #require(recovery(mac).key).publicKey
    let forgedKey = SymmetricKey(size: .bits256)
    let forgedID = "0000000000000000"
    try mac.save(
      try VaultRecoveryBlob.seal(
        forgedKey.withUnsafeBytes { Data($0) }, publicKey: publicKey, content: .vaultKey, keyID: forgedID, folderID: nil))

    let (phone, phoneRecovery, phoneKeys, _) = try lostDevice(from: mac)
    var fields = ItemFields()
    _ = fields.apply(["hostname": .string("evil")], clock: HybridClock.zero.next(now: .now, device: "x"))
    let body = try JSONEncoder().encode(fields)
    let record = try VaultItemSeal.seal(kind: "host", fields: body, id: "evil", account: "personal", keyID: forgedID, key: forgedKey)
    _ = try phone.apply(RemoteRecord(id: "evil", keyID: forgedID, payload: record, changeTag: "t", systemFields: nil))

    let restored = try phoneRecovery.restore(try await phoneRecovery.recover(kit.qrText))
    #expect(restored.restoredKeys.contains(forgedID))
    #expect(try phoneKeys.primary().id == restored.currentKey)
    #expect(try phoneKeys.isRetired(forgedID))

    let later = try VaultItemSeal.seal(kind: "host", fields: body, id: "later", account: "personal", keyID: forgedID, key: forgedKey)
    #expect(
      try phone.apply(RemoteRecord(id: "later", keyID: forgedID, payload: later, changeTag: "u", systemFields: nil))
        == .refused(needsSend: false))
  }

  /// A key moved in from somewhere else doesn't vouch for itself: the record it opens has to belong here.
  @Test func aRecordSealedForAnotherIDDoesntVouchForAKey() throws {
    let mac = try makeStore()
    let key = SymmetricKey(size: .bits256)
    var fields = ItemFields()
    _ = fields.apply(["a": .string("b")], clock: HybridClock.zero.next(now: .now, device: "x"))
    let sealed = try VaultItemSeal.seal(
      kind: "host", fields: try JSONEncoder().encode(fields), id: "elsewhere", account: "personal", keyID: "abcd", key: key)
    try mac.database.query("INSERT INTO items(id, kind, key_id, payload) VALUES('here', '', 'abcd', ?)", [.blob(sealed)])
    #expect(try mac.opensARecord(key: key, id: "abcd") == false)
  }

  @Test func aRestoredVaultKeepsItsIDs() async throws {
    let mac = try makeStore()
    try mac.save(VaultHost(id: "h", name: "prod", hostname: "prod.example.com", user: "deploy"))
    let id = try mac.derivedID("project")
    let hubID = try mac.hubVaultID()
    try mac.rotateKeys()
    let kit = try recovery(mac).create()

    let (phone, phoneRecovery, _, _) = try lostDevice(from: mac)
    // It hashed an id before: with a key of its own.
    #expect(try phone.derivedID("project") != id)
    _ = try phoneRecovery.restore(try await phoneRecovery.recover(kit.qrText))
    #expect(try phone.derivedID("project") == id)
    #expect(try phone.hubVaultID() == hubID)
    #expect(try phone.record(VaultHost.self, id: "h")?.name == "prod")
  }

  /// A store as an old build left it, with a kit: the blobs move over and still recover.
  @Test func aKitMovesToFormat2() async throws {
    let old = try OldBuildStore(keys: keys, device: "mac")
    let secret = RecoverySecret.random()
    let key = VaultRecoveryKey(publicKey: secret.publicKey)
    try old.save(id: VaultRecoveryKey.recordID, kind: VaultRecoveryKey.kind, changes: key.values)
    let vaultKey = try #require(try keys.key(id: "0000000000000001"))
    let blob = try VaultRecoveryBlob.seal(
      vaultKey.withUnsafeBytes { Data($0) }, publicKey: secret.publicKey, content: .vaultKey, keyID: "0000000000000001", folderID: nil)
    // Sealed with the record key, as the kit does.
    let recordKey = key.recordKey
    var fields = ItemFields()
    _ = fields.apply(blob.values, clock: HybridClock.zero.next(now: .now, device: "mac"))
    struct Plain: Encodable {
      let k: String
      let f: ItemFields
    }
    let sealed = try VaultCrypto.seal(try JSONEncoder().encode(Plain(k: VaultRecoveryBlob.kind, f: fields)), key: recordKey.key)
    try old.database.query(
      "INSERT INTO items(id, kind, key_id, payload, version) VALUES(?, ?, ?, ?, 1)",
      [.text(blob.id), .text(VaultRecoveryBlob.kind), .text(recordKey.id), .blob(sealed)])
    try old.save(id: "h", kind: "host", changes: ["hostname": .string("server")])

    let store = try VaultStore(directory: old.directory, keys: keys, deviceID: "mac", notifier: nil, owner: "t")
    #expect(store.isFormatFinished)
    #expect(store.formatStatus.unreadable == 0)
    let row = try store.database.query("SELECT key_id, payload FROM items WHERE id = ?", [.text(blob.id)])[0]
    #expect(row[0].text == recordKey.id)
    #expect(VaultItemSeal.parse(row[1].blob ?? Data()) != nil)
    let recovery = VaultRecovery(store: store, identity: identity, secrets: secrets)
    #expect(try recovery.blobs().map(\.id) == [blob.id])
    #expect(try await recovery.recover(RecoveryKit(secret: secret, created: .now).qrText).vaultKeys["0000000000000001"] == vaultKey)
  }
}

extension RecoveryCoverageTests {
  /// After a rotation nothing in the store is under the old key, but an encrypted note still is: it comes back.
  @Test func aRetiredKeyComesBackForTheFilesStillUnderIt() async throws {
    let mac = try makeStore()
    try mac.save(VaultHost(id: "h", name: "prod", hostname: "prod.example.com", user: "deploy"))
    let oldID = try keys.primary().id
    let note = try EncryptedNote.seal("my note", keys: keys)
    try mac.rotateKeys()
    let kit = try recovery(mac).create()
    #expect(try mac.database.query("SELECT 1 FROM items WHERE key_id = ?", [.text(oldID)]).isEmpty)

    let (_, phone, phoneKeys, _) = try lostDevice(from: mac)
    let restored = try phone.restore(try await phone.recover(kit.qrText))
    #expect(restored.restoredKeys.contains(oldID))
    #expect(restored.refusedKeys.isEmpty)
    #expect(try phoneKeys.isRetired(oldID))
    #expect(try EncryptedNote.open(note, keys: phoneKeys) == "my note")
  }

  /// The history names the key by fingerprint: another key under a listed id gets nothing.
  @Test func theHistoryDoesntVouchForAnotherKeyWithTheSameID() async throws {
    let mac = try makeStore()
    try mac.save(VaultHost(id: "h", name: "prod", hostname: "prod.example.com", user: "deploy"))
    let oldID = try keys.primary().id
    try mac.rotateKeys()
    #expect(try mac.keysInHistory(among: [oldID: try #require(try keys.key(id: oldID))]).count == 1)
    #expect(try mac.keysInHistory(among: [oldID: SymmetricKey(size: .bits256)]).isEmpty)
  }
}
