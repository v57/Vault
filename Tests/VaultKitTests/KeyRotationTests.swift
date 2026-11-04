import CryptoKit
import Foundation
import Testing

@testable import VaultKit

private func open(_ directory: URL = temporaryDirectory(), keys: VaultKeyProvider, device: String = "mac") throws -> VaultStore {
  try VaultStore(directory: directory, keys: keys, deviceID: device, notifier: nil, owner: "test")
}

private func keyColumn(_ store: VaultStore, _ id: String) throws -> String {
  try store.database.query("SELECT key_id FROM items WHERE id = ?", [.text(id)])[0][0].text ?? ""
}

@Suite struct KeyRotationTests {
  /// Two devices with one key; `b` gets what iCloud Keychain brings when `deliver` runs.
  private func twoDevices() throws -> (cloud: FakeCloud, a: FakeApp, b: FakeApp, keysA: MemoryKeyProvider, keysB: MemoryKeyProvider) {
    let cloud = FakeCloud()
    let keysA = MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(size: .bits256)])
    let keysB = MemoryKeyProvider(keys: keysA.allKeys)
    let a = try FakeApp(directory: temporaryDirectory(), keys: keysA, device: "a", name: "A")
    let b = try FakeApp(directory: temporaryDirectory(), keys: keysB, device: "b", name: "B")
    try a.store.save(id: "h", kind: "host", changes: ["hostname": .string("server")])
    a.sync(cloud)
    b.sync(cloud)
    return (cloud, a, b, keysA, keysB)
  }

  @Test func rotatingSealsEverythingAgainUnderTheNewKey() throws {
    let keys = MemoryKeyProvider()
    let store = try open(keys: keys)
    try store.save(id: "h", kind: "host", changes: ["hostname": .string("server")])
    try store.save(id: "gone", kind: "login", changes: ["user": .string("x")])
    try store.delete(id: "gone")
    let hubID = try store.hubVaultID()

    let rotation = try store.rotateKeys()
    #expect(rotation.epoch.epoch == 1)
    #expect(rotation.rewritten == 2)
    #expect(try keyColumn(store, "h") == rotation.epoch.keyID)
    #expect(try keyColumn(store, "gone") == rotation.epoch.keyID)
    #expect(try store.item(id: "h")?.fields["hostname"]?.stringValue == "server")
    #expect(try store.item(id: "gone")?.isDeleted == true)
    #expect(try store.pendingIDs().isSuperset(of: ["h", "gone"]))
    // The mailbox and every derived id stay as they were.
    #expect(try store.hubVaultID() == hubID)
    // Nothing left to do.
    #expect(try store.catchUp().isEmpty)
  }

  @Test func accountStoresRotateToo() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let personal = try open(directory, keys: keys)
    let account = try VaultStore(
      directory: directory, fileName: "acme.sqlite", accountID: "acme", keys: keys, deviceID: "mac", notifier: nil, owner: "test")
    try account.save(id: "h", kind: "host", changes: ["hostname": .string("acme")])
    let rotation = try personal.rotateKeys(alongWith: [account])
    #expect(try keyColumn(account, "h") == rotation.epoch.keyID)
  }

  @Test func folderKeysAreWrappedAgain() throws {
    let keys = MemoryKeyProvider()
    let store = try open(keys: keys)
    let secret = Data(repeating: 9, count: 33)
    let first = try VaultCrypto.seal(secret, keys: keys)
    let keyName = Data(first.keyID.utf8)
    let wrapped = (Data([1, UInt8(keyName.count)]) + keyName + first.ciphertext).base64EncodedString()
    try store.save(VaultFolder(id: "f", name: "Folder", wrappedKey: wrapped))

    let rotation = try store.rotateKeys()
    let again = try #require(try store.record(VaultFolder.self, id: "f")?.wrappedKey)
    #expect(again != wrapped)
    let data = try #require(Data(base64Encoded: again))
    let length = Int(data[1])
    #expect(String(decoding: data[2..<2 + length], as: UTF8.self) == rotation.epoch.keyID)
    #expect(try VaultCrypto.open(Data(data[(2 + length)...]), keyID: rotation.epoch.keyID, keys: keys) == secret)
  }

  /// The device that's gone still has the old key, and isn't in the Apple account any more: no new one reaches it.
  @Test func aRemovedDeviceCantWriteAfterARotation() throws {
    let (cloud, a, removed, _, _) = try twoDevices()
    let rotation = try a.store.rotateKeys()
    a.sync(cloud)
    #expect(cloud.records["h"].flatMap { VaultItemSeal.parse($0.payload)?.keyID } == rotation.epoch.keyID)

    // It writes a new record and changes one it knows, under the old key.
    try removed.store.save(id: "evil", kind: "knownHost", changes: ["fingerprint": .string("SHA256:evil")])
    try removed.store.save(id: "h", kind: "host", changes: ["hostname": .string("evil.example")])
    removed.sync(cloud)
    #expect(cloud.records["evil"] != nil)

    a.sync(cloud)
    #expect(try a.store.item(id: "evil") == nil)
    #expect(try a.store.allIDs().contains("evil") == false)
    #expect(try a.store.item(id: "h")?.fields["hostname"]?.stringValue == "server")
    #expect(a.store.formatStatus.refused >= 1)
    // Its copy of `h` was on the server and is replaced by the real one.
    #expect(cloud.records["h"].flatMap { VaultItemSeal.parse($0.payload)?.keyID } == rotation.epoch.keyID)

    // It can't read what's new either.
    try a.store.save(id: "after", kind: "login", changes: ["user": .string("new")])
    a.sync(cloud)
    removed.sync(cloud)
    #expect(try removed.store.item(id: "after") == nil)
  }

  @Test func aRemovedDeviceCantWriteThroughAHubEither() throws {
    let (_, a, removed, _, _) = try twoDevices()
    try removed.store.save(id: "evil", kind: "knownHost", changes: ["fingerprint": .string("SHA256:evil")])
    let row = try removed.store.database.query("SELECT key_id, payload FROM items WHERE id = 'evil'")[0]
    try a.store.rotateKeys()
    #expect(try a.store.applyFromPeer(id: "evil", keyID: row[0].text ?? "", payload: row[1].blob ?? Data()) == .refused)
    #expect(try a.store.item(id: "evil") == nil)
  }

  /// A record written under a retired key that arrived before that key did never opened, and doesn't open when the key
  /// shows up: it's a placeholder nobody checked.
  @Test func aPlaceholderUnderARetiredKeyStaysShut() throws {
    let keys = MemoryKeyProvider()
    let oldKey = SymmetricKey(size: .bits256)
    let store = try open(keys: keys)
    var fields = ItemFields()
    _ = fields.apply(["hostname": .string("evil")], clock: HybridClock.zero.next(now: .now, device: "x"))
    let sealed = try VaultItemSeal.seal(
      kind: "host", fields: try JSONEncoder().encode(fields), id: "h", account: "personal", keyID: "aaaa", key: oldKey)
    #expect(try store.apply(RemoteRecord(id: "h", keyID: "aaaa", payload: sealed, changeTag: "t", systemFields: nil)) == .undecryptable)
    keys.add(oldKey, id: "aaaa")
    try keys.rotate(kitCheck: nil)
    #expect(try store.item(id: "h") == nil)
    #expect(try store.items(kind: "host").isEmpty)
  }

  /// B is still in the Apple account: the key reaches it, late. Its edits made in the meantime aren't lost.
  @Test func aDeviceThatHearsLateConverges() throws {
    let (cloud, a, b, keysA, keysB) = try twoDevices()
    try a.store.rotateKeys()
    a.sync(cloud)

    // B writes under the old key; A refuses it.
    try b.store.save(id: "h", kind: "host", changes: ["port": .int(2222)])
    b.sync(cloud)
    try b.store.save(id: "from-b", kind: "note", changes: ["text": .string("hello")])
    b.sync(cloud)
    a.sync(cloud)
    #expect(try a.store.item(id: "from-b") == nil)
    // Nor can B read A's copy yet; its own row stays readable.
    #expect(try b.store.item(id: "h")?.fields["port"] == .int(2222))

    keysB.items.receive(from: keysA.items)
    #expect(try b.store.catchUp().contains("from-b"))
    #expect(try keysB.isRetired(try keyColumn(b.store, "from-b")) == false)
    b.sync(cloud)
    a.sync(cloud)
    b.sync(cloud)
    for app in [a, b] {
      #expect(try app.store.item(id: "h")?.fields["port"] == .int(2222))
      #expect(try app.store.item(id: "h")?.fields["hostname"]?.stringValue == "server")
      #expect(try app.store.item(id: "from-b")?.fields["text"]?.stringValue == "hello")
    }
    #expect(try a.store.pendingCount() == 0)
    #expect(try b.store.pendingCount() == 0)
  }

  @Test func rotationsOnTwoDevicesConverge() throws {
    let (cloud, a, b, keysA, keysB) = try twoDevices()
    let fromA = try a.store.rotateKeys()
    let fromB = try b.store.rotateKeys()
    a.sync(cloud)
    b.sync(cloud)
    keysA.items.receive(from: keysB.items)
    keysB.items.receive(from: keysA.items)
    try a.store.save(id: "after", kind: "login", changes: ["user": .string("a")])
    try b.store.save(id: "after2", kind: "login", changes: ["user": .string("b")])
    let winner = max(fromA.epoch.keyID, fromB.epoch.keyID)
    #expect(try keysA.primary().id == winner)
    #expect(try keysB.primary().id == winner)
    for _ in 0..<3 {
      a.sync(cloud)
      b.sync(cloud)
    }
    for app in [a, b] {
      #expect(try app.store.item(id: "h")?.fields["hostname"]?.stringValue == "server")
      #expect(try app.store.item(id: "after")?.fields["user"]?.stringValue == "a")
      #expect(try app.store.item(id: "after2")?.fields["user"]?.stringValue == "b")
    }
  }

  /// The rotation's epoch item came through but the key didn't: there's nothing better to seal with.
  @Test func aDeviceWithoutTheNewKeyDoesntSpinOnRows() throws {
    let keys = MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(size: .bits256)])
    let store = try open(keys: keys)
    try store.save(id: "h", kind: "host", changes: ["hostname": .string("server")])
    let claim = VaultKeyEpoch(epoch: 1, keyID: "ffff")
    _ = try keys.items.add(
      try JSONEncoder().encode(VaultKeyRing.Claim(kit: nil, retired: ["0000000000000001"])),
      named: VaultKeyRing.epochName(claim), synced: true, label: "")
    #expect(try keys.primary().id == "0000000000000001")
    #expect(try store.catchUp().isEmpty)
    #expect(try store.item(id: "h")?.fields["hostname"]?.stringValue == "server")
  }

  /// Killed after the keychain changed and before the rows did: the next look carries on.
  @Test func anInterruptedRotationFinishesOnTheNextCatchUp() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let store = try open(directory, keys: keys)
    try store.save(id: "h", kind: "host", changes: ["hostname": .string("server")])
    let epoch = try keys.rotate(kitCheck: nil)

    let next = try open(directory, keys: keys)
    #expect(try next.catchUp() == ["h"])
    #expect(try keyColumn(next, "h") == epoch.keyID)
  }

  // MARK: Revoked devices

  private static let key =
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKZG lost"

  private func store() throws -> VaultStore {
    VaultSecrets.useInMemoryStore()
    return try open(keys: MemoryKeyProvider())
  }

  @Test func aRevokedDeviceDoesntComeBackByItself() throws {
    let store = try store()
    let lost = VaultDeviceKey(id: "lost", deviceName: "Lost Mac", publicKey: Self.key, platform: "macOS")
    try store.save(lost)
    try store.revokeDevice(lost)
    #expect(try store.record(VaultDeviceKey.self, id: "lost") == nil)
    #expect(try store.isRevoked(device: "lost"))
    #expect(try store.trustedDeviceKeys().isEmpty)

    // It publishes itself again, an old build or someone holding it.
    try store.save(lost)
    let sorted = try store.deviceKeysByTrust()
    #expect(sorted.trusted.isEmpty)
    #expect(sorted.revoked.map(\.id) == ["lost"])
    // And under another id with the same key.
    try store.save(VaultDeviceKey(id: "other", deviceName: "Renamed", publicKey: Self.key, platform: "macOS"))
    #expect(try store.trustedDeviceKeys().isEmpty)

    // A device reads the list and stops by itself.
    let itself = try open(store.directory, keys: store.keys, device: "lost")
    try itself.delete(id: "lost")
    #expect(try itself.publishDeviceHost(name: "x", address: "x.local", user: "me", hostKey: nil, allowed: []) == false)
    #expect(try itself.record(VaultHost.self, id: try itself.deviceHostID(device: "lost")) == nil)

    try store.trustAgain(device: "lost")
    #expect(try store.isRevoked(device: "lost") == false)
    #expect(try store.trustedDeviceKeys().map(\.id).sorted() == ["other"])
  }

  @Test func aDeviceCantRevokeItself() throws {
    let store = try store()
    let own = VaultDeviceKey(id: "mac", deviceName: "This", publicKey: Self.key, platform: "macOS")
    #expect(throws: VaultDeviceError.self) { try store.revokeDevice(own) }
  }

  @Test @MainActor func aRevokedDevicesLineGoesFromAMacThatLetsItIn() throws {
    let store = try store()
    let lost = VaultDeviceKey(id: "lost", deviceName: "Lost Mac", publicKey: Self.key, platform: "macOS")
    try store.save(lost)
    let file = temporaryDirectory().appendingPathComponent("authorized_keys")
    let keys = VaultAuthorizedKeys(url: file)
    try keys.allow(lost)

    let vault = Vault(store: store)
    #expect(vault.deviceKeys.map(\.id) == ["lost"])
    #expect(try keys.removeStale(keeping: vault.deviceKeys) == false)

    try store.revokeDevice(lost)
    try store.save(lost)
    vault.reload(force: true)
    #expect(vault.deviceKeys.isEmpty)
    #expect(vault.untrustedDeviceKeys.map(\.id) == ["lost"])
    #expect(vault.revokedDevices.map(\.deviceID) == ["lost"])
    #expect(try keys.removeStale(keeping: vault.deviceKeys))
    #expect(try keys.entries().isEmpty)
  }

  @Test @MainActor func aRevokedDevicesHostIsHidden() throws {
    let store = try store()
    let lost = VaultDeviceKey(id: "lost", deviceName: "Lost Mac", publicKey: Self.key, platform: "macOS")
    try store.save(lost)
    try store.revokeDevice(lost)
    let route = VaultHost.DeviceRoute(deviceID: "lost", address: "lost.local", hostKey: nil, allowed: [])
    var host = VaultHost(id: "published", name: "Lost", hostname: "lost.local", port: 22, user: "me", source: "device")
    host.device = route
    try store.save(host)
    let vault = Vault(store: store)
    #expect(vault.hosts.isEmpty)
  }

  // MARK: The sweep

  private func runSweep(_ command: String, home: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }

  private func home(with text: String?) throws -> (home: URL, file: URL) {
    let home = temporaryDirectory()
    let ssh = home.appendingPathComponent(".ssh")
    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
    let file = ssh.appendingPathComponent("authorized_keys")
    if let text {
      try text.write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    return (home, file)
  }

  private let material = "ssh-ed25519 QUFBQQ=="
  private let other = "ssh-ed25519 QkJCQg== someone@laptop"

  @Test func theSweepTakesTheDevicesLinesAndKeepsTheRest() throws {
    let (home, file) = try home(
      with: "\(other)\n\(material) v57-device=lost Lost Mac\nfrom=\"10.0.0.1\" \(material) by hand\nssh-ed25519 Q0NDQw== v57-device=lost Old key\nssh-ed25519 RERERA== v57-device=lost2 Another\n")
    let command = try #require(VaultAuthorizedKeys.sweepCommand(device: "lost", publicKey: "\(material) Lost Mac"))
    let result = try runSweep(command, home: home)
    #expect(result.status == 0)
    #expect(VaultAuthorizedKeys.sweptLines(from: result.output) == 3)
    let left = try String(contentsOf: file, encoding: .utf8)
    #expect(left == "\(other)\nssh-ed25519 RERERA== v57-device=lost2 Another\n")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["authorized_keys"])
  }

  @Test func theSweepCopesWithNoFileAndNoMatch() throws {
    let command = try #require(VaultAuthorizedKeys.sweepCommand(device: "lost", publicKey: "\(material) Lost Mac"))
    let (empty, _) = try home(with: nil)
    #expect(VaultAuthorizedKeys.sweptLines(from: try runSweep(command, home: empty).output) == 0)
    let (keep, file) = try home(with: "\(other)\n")
    #expect(VaultAuthorizedKeys.sweptLines(from: try runSweep(command, home: keep).output) == 0)
    #expect(try String(contentsOf: file, encoding: .utf8) == "\(other)\n")
    // Every line goes: grep says "nothing selected", which is no failure.
    let (all, allFile) = try home(with: "\(material) v57-device=lost x\n")
    #expect(VaultAuthorizedKeys.sweptLines(from: try runSweep(command, home: all).output) == 1)
    #expect(try String(contentsOf: allFile, encoding: .utf8).isEmpty)
  }

  /// A device record is synced data: whatever's in it stays a quoted pattern.
  @Test func aRecordCantBreakOutOfTheSweep() throws {
    let (home, file) = try home(with: "\(other)\n")
    let canary = home.appendingPathComponent("canary").path
    let evil = "x'; touch \(canary); echo '"
    let command = try #require(VaultAuthorizedKeys.sweepCommand(device: evil, publicKey: "not a key"))
    let result = try runSweep(command, home: home)
    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: canary))
    #expect(try String(contentsOf: file, encoding: .utf8) == "\(other)\n")

    // A line break would make a second, empty pattern, which matches every line.
    #expect(VaultAuthorizedKeys.sweepCommand(device: "a\n", publicKey: "no") == nil)
    #expect(VaultAuthorizedKeys.sweepCommand(device: "", publicKey: "no") == nil)
  }
}
