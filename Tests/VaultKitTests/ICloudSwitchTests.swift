import Foundation
import Testing

@testable import VaultKit

#if canImport(Security)
  import Security
#endif

/// `VaultICloud`: the device's switch, and what `VaultKeychain` does while it's off. Serialized: the switch is one per
/// process here. Secrets in memory give the run a switch file of its own, away from the real apps'.
@Suite(.serialized)
struct ICloudSwitchTests {
  init() throws {
    VaultSecrets.useInMemoryStore()
    try VaultICloud.setOff(false)
  }

  @Test func theSwitchOutlivesTheCallAndCanGoBack() throws {
    #expect(!VaultICloud.isOff)
    try VaultICloud.setOff(true)
    #expect(VaultICloud.isOff)
    // Twice is the same.
    try VaultICloud.setOff(true)
    #expect(VaultICloud.isOff)
    try VaultICloud.setOff(false)
    #expect(!VaultICloud.isOff)
    try VaultICloud.setOff(false)
    #expect(!VaultICloud.isOff)
  }

  @Test func theFileIsNotTheRealApps() {
    #expect(VaultConfiguration.iCloudOffFile.path.contains("dev.v57.vault-"))
  }

  @Test func changingItTellsTheOtherApps() async throws {
    let heard = Heard()
    let observer = VaultChangeObserver(name: VaultICloud.changeNotification) { heard.mark() }
    try VaultICloud.setOff(true)
    try VaultICloud.setOff(false)
    for _ in 0..<40 where !heard.value {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(heard.value)
    withExtendedLifetime(observer) {}
  }

  #if canImport(Security)
    /// The data-protection keychain, which needs a signed app as the test's host. A plain `swift test` on the Mac has
    /// only the file keychain, whose items never sync, so there's nothing to keep back, and a test without a host on
    /// the simulator skips it as well.
    @Test(.enabled(if: VaultKeychain.dataProtection))
    func syncedItemsStayOnThisDeviceWhileOff() throws {
      let service = "dev.v57.vault.icloud-test-\(UUID().uuidString)"
      let keychain = VaultKeychain(service: service, accessGroup: nil)
      let twin = VaultKeychain(service: service + ".icloud-off", accessGroup: nil)
      defer {
        for account in ["a", "b", "c"] {
          try? keychain.delete(account, options: .synced)
          try? twin.delete(account, options: .thisDevice)
        }
      }

      // On: straight to iCloud Keychain.
      try keychain.write(Data("one".utf8), account: "a", options: .synced)
      #expect(try synced(service, "a") == Data("one".utf8))

      try VaultICloud.setOff(true)
      defer { try? VaultICloud.setOff(false) }

      // What's there still reads, and a change stays here.
      #expect(try keychain.read("a", options: .synced) == Data("one".utf8))
      try keychain.write(Data("two".utf8), account: "a", options: .synced)
      #expect(try keychain.read("a", options: .synced) == Data("two".utf8))
      #expect(try synced(service, "a") == Data("one".utf8))

      // A new item stays here too, and adding over either kind says it's there.
      try keychain.addNew(Data("new".utf8), account: "b", options: .synced)
      #expect(try synced(service, "b") == nil)
      #expect(throws: VaultKeychain.KeychainError.status(errSecDuplicateItem)) {
        try keychain.addNew(Data("x".utf8), account: "b", options: .synced)
      }
      #expect(throws: VaultKeychain.KeychainError.status(errSecDuplicateItem)) {
        try keychain.addNew(Data("x".utf8), account: "a", options: .synced)
      }

      // The list has each once, the change winning.
      let all = try keychain.readAll(options: .synced)
      #expect(all.count == 2)
      #expect(all.first { $0.account == "a" }?.data == Data("two".utf8))

      // A deletion reaches iCloud Keychain as well: what the user deleted doesn't come back.
      try keychain.write(Data("gone".utf8), account: "c", options: .synced)
      try keychain.delete("b", options: .synced)
      #expect(try keychain.read("b", options: .synced) == nil)

      try VaultICloud.setOff(false)

      // On again: what stayed here goes up, and the twins are gone.
      #expect(try keychain.read("a", options: .synced) == Data("two".utf8))
      #expect(try synced(service, "a") == Data("two".utf8))
      #expect(try synced(service, "c") == Data("gone".utf8))
      #expect(try twin.readAll(options: .thisDevice).isEmpty)
    }

    /// An item in iCloud Keychain, whatever the switch says.
    private func synced(_ service: String, _ account: String) throws -> Data? {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: account, kSecAttrSynchronizable as String: true,
        kSecUseDataProtectionKeychain as String: true, kSecReturnData as String: true,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      return status == errSecSuccess ? result as? Data : nil
    }
  #endif
}

private final class Heard: @unchecked Sendable {
  private let lock = NSLock()
  private var heard = false
  var value: Bool { lock.withLock { heard } }
  func mark() { lock.withLock { heard = true } }
}
