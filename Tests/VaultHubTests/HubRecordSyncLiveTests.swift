import Foundation
import Testing
import VaultKit

@testable import VaultHub

/// Record sync between two devices through a real hub-pro and hub-vault, when given: `HUB_E2E_PORT` (hub-pro on
/// 127.0.0.1, with both device keys below and hub-vault's key as owners). The devices' keys come from fixed seeds:
/// device A `a1…`, device B `b2…` (32 bytes each).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HUB_E2E_PORT"] != nil))
@MainActor
struct HubRecordSyncLiveTests {
  static func seed(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

  func device(_ name: String, seed: UInt8, keys: MemoryKeyProvider, url: String) throws -> (Vault, HubConnection) {
    let store = try VaultStore(
      directory: FileManager.default.temporaryDirectory.appending(path: "hub-e2e-\(name)-\(UUID().uuidString)"),
      keys: keys, deviceID: name, notifier: nil, owner: name)
    let vault = Vault(store: store)
    var hub = VaultHubServer(id: "hub", url: url, connects: [name])
    hub.syncs = [name]
    try store.save(hub)
    vault.reload()
    let deviceKey = try HubKey(seed: Self.seed(seed))
    var this = HubThisDevice(key: deviceKey)
    this.name = "e2e \(name)"
    let connection = HubConnection(
      hub: hub, vault: vault, device: this, deviceKey: deviceKey, clientKey: try HubKey(seed: Self.seed(seed &+ 1)))
    return (vault, connection)
  }

  func wait(_ what: String, timeout: TimeInterval = 30, _ check: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !check() {
      guard Date() < end else { throw CancellationError() }
      try await Task.sleep(for: .milliseconds(200))
    }
  }

  @Test func recordsTravelBetweenDevices() async throws {
    VaultSecrets.useInMemoryStore()
    let url = "ws://127.0.0.1:\(ProcessInfo.processInfo.environment["HUB_E2E_PORT"]!)"
    let keys = MemoryKeyProvider()
    let (macVault, mac) = try device("mac", seed: 0xa1, keys: keys, url: url)
    let (linuxVault, linux) = try device("linux", seed: 0xb2, keys: keys, url: url)
    mac.start()
    linux.start()
    defer {
      mac.stop()
      linux.stop()
    }
    try await wait("both synced") {
      if case .synced = mac.recordSync, case .synced = linux.recordSync { return true }
      return false
    }
    // The Hub pinned and devices listed: the device directory works as well.
    #expect(macVault.hub(id: "hub")?.hubKey != nil)

    macVault.save(VaultHost(id: "e2e-host", name: "from mac", hostname: "mac.example.com"))
    try await wait("linux has the host") {
      linuxVault.reload(force: true)
      return linuxVault.host(id: "e2e-host") != nil
    }
    #expect(linuxVault.host(id: "e2e-host")?.hostname == "mac.example.com")

    var host = try #require(linuxVault.host(id: "e2e-host"))
    host.port = 2222
    linuxVault.save(host)
    try await wait("mac has the change") {
      macVault.reload(force: true)
      return macVault.host(id: "e2e-host")?.port == 2222
    }
    print("record sync states:", mac.recordSync, linux.recordSync)
  }
}
