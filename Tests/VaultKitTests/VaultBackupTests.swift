import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// The encrypted backup (security audit H2, the gate before real data): everything comes back into an empty store and an
/// empty keychain, and nothing in the file reads without the passphrase. Memory only: no keychain is touched.
@Suite(.serialized)
struct VaultBackupTests {
  static let passphrase = "correct horse battery staple"
  /// Few rounds, so the tests run fast; the format carries the count.
  static let rounds = 1_000

  /// One device's vault: Personal and an account, the keys after a rotation, both groups' secrets, the identity and this
  /// device's own items.
  struct Device {
    let keys: MemoryKeyProvider
    let personal: VaultStore
    let account: VaultStore
    let secrets: VaultSecretTiers
    let identity: VaultSecretTiers
    let secretsShared = MemorySecretBacking()
    let secretsVaultOnly = MemorySecretBacking()
    let identityShared = MemorySecretBacking()
    let identityVaultOnly = MemorySecretBacking()

    init(keys: MemoryKeyProvider, directory: URL = temporaryDirectory()) throws {
      self.keys = keys
      personal = try VaultStore(directory: directory, keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
      account = try VaultStore(
        directory: directory, fileName: VaultAccountStores.fileName(forAccount: "work"), accountID: "work", keys: keys,
        deviceID: "mac", notifier: nil, owner: "mac")
      secrets = VaultSecretTiers(shared: secretsShared, vaultOnly: secretsVaultOnly)
      identity = VaultSecretTiers(shared: identityShared, vaultOnly: identityVaultOnly) { _ in true }
    }

    var sources: VaultBackup.Sources {
      .init(stores: [personal, account], keys: keys, secrets: secrets, identity: identity, deviceID: "mac", deviceName: "Mac")
    }

    func targets() -> VaultBackup.Targets {
      .init(keys: keys, secrets: secrets, identity: identity) { account in
        account == nil ? personal : account == "work" ? self.account : nil
      }
    }

    /// Every item of a store as it reads: id, kind, values and whether it's deleted.
    static func contents(_ store: VaultStore) throws -> [String: String] {
      Dictionary(uniqueKeysWithValues: try store.backupItems().items.map { item in
        let values = item.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return (item.id, "\(item.kind)|\(item.isDeleted)|\(values)")
      })
    }

    static func secrets(_ backing: MemorySecretBacking) throws -> [String: Data] {
      Dictionary(uniqueKeysWithValues: try backing.all().map { ($0.name, $0.data) })
    }
  }

  /// A vault with something of every kind in it.
  func filledDevice() throws -> Device {
    let device = try Device(keys: MemoryKeyProvider())
    let login = VaultLogin(title: "Mail", website: "mail.example.com", username: "me")
    try device.personal.save(login)
    try device.personal.save(VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy", auth: .password))
    try device.personal.save(VaultNote(folder: "Work", name: "Plan", text: "# Plan\nship it"))
    try device.personal.save(VaultNoteFile(path: "Images/a.png", data: Data([1, 2, 3])))
    let gone = VaultLogin(title: "Old")
    try device.personal.save(gone)
    try device.personal.delete(id: gone.id)
    try device.account.save(VaultLogin(title: "Work mail", username: "me@work"))
    // A rotation: the backup carries the old key, the new one and the epoch that orders them.
    try device.personal.rotateKeys(alongWith: [device.account])
    try device.personal.save(VaultLogin(title: "After the rotation"))

    try device.secretsShared.write(Data("host password".utf8), named: "password.prod", label: "")
    try device.secretsShared.write(Data("imported key".utf8), named: "database.sshkey.1", label: "")
    for (name, value) in [("login.\(login.id)", "login password"), ("otp.\(login.id)", "JBSWY3DP"), ("card.number.c", "4242"), ("passkey.p", "pk")] {
      try device.secretsVaultOnly.write(Data(value.utf8), named: name, label: "")
    }
    try device.identityVaultOnly.write(PersonalIdentity().rawRepresentation, named: VaultPersonalIdentity.account, label: "")
    for (name, value) in [("device-id", "mac"), ("ssh-identity", "blob"), ("hub.device-key", String(repeating: "k", count: 32)), ("other", "x")] {
      _ = try device.keys.items.add(Data(value.utf8), named: name, synced: false, label: "")
    }
    return device
  }

  @Test func everythingComesBackIntoAnEmptyStoreAndKeychain() throws {
    let device = try filledDevice()
    let file = try VaultBackup.make(from: device.sources, passphrase: Self.passphrase, rounds: Self.rounds)

    // Nothing readable in the file.
    let text = String(decoding: file, as: UTF8.self)
    for secret in ["host password", "login password", "Mail", "ship it", "Work mail", "4242"] { #expect(!text.contains(secret)) }

    let fresh = try Device(keys: MemoryKeyProvider(keys: [:]))
    let contents = try VaultBackup.open(file, passphrase: Self.passphrase)
    #expect(contents.deviceName == "Mac")
    #expect(contents.accountCount == 1)
    #expect(contents.hasVaultOnlySecrets)
    #expect(contents.leftOut == 0)
    let result = try VaultBackup.restore(contents, to: fresh.targets())

    // The keys, their rotation and the id key: the same key is current, and ids come out the same.
    #expect(fresh.keys.allKeys == device.keys.allKeys)
    #expect(try fresh.keys.keyEpochs == device.keys.keyEpochs)
    #expect(try fresh.keys.primary().id == device.keys.primary().id)
    #expect(try fresh.personal.derivedID("x") == device.personal.derivedID("x"))
    // Every record, the deleted one too, in Personal and in the account.
    #expect(try Device.contents(fresh.personal) == Device.contents(device.personal))
    #expect(try Device.contents(fresh.account) == Device.contents(device.account))
    #expect(try fresh.personal.records(VaultLogin.self).count == 2)
    #expect(try fresh.personal.records(VaultNote.self).first?.text == "# Plan\nship it")
    // Both groups' secrets, each in its own group, and the identity.
    #expect(try Device.secrets(fresh.secretsShared) == Device.secrets(device.secretsShared))
    #expect(try Device.secrets(fresh.secretsVaultOnly) == Device.secrets(device.secretsVaultOnly))
    #expect(try Device.secrets(fresh.identityVaultOnly) == Device.secrets(device.identityVaultOnly))
    // And they go up to iCloud: every restored record is in the outbox.
    #expect(try fresh.personal.pendingCount() == Device.contents(device.personal).count)
    #expect(try result.records == Device.contents(device.personal).count + Device.contents(device.account).count)
    #expect(result.secrets == 7)
    #expect(result.keptSecrets == 0)
    // This device's own keys only when asked for.
    #expect(result.deviceItems == 0)
    #expect(try fresh.keys.backupItems(synced: false).isEmpty)
  }

  @Test func thisDevicesOwnKeysComeBackOnlyWhenAskedAndOnlyAKeyItOpens() throws {
    let device = try filledDevice()
    let file = try VaultBackup.make(from: device.sources, passphrase: Self.passphrase, rounds: Self.rounds)
    let contents = try VaultBackup.open(file, passphrase: Self.passphrase)
    #expect(Set(contents.deviceItems.map(\.name)) == ["device-id", "ssh-identity", "hub.device-key"])

    let opensHere = VaultBackup.deviceKeyOpensHere
    defer { VaultBackup.deviceKeyOpensHere = opensHere }
    let fresh = try Device(keys: MemoryKeyProvider(keys: [:]))
    _ = try fresh.keys.items.add(Data("new-id".utf8), named: "device-id", synced: false, label: "")
    // Another device's Secure Enclave can't open the SSH key: left out.
    VaultBackup.deviceKeyOpensHere = { _ in false }
    var result = try VaultBackup.restore(contents, to: fresh.targets(), devicesOwnKeys: true)
    #expect(result.deviceItems == 2)
    #expect(try fresh.keys.items.read("device-id", synced: false) == Data("mac".utf8))
    #expect(try fresh.keys.items.read("ssh-identity", synced: false) == nil)

    VaultBackup.deviceKeyOpensHere = { _ in true }
    result = try VaultBackup.restore(contents, to: fresh.targets(), devicesOwnKeys: true)
    #expect(try fresh.keys.items.read("ssh-identity", synced: false) == Data("blob".utf8))
    #expect(try fresh.keys.items.read("other", synced: false) == nil)
  }

  /// Over a vault that's there: what changed since stays, a deletion since stays, and a secret of Vault's own that changed
  /// keeps the backup's value as a replaced one.
  @Test func restoringOverALiveVaultReplacesNothingNewer() throws {
    let device = try filledDevice()
    let file = try VaultBackup.make(from: device.sources, passphrase: Self.passphrase, rounds: Self.rounds)
    let contents = try VaultBackup.open(file, passphrase: Self.passphrase)

    let login = try #require(try device.personal.records(VaultLogin.self).first { $0.title == "Mail" })
    var edited = login
    edited.username = "me again"
    try device.personal.save(edited)
    let note = try #require(try device.personal.records(VaultNote.self).first)
    try device.personal.delete(id: note.id)
    try device.secretsVaultOnly.write(Data("new password".utf8), named: "login.\(login.id)", label: "")

    let result = try VaultBackup.restore(contents, to: device.targets())
    #expect(result.keys == 0)
    #expect(result.records == 0)
    #expect(result.keptSecrets == 1)
    #expect(try device.personal.record(VaultLogin.self, id: login.id)?.username == "me again")
    #expect(try device.personal.item(id: note.id)?.isDeleted == true)
    #expect(try device.secretsVaultOnly.read("login.\(login.id)") == Data("new password".utf8))
    #expect(try device.secretsVaultOnly.read("superseded.login.\(login.id)") == Data("login password".utf8))
  }

  @Test func theFileOpensOnlyWithItsPassphraseAndUnchanged() throws {
    let device = try filledDevice()
    let file = try VaultBackup.make(from: device.sources, passphrase: Self.passphrase, rounds: Self.rounds)
    #expect(VaultBackup.created(file) != nil)
    #expect(throws: VaultBackup.BackupError.wrongPassphrase) { try VaultBackup.open(file, passphrase: "correct horse battery stapler") }
    var changed = file
    changed[changed.count - 40] ^= 1
    #expect(throws: VaultBackup.BackupError.wrongPassphrase) { try VaultBackup.open(changed, passphrase: Self.passphrase) }
    // The header is authenticated too: fewer rounds written in don't open it.
    let tampered = Data(String(decoding: file, as: UTF8.self).replacingOccurrences(of: "\"rounds\":1000", with: "\"rounds\":999").utf8)
    if tampered != file {
      #expect(throws: (any Error).self) { try VaultBackup.open(tampered, passphrase: Self.passphrase) }
    }
    #expect(throws: VaultBackup.BackupError.notABackup) { try VaultBackup.open(Data("hello".utf8), passphrase: Self.passphrase) }
    #expect(throws: VaultBackup.BackupError.shortPassphrase) {
      try VaultBackup.make(from: device.sources, passphrase: "short", rounds: Self.rounds)
    }
    // The same passphrase typed in another Unicode form opens it.
    let accented = try VaultBackup.make(from: device.sources, passphrase: "pass phrase caf\u{E9}", rounds: Self.rounds)
    #expect(throws: Never.self) { try VaultBackup.open(accented, passphrase: "pass phrase cafe\u{301}") }
  }

  @Test func aDeviceWithNoKeysHasNothingToBackUp() throws {
    // No store opened yet, so no key was made.
    let tiers = VaultSecretTiers(shared: MemorySecretBacking(), vaultOnly: MemorySecretBacking())
    let sources = VaultBackup.Sources(stores: [], keys: MemoryKeyProvider(keys: [:]), secrets: tiers, identity: tiers, deviceID: "mac")
    #expect(throws: VaultBackup.BackupError.noKeys) {
      try VaultBackup.make(from: sources, passphrase: Self.passphrase, rounds: Self.rounds)
    }
  }

  /// RFC 6070-style vectors for PBKDF2-HMAC-SHA256, through CommonCrypto and the portable code the other systems run.
  @Test func pbkdf2MatchesTheKnownVectors() {
    let vectors: [(String, String, Int, String)] = [
      ("password", "salt", 1, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
      ("password", "salt", 2, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
      ("password", "salt", 4096, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
    ]
    for (password, salt, rounds, expected) in vectors {
      let p = Data(password.utf8)
      let s = Data(salt.utf8)
      #expect(hex(PBKDF2.sha256(password: p, salt: s, iterations: rounds)) == expected)
      #expect(hex(PBKDF2.portableSHA256(password: p, salt: s, iterations: rounds)) == expected)
    }
    // Longer than one block.
    let long = PBKDF2.portableSHA256(password: Data("passwd".utf8), salt: Data("salt".utf8), iterations: 1, length: 64)
    #expect(hex(long) == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
  }

  private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
