import CryptoKit
import Foundation
import Testing

@testable import VaultKit

struct RecoveryKitTests {
  /// A fixed secret, so the typo tests check the same cases every run.
  let secret = try! RecoverySecret(data: Data((0..<32).map { UInt8(($0 * 37 + 11) % 256) }))

  @Test func englishListIsBIP39() {
    let list = RecoveryWordList.english
    #expect(list.words.count == 2048)
    let file = Data((list.words.joined(separator: "\n") + "\n").utf8)
    #expect(
      SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
        == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
    #expect(RecoveryWordList(words: Array(list.words.dropLast())) == nil)
    #expect(RecoveryWordList(words: list.words.map { $0.uppercased() }) == nil)
  }

  @Test func bip39Vectors() throws {
    func words(_ byte: UInt8) throws -> String {
      try RecoverySecret(data: Data(repeating: byte, count: 32)).words().joined(separator: " ")
    }
    #expect(try words(0x00) == Array(repeating: "abandon", count: 23).joined(separator: " ") + " art")
    #expect(try words(0xFF) == Array(repeating: "zoo", count: 23).joined(separator: " ") + " vote")
    #expect(
      try words(0x7F)
        == "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
    )
    #expect(
      try words(0x80)
        == "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"
    )
  }

  @Test func wordsRoundTrip() throws {
    for _ in 0..<50 {
      let secret = RecoverySecret.random()
      let words = secret.words()
      #expect(words.count == 24)
      #expect(try RecoverySecret(words: words) == secret)
      #expect(try RecoverySecret(parsing: words.joined(separator: " ")) == secret)
    }
  }

  @Test func base32RoundTrip() throws {
    for _ in 0..<50 {
      let secret = RecoverySecret.random()
      #expect(secret.groups.count == 14)
      #expect(secret.groups.allSatisfy { $0.count == 4 })
      #expect(try RecoverySecret(base32: secret.groupedText) == secret)
      #expect(try RecoverySecret(parsing: secret.groupedText.lowercased()) == secret)
      #expect(try RecoverySecret(parsing: secret.groups.joined(separator: "  ")) == secret)
    }
  }

  @Test func parsingTolerance() throws {
    let words = secret.words()
    // Case, line numbers, commas, dashes and line breaks, as people copy a kit.
    let numbered = words.enumerated().map { "\($0 + 1). \($1.uppercased())" }.joined(separator: "\n")
    #expect(try RecoverySecret(parsing: numbered) == secret)
    #expect(try RecoverySecret(parsing: words.joined(separator: ", ")) == secret)
    #expect(try RecoverySecret(parsing: words.joined(separator: "-")) == secret)
    // The first four letters (or more) of each word.
    #expect(try RecoverySecret(parsing: words.map { String($0.prefix(4)) }.joined(separator: " ")) == secret)
    #expect(try RecoverySecret(parsing: words.map { String($0.prefix(5)) }.joined(separator: " ")) == secret)
    // Base32 without the digits it doesn't have: 0, 1 and 8 read as O, I and B.
    let confusable = secret.groupedText.replacingOccurrences(of: "O", with: "0")
      .replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "B", with: "8")
    #expect(try RecoverySecret(parsing: confusable) == secret)
  }

  @Test func unknownWordsAreReportedNotCorrected() throws {
    var words = secret.words()
    let original = words[4]
    words[4] = String(original.dropLast()) + (original.last == "x" ? "y" : "x")  // one letter changed
    words[9] = "qwertyuiop"
    do {
      _ = try RecoverySecret(parsing: words.joined(separator: " "))
      Issue.record("A mistyped word was accepted")
    } catch RecoveryKeyError.unknownWords(let unknown) {
      #expect(unknown.map(\.position) == [5, 10])
      #expect(unknown[0].typed == words[4])
      #expect(unknown[0].suggestions.contains(original))
      #expect(unknown[1].suggestions.isEmpty)
    }
    // Too few words.
    #expect(throws: RecoveryKeyError.wrongWordCount(23)) {
      try RecoverySecret(parsing: self.secret.words().dropLast().joined(separator: " "))
    }
  }

  @Test func checksumCatchesBase32Typos() throws {
    let text = Array(secret.groups.joined())
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var tried = 0
    for position in text.indices {
      for replacement in alphabet where replacement != text[position] {
        var typo = text
        typo[position] = replacement
        tried += 1
        #expect(throws: RecoveryKeyError.self) { try RecoverySecret(base32: String(typo)) }
        // A typo that reads as another secret would be a silent correction.
        #expect((try? RecoverySecret(base32: String(typo))) == nil)
      }
    }
    #expect(tried == 56 * 31)
    #expect(throws: RecoveryKeyError.wrongLength(55)) { try RecoverySecret(base32: String(text.dropLast())) }
    #expect(throws: RecoveryKeyError.invalidCharacter("9")) {
      try RecoverySecret(base32: "9" + String(text.dropFirst()))
    }
  }

  @Test func checksumCatchesWordTypos() throws {
    let words = secret.words()
    let list = RecoveryWordList.english
    var caught = 0
    var tried = 0
    for position in words.indices {
      for step in 1...40 {
        var typo = words
        typo[position] = list.words[(list.index(of: words[position])! + step * 47) % 2048]
        tried += 1
        if (try? RecoverySecret(words: typo)) == nil { caught += 1 }
      }
    }
    // An 8-bit checksum lets about 1 in 256 through; those match no recovery key (`VaultRecovery.check`).
    #expect(Double(caught) / Double(tried) > 0.98)
    // Two words swapped.
    var swapped = words
    swapped.swapAt(0, 1)
    if swapped != words { #expect((try? RecoverySecret(words: swapped)) == nil) }
  }

  @Test func kitText() throws {
    let kit = RecoveryKit(secret: secret, created: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(kit.qrText.hasPrefix("V57R1:"))
    #expect(kit.qrText.count == 6 + 56)
    // QR's alphanumeric set: digits, capitals, and a few symbols.
    #expect(kit.qrText.allSatisfy { $0.isNumber || ($0.isUppercase && $0.isASCII) || $0 == ":" })
    #expect(try RecoverySecret(parsing: kit.qrText) == secret)
    #expect(try RecoverySecret(parsing: kit.printText.components(separatedBy: "Or type: ")[1].prefix(69).description) == secret)
    #expect(kit.check == secret.check)
    #expect(kit.check.wholeMatch(of: /[0-9A-F]{4}-[0-9A-F]{4}/) != nil)
    #expect(kit.printText.contains(kit.check))
    for word in kit.words { #expect(kit.printText.contains(word)) }
    #expect(throws: RecoveryKeyError.unsupportedVersion("V57R2")) {
      try RecoverySecret(parsing: "V57R2:" + self.secret.groups.joined())
    }
    #expect(throws: RecoveryKeyError.unrecognized) { try RecoverySecret(parsing: "  ") }
  }

  @Test func derivedKeyIsStable() throws {
    let copy = try RecoverySecret(data: secret.data)
    #expect(copy.publicKey == secret.publicKey)
    #expect(secret.publicKey.count == 32)
    #expect(RecoverySecret.random().publicKey != secret.publicKey)
  }
}

struct RecoveryKeyTests {
  let keys = MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(size: .bits256), "0000000000000002": SymmetricKey(size: .bits256)])
  let identityBacking = MemorySecretBacking()
  let identity = PersonalIdentity()
  let folderKeys = [
    RecoveryFolderKey(folderID: "folder-a", keyID: "aaaa", keyData: Data(repeating: 1, count: 32)),
    RecoveryFolderKey(folderID: "folder-b", keyID: "bbbb", keyData: Data(repeating: 2, count: 32)),
  ]

  init() throws {
    _ = try identityBacking.addNew(identity.rawRepresentation, named: VaultPersonalIdentity.account, label: "")
  }

  func makeStore(_ device: String = "mac", keys: MemoryKeyProvider? = nil) throws -> VaultStore {
    try VaultStore(
      directory: temporaryDirectory(), keys: keys ?? self.keys, deviceID: device, notifier: nil, owner: device)
  }

  func recovery(_ store: VaultStore) -> VaultRecovery {
    VaultRecovery(store: store, identity: identityBacking)
  }

  /// Sends every pending record of `from` to `to`, as CloudKit would.
  func sync(_ from: VaultStore, to: VaultStore) throws {
    for id in try from.claimOutbox(limit: 10_000) {
      guard let record = try from.outgoing(id: id) else { continue }
      let tag = UUID().uuidString
      try from.markSent(
        id: id, version: record.version, changeTag: tag, systemFields: nil, sent: (record.keyID, record.payload))
      try to.apply(RemoteRecord(id: id, keyID: record.keyID, payload: record.payload, changeTag: tag, systemFields: nil))
    }
  }

  func expectAllKeys(_ recovered: RecoveredKeys) {
    #expect(recovered.vaultKeys.keys.sorted() == keys.allKeys.keys.sorted())
    for (id, key) in keys.allKeys { #expect(recovered.vaultKeys[id] == key) }
    #expect(recovered.identity?.rawRepresentation == identity.rawRepresentation)
    #expect(recovered.folderKeys == folderKeys)
    #expect(recovered.damaged == 0)
  }

  @Test func createAndRecover() async throws {
    let store = try makeStore()
    let recovery = recovery(store)
    #expect(!recovery.isOn)
    #expect(try recovery.wrapMissing() == 0)  // off: nothing is wrapped

    let kit = try recovery.create(folderKeys: folderKeys)
    #expect(recovery.isOn)
    #expect(recovery.key?.check == kit.check)
    #expect(kit.words.count == 24)
    // Two vault keys, the identity, two folder keys.
    #expect(try recovery.blobs().count == 5)
    #expect(throws: RecoveryKeyError.alreadyOn) { try recovery.create() }

    expectAllKeys(try await recovery.recover(kit.words.joined(separator: " ")))
    expectAllKeys(try await recovery.recover(kit.qrText))
    expectAllKeys(try await recovery.recover(kit.groupedText))
    // A well-formed key that isn't this one.
    await #expect(throws: RecoveryKeyError.doesNotMatch) {
      try await recovery.recover(RecoveryKit(secret: .random()).qrText)
    }
  }

  @Test func storesOnlyThePublicKey() throws {
    let store = try makeStore()
    let kit = try recovery(store).create()
    let secret = try RecoverySecret(parsing: kit.qrText)
    let record = try #require(try store.record(VaultRecoveryKey.self, id: VaultRecoveryKey.recordID))
    #expect(record.publicKey == secret.publicKey)
    let everything = try store.items(kind: VaultRecoveryKey.kind) + store.items(kind: VaultRecoveryBlob.kind)
    let text = everything.map { "\($0.values)" }.joined()
    #expect(!text.contains(secret.data.base64EncodedString()))
    #expect(!text.contains(secret.groups.joined()))
  }

  @Test func check() throws {
    let store = try makeStore()
    let recovery = recovery(store)
    #expect(throws: RecoveryKeyError.off) { try recovery.check(RecoveryKit(secret: .random()).qrText) }
    let kit = try recovery.create()
    #expect(try recovery.check(kit.words.joined(separator: " ")))
    #expect(try recovery.check(kit.qrText))
    #expect(try !recovery.check(RecoveryKit(secret: .random()).qrText))
    var typo = kit.words
    typo[3] = "zzzz"
    #expect(throws: RecoveryKeyError.self) { try recovery.check(typo.joined(separator: " ")) }
  }

  @Test func replaceRemovesOldBlobs() async throws {
    let store = try makeStore()
    let recovery = recovery(store)
    let remote = MemoryRemoteFileSystem()
    let folder = RecoveryRemoteFolder(remote: remote, path: "Sync/Photos", folderID: "folder-a")
    await #expect(throws: RecoveryKeyError.off) { try await recovery.replace() }

    let old = try recovery.create(folderKeys: folderKeys)
    try await recovery.writeBlobs(to: folder)
    let oldFiles = try await remote.list(folder.directory).map(\.name)
    #expect(oldFiles.count == 1)

    let new = try await recovery.replace(folderKeys: folderKeys, remotes: [folder])
    #expect(new.check != old.check)
    #expect(recovery.key?.check == new.check)
    let blobs = try recovery.blobs()
    #expect(blobs.count == 5)
    #expect(blobs.allSatisfy { $0.recoveryKey == new.check })
    let newFiles = try await remote.list(folder.directory).map(\.name)
    #expect(newFiles.count == 1)
    #expect(Set(newFiles).isDisjoint(with: oldFiles))

    await #expect(throws: RecoveryKeyError.doesNotMatch) { try await recovery.recover(old.qrText, remotes: [folder]) }
    #expect(try !recovery.check(old.qrText))
    expectAllKeys(try await recovery.recover(new.qrText))
  }

  @Test func turnOffRemovesEverything() async throws {
    let store = try makeStore()
    let recovery = recovery(store)
    let remote = MemoryRemoteFileSystem()
    let folders = [
      RecoveryRemoteFolder(remote: remote, path: "A", folderID: "folder-a"),
      RecoveryRemoteFolder(remote: remote, path: "B", folderID: "folder-b"),
    ]
    let kit = try recovery.create(folderKeys: folderKeys)
    for folder in folders { try await recovery.writeBlobs(to: folder) }
    try await remote.write(Data("members".utf8), to: "A/members")
    let ids = try recovery.blobs().map(\.id)

    try await recovery.turnOff(remotes: folders)
    #expect(!recovery.isOn)
    #expect(recovery.key == nil)
    #expect(try recovery.blobs().isEmpty)
    for id in ids { #expect(try store.item(id: id)?.isDeleted == true) }  // deletions sync like writes
    #expect(try await !remote.exists("A/recovery"))
    #expect(try await !remote.exists("B/recovery"))
    #expect(try await remote.exists("A/members"))
    await #expect(throws: RecoveryKeyError.self) { try await recovery.recover(kit.qrText, remotes: folders) }

    // Off: the hooks and the remote writes do nothing.
    #expect(try !recovery.wrap(vaultKey: SymmetricKey(size: .bits256), id: "0000000000000009"))
    #expect(try !recovery.wrap(folderKey: folderKeys[0]))
    try await recovery.writeBlobs(to: folders[0])
    #expect(try await !remote.exists("A/recovery"))
    try await recovery.turnOff()  // twice is fine

    // On again: a new key, and the blobs come back.
    let again = try recovery.create(folderKeys: folderKeys)
    #expect(again.check != kit.check)
    #expect(try recovery.blobs().count == 5)
  }

  @Test func hooksWrapNewKeys() async throws {
    let store = try makeStore()
    let recovery = recovery(store)
    let kit = try recovery.create(folderKeys: [folderKeys[0]])
    #expect(try recovery.blobs().count == 4)

    // A rotated vault key and a new folder.
    let newKey = SymmetricKey(size: .bits256)
    keys.add(newKey, id: "0000000000000003")
    #expect(try recovery.wrap(vaultKey: newKey, id: "0000000000000003"))
    #expect(try !recovery.wrap(vaultKey: newKey, id: "0000000000000003"))  // once
    #expect(try recovery.wrap(folderKey: folderKeys[1]))
    // A new identity (made again).
    let newIdentity = PersonalIdentity()
    #expect(try recovery.wrap(identity: newIdentity))
    #expect(try recovery.wrapMissing(folderKeys: folderKeys) == 0)

    let recovered = try await recovery.recover(kit.qrText)
    #expect(recovered.vaultKeys["0000000000000003"] == newKey)
    #expect(recovered.vaultKeys.count == 3)
    #expect(recovered.folderKeys == folderKeys)
    #expect(recovered.identity != nil)

    // A key that arrived through iCloud Keychain without a hook: wrapMissing finds it.
    keys.add(SymmetricKey(size: .bits256), id: "0000000000000004")
    #expect(try recovery.wrapMissing() == 1)
  }

  @Test func recoverOnNewDevice() async throws {
    // The Mac has the vault and a recovery key; everything syncs through CloudKit.
    let mac = try makeStore("mac")
    try mac.save(VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy"))
    let kit = try recovery(mac).create(folderKeys: folderKeys)

    // A new device whose iCloud Keychain lost everything: other vault keys, no identity.
    let newKeys = MemoryKeyProvider(keys: ["00000000000000ff": SymmetricKey(size: .bits256)])
    let phone = try makeStore("phone", keys: newKeys)
    try sync(mac, to: phone)
    let newIdentity = MemorySecretBacking()
    let phoneRecovery = VaultRecovery(store: phone, identity: newIdentity)
    #expect(try phone.records(VaultHost.self).isEmpty)
    #expect(!phoneRecovery.isOn)  // the public key record is sealed by the lost vault key
    #expect(try phoneRecovery.blobs().isEmpty)

    let recovered = try await phoneRecovery.recover(kit.words.joined(separator: " "))
    expectAllKeys(recovered)

    // Written back: the vault keys as the keychain names them, the identity where VaultPersonalIdentity reads it.
    let vaultKeyBacking = MemorySecretBacking()
    try recovered.restore(vaultKeys: vaultKeyBacking, identity: newIdentity)
    #expect(vaultKeyBacking.names.sorted() == keys.allKeys.keys.sorted().map { "key.\($0)" })
    for name in vaultKeyBacking.names {
      newKeys.add(SymmetricKey(data: try #require(try vaultKeyBacking.read(name))), id: String(name.dropFirst(4)))
    }
    #expect(try newIdentity.read(VaultPersonalIdentity.account) == identity.rawRepresentation)

    // The synced items open now, the recovery key included.
    #expect(try phone.records(VaultHost.self).map(\.name) == ["prod"])
    #expect(phoneRecovery.isOn)
    #expect(try phoneRecovery.check(kit.qrText))
  }

  @Test func blobsSyncWithoutTheVaultKey() throws {
    let mac = try makeStore("mac")
    _ = try recovery(mac).create(folderKeys: folderKeys)
    let (vaultKeyID, _) = try keys.primary()
    var sealedWith: [String: String] = [:]
    for id in try mac.claimOutbox(limit: 100) {
      let record = try #require(try mac.outgoing(id: id))
      sealedWith[id] = record.keyID
    }
    #expect(sealedWith[VaultRecoveryKey.recordID] == vaultKeyID)
    let blobKeys = Set(sealedWith.filter { $0.key != VaultRecoveryKey.recordID }.values)
    #expect(blobKeys.count == 1)
    #expect(blobKeys.first?.hasPrefix("recovery-") == true)
  }

  @Test func recoverFromRemoteOnly() async throws {
    // The Apple ID is gone: only the remote and the kit are left.
    let remote = MemoryRemoteFileSystem()
    let folder = RecoveryRemoteFolder(remote: remote, path: "Shared/Work", folderID: "folder-b")
    let mac = try makeStore("mac")
    let recovery = recovery(mac)
    let kit = try recovery.create(folderKeys: folderKeys)
    try await recovery.writeBlobs(to: folder)
    let files = try await remote.list(folder.directory)
    #expect(files.count == 1)
    let file = try await remote.read(files[0].path)
    #expect(String(decoding: file, as: UTF8.self).contains("folderKey"))

    let fresh = try makeStore("new", keys: MemoryKeyProvider(keys: ["00000000000000ff": SymmetricKey(size: .bits256)]))
    let recovered = try await VaultRecovery(store: fresh, identity: MemorySecretBacking())
      .recover(kit.qrText, remotes: [folder])
    #expect(recovered.folderKeys == [folderKeys[1]])
    #expect(recovered.vaultKeys.isEmpty)

    // A blob file moved to stand for another key doesn't open.
    var tampered = try JSONSerialization.jsonObject(with: file) as! [String: Any]
    tampered["keyID"] = "other"
    try await remote.write(try JSONSerialization.data(withJSONObject: tampered), to: files[0].path)
    await #expect(throws: RecoveryKeyError.damaged) {
      try await VaultRecovery(store: fresh, identity: MemorySecretBacking()).recover(kit.qrText, remotes: [folder])
    }
  }
}
