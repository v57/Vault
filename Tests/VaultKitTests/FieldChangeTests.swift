import Foundation
import Testing

@testable import VaultKit

struct FieldChangeTests {
  let keys = MemoryKeyProvider()

  init() { VaultSecrets.useInMemoryStore() }

  @Test func eachFieldTellsWhenAndWhere() throws {
    let directory = temporaryDirectory()
    let mac = try VaultStore(directory: directory, keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
    let phone = try VaultStore(directory: directory, keys: keys, deviceID: "phone", notifier: nil, owner: "phone")
    let login = VaultLogin(title: "Bank", username: "me")
    let before = Date.now.addingTimeInterval(-1)
    try mac.save(login)
    try phone.setPassword("secret", forLogin: login.id)

    let changes = try mac.fieldChanges(id: login.id)
    #expect(changes["title"]?.device == "mac")
    #expect(changes["passwordChanged"]?.device == "phone")
    #expect(changes["passwordChanged"]?.merged == false)
    #expect(changes["title"].map { $0.date >= before && $0.date <= .now.addingTimeInterval(1) } == true)
    #expect(changes["_deleted"] == nil)
    #expect(try mac.fieldChanges(id: "missing").isEmpty)
  }

  @Test func mergedClocksNameTheDevice() {
    let change = VaultFieldChange(field: "text", clock: HybridClock(millis: 1_000, counter: 1, device: "ipad+merge"))
    #expect(change.device == "ipad")
    #expect(change.merged)
    #expect(change.date == Date(timeIntervalSince1970: 1))
  }

  @MainActor @Test func deviceNamesComeFromDeviceKeys() throws {
    let store = try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
    try store.save(VaultDeviceKey(id: "studio", deviceName: "Studio Mac", publicKey: "", platform: "macOS"))
    let vault = Vault(store: store)
    #expect(vault.deviceName(for: "studio") == "Studio Mac")
    #expect(vault.deviceName(for: "unknown") == nil)
    #expect(vault.fieldChanges(id: "studio")["deviceName"]?.device == "mac")
  }
}
