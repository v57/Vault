import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Security audit M4 and V3: Get, Player and Hub read the vault through a copy of its keys in the records group, and
/// hold no secret, no device key and no Hub key. In memory; no keychain is touched.
struct RecordsGroupTests {
  private func keyData() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

  @Test func theCopyFollowsTheSharedGroupOneWay() throws {
    let shared = MemoryKeyItems()
    let records = MemoryKeyItems()
    for name in ["key.a", "keyepoch.1", "idkey.a", "mark.revoked.personal.old"] {
      _ = try shared.add(keyData(), named: name, synced: true, label: "")
    }
    // What isn't a key item stays out: a password or anything else in the service.
    _ = try shared.add(Data("hunter2".utf8), named: "password.host", synced: true, label: "")
    _ = try shared.add(Data("se".utf8), named: "ssh-identity", synced: false, label: "")
    _ = try shared.add(Data("hub".utf8), named: "hub.device-key", synced: false, label: "")
    _ = try shared.add(Data("mac".utf8), named: "device-id", synced: false, label: "")

    var report = try VaultRecordsMirror.run(from: shared, to: records)
    #expect(report.written == 5)
    #expect(Set(try records.all(synced: true).map(\.name)) == ["key.a", "keyepoch.1", "idkey.a", "mark.revoked.personal.old"])
    #expect(try records.all(synced: false).map(\.name) == ["device-id"])
    #expect(try records.read("key.a", synced: true) == shared.read("key.a", synced: true))

    // Nothing changed: nothing written.
    report = try VaultRecordsMirror.run(from: shared, to: records)
    #expect(report == .init())

    // A rotation adds a key, a mark goes, and a key item someone put in the copy goes too.
    _ = try shared.add(keyData(), named: "key.b", synced: true, label: "")
    try shared.delete("mark.revoked.personal.old", synced: true)
    _ = try records.add(keyData(), named: "key.forged", synced: true, label: "")
    report = try VaultRecordsMirror.run(from: shared, to: records)
    #expect(report == .init(written: 1, removed: 2))
    #expect(Set(try records.all(synced: true).map(\.name)) == ["key.a", "key.b", "keyepoch.1", "idkey.a"])
  }

  /// Get opened first on a new device and made the id there: the shared apps take it, so the device keeps one id.
  @Test func theDeviceIDGoesWhereItsMissing() throws {
    let shared = MemoryKeyItems()
    let records = MemoryKeyItems()
    _ = try records.add(Data("first".utf8), named: "device-id", synced: false, label: "")
    _ = try VaultRecordsMirror.run(from: shared, to: records)
    #expect(try shared.read("device-id", synced: false) == Data("first".utf8))
  }

  /// A records-only app reads the copy and opens records, but never makes a vault key of its own.
  @Test func aRecordsOnlyRingReadsAndNeverMakesAKey() throws {
    let records = MemoryKeyItems()
    let readOnly = ReadOnlySyncedKeyItems(items: records)
    let empty = VaultKeyRing(items: readOnly, staleAfter: 0)
    #expect(throws: ReadOnlySyncedKeyItems.ReadOnly.self) { try empty.primary() }
    #expect(try records.all(synced: true).isEmpty)
    #expect(throws: (any Error).self) { try empty.setMark("revoked.x", data: Data(), synced: true) }

    let shared = MemoryKeyItems()
    let full = VaultKeyRing(items: shared, staleAfter: 0)
    let primary = try full.primary()
    _ = try full.stableIDKey()
    _ = try VaultRecordsMirror.run(from: shared, to: records)
    let copy = VaultKeyRing(items: readOnly, staleAfter: 0)
    #expect(try copy.primary().id == primary.id)
    #expect(try copy.stableIDKey() == full.stableIDKey())
    #expect(throws: (any Error).self) { try copy.rotate(kitCheck: nil) }
    // This device's own marks are still its own to write.
    try copy.setMark("seen", data: Data([1]), synced: false)
  }

  @Test func noSecretsInARecordsOnlyApp() throws {
    let none = NoSecrets()
    #expect(try none.read("password.host") == nil)
    #expect(throws: NoSecrets.NotHere.self) { try none.write(Data(), named: "password.host", label: "") }
    #expect(!none.seesEverySecret)
  }

  @Test func anAppsKeyGoesWithItsDeviceAndSignsInRestricted() throws {
    let store = try VaultStore(
      directory: temporaryDirectory(), keys: MemoryKeyProvider(), deviceID: "mac", notifier: nil, owner: "mac")
    let line = "ecdsa-sha2-nistp256 \(Data(repeating: 1, count: 104).base64EncodedString())"
    try store.save(VaultDeviceKey(id: "phone", deviceName: "Phone", publicKey: line + " Phone", platform: "iOS"))
    let appKey = VaultDeviceKey(
      id: "phone.dev.v57.get", deviceName: "Get on Phone",
      publicKey: "ecdsa-sha2-nistp256 \(Data(repeating: 2, count: 104).base64EncodedString()) Get on Phone",
      platform: "iOS", app: "dev.v57.get", device: "phone")
    try store.save(appKey)
    let saved = try #require(try store.record(VaultDeviceKey.self, id: appKey.id))
    #expect(saved.app == "dev.v57.get" && saved.device == "phone")
    #expect(try store.trustedDeviceKeys().map(\.id) == ["phone"])
    #expect(try store.deviceKeysByTrust().trusted.contains { $0.id == appKey.id })

    let material = try #require(VaultAuthorizedKeys.keyMaterial(of: appKey.publicKey))
    let entry = VaultAuthorizedKeys.line(material: material, for: appKey)
    #expect(entry.hasPrefix("restrict "))
    #expect(VaultAuthorizedKeys.keyMaterial(of: entry) == material)
    #expect(!VaultAuthorizedKeys.line(material: material, for: saved).isEmpty)

    let phone = try #require(try store.record(VaultDeviceKey.self, id: "phone"))
    try store.revokeDevice(phone)
    let byTrust = try store.deviceKeysByTrust()
    #expect(byTrust.revoked.map(\.id).contains(appKey.id))
    #expect(!byTrust.trusted.map(\.id).contains(appKey.id))
  }
}
