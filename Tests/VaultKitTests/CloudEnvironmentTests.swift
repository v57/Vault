import Foundation
import Testing

@testable import VaultKit

/// Security audit M2: a build in another CloudKit environment than the vault's reads it and writes nothing.
struct CloudEnvironmentTests {
  let keys = MemoryKeyProvider()

  private func store(_ directory: URL = temporaryDirectory()) throws -> VaultStore {
    try VaultStore(directory: directory, keys: keys, deviceID: "phone", notifier: nil, owner: "phone")
  }

  @Test func aDevelopmentBuildCantWriteToAVaultThatSyncedInProduction() throws {
    let directory = temporaryDirectory()
    let production = try store(directory)
    _ = try production.save(id: "h", kind: "host", changes: ["name": .string("prod")])
    production.recordCloudEnvironment(VaultCloudEnvironment.production)

    let debug = try store(directory)
    debug.checkCloudEnvironment(VaultCloudEnvironment.development)
    #expect(debug.writeRefusal == VaultEnvironmentMismatch(vault: "Production", build: "Development"))
    #expect(throws: VaultEnvironmentMismatch.self) { try debug.save(id: "h", kind: "host", changes: ["name": .string("dev")]) }
    #expect(throws: VaultEnvironmentMismatch.self) { try debug.delete(id: "h") }
    // It still reads.
    #expect(try debug.item(id: "h")?.fields["name"]?.stringValue == "prod")
    #expect(try debug.pendingIDs() == ["h"])
    // And says why.
    #expect(debug.writeRefusal?.localizedDescription.contains("read-only") == true)

    // The same build signed for Production writes again.
    debug.checkCloudEnvironment(VaultCloudEnvironment.production)
    #expect(debug.writeRefusal == nil)
    #expect(try debug.save(id: "h", kind: "host", changes: ["name": .string("dev")]))
  }

  /// A store that synced before the environment was recorded has CloudSync's Production mark.
  @Test func aStoreFromBeforeTheRecordCountsAsProduction() throws {
    let store = try store()
    #expect(store.cloudEnvironment == nil)
    try store.setEngineState(Data("1".utf8), for: VaultStore.productionMark)
    #expect(store.cloudEnvironment == "Production")
    store.checkCloudEnvironment("Development")
    #expect(store.writeRefusal != nil)
  }

  /// A device that never synced has nothing to mix: any build writes, and the one that syncs records it.
  @Test func aStoreThatNeverSyncedTakesAnyBuild() throws {
    let store = try store()
    store.checkCloudEnvironment("Development")
    #expect(store.writeRefusal == nil)
    #expect(try store.save(id: "a", kind: "host", changes: ["name": .string("x")]))
  }

  @Test func anAccountsStoreFollowsPersonal() throws {
    let personal = try store()
    personal.recordCloudEnvironment("Production")
    personal.checkCloudEnvironment("Development")
    let accounts = VaultAccountStores(personal: personal, notifier: nil)
    let account = try accounts.store(forAccount: "work")
    #expect(throws: VaultEnvironmentMismatch.self) { try account.save(id: "a", kind: "host", changes: [:]) }
  }

  @Test func theEnvironmentFromTheSignatureAndTheProfile() {
    func plist(_ body: String) -> Data {
      Data("garbage\u{0}<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>\(body)</dict></plist>\u{0}more".utf8)
    }
    let production = plist("<key>com.apple.developer.icloud-container-environment</key>\n\t<string>Production</string>")
    let development = plist("<key>com.apple.developer.icloud-container-environment</key><string>Development</string>")
    let none = plist("<key>application-identifier</key><string>T.dev.v57.vault</string>")
    let debugProfile = plist("<key>get-task-allow</key>\n\t\t<true/>")
    let adHocProfile = plist("<key>get-task-allow</key><false/>")

    #expect(VaultCloudEnvironment.environment(signature: production, profile: debugProfile) == "Production")
    #expect(VaultCloudEnvironment.environment(signature: development, profile: nil) == "Development")
    #expect(VaultCloudEnvironment.environment(signature: none, profile: debugProfile) == "Development")
    #expect(VaultCloudEnvironment.environment(signature: none, profile: adHocProfile) == "Production")
    #expect(VaultCloudEnvironment.environment(signature: none, profile: nil) == "Production")
  }
}
