#if !canImport(Security)
  import Foundation
  import Testing

  @testable import VaultKit

  /// The keychain off Apple platforms (Windows Credential Manager, a user-only file on Linux).
  struct PortableKeychainTests {
    @Test func itemsRoundTripAndStayApartBySync() throws {
      let keychain = VaultKeychain(service: "dev.v57.vault.test.\(UUID().uuidString)")
      // The Windows Credential Manager needs an interactive logon (not SSH with a key): nothing to test there.
      if case .status(1312)? = Self.logonError(keychain) { return }
      #expect(try keychain.read("a", options: .thisDevice) == nil)
      try keychain.write(Data("one".utf8), account: "a", options: .thisDevice)
      try keychain.write(Data("two".utf8), account: "a", options: .thisDevice)
      try keychain.write(Data("synced".utf8), account: "a", options: .synced)
      #expect(try keychain.read("a", options: .thisDevice) == Data("two".utf8))
      #expect(try keychain.read("a", options: .synced) == Data("synced".utf8))
      #expect(throws: VaultKeychain.KeychainError.status(errSecDuplicateItem)) {
        try keychain.addNew(Data("three".utf8), account: "a", options: .thisDevice)
      }
      try keychain.addNew(Data("b".utf8), account: "b", options: .thisDevice)
      #expect(Set(try keychain.readAll(options: .thisDevice).map(\.account)) == ["a", "b"])
      for account in ["a", "b"] { try keychain.delete(account, options: .thisDevice) }
      try keychain.delete("a", options: .synced)
      #expect(try keychain.readAll(options: .thisDevice).isEmpty)
      #expect(try keychain.read("a", options: .synced) == nil)
    }

    /// Security audit M5: Windows caps an item at 2,560 bytes; larger ones are kept in pieces.
    @Test func itemsPastTheLimitRoundTrip() throws {
      let keychain = VaultKeychain(service: "dev.v57.vault.test.\(UUID().uuidString)")
      if case .status(1312)? = Self.logonError(keychain) { return }
      let big = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
      let bigger = Data(repeating: 7, count: 9_000)
      try keychain.write(big, account: "big", options: .thisDevice)
      #expect(try keychain.read("big", options: .thisDevice) == big)
      try keychain.write(bigger, account: "big", options: .thisDevice)
      try keychain.write(Data("small".utf8), account: "small", options: .thisDevice)
      #expect(try keychain.read("big", options: .thisDevice) == bigger)
      let all = Dictionary(uniqueKeysWithValues: try keychain.readAll(options: .thisDevice).map { ($0.account, $0.data) })
      #expect(all == ["big": bigger, "small": Data("small".utf8)])
      try keychain.write(Data("short again".utf8), account: "big", options: .thisDevice)
      #expect(try keychain.read("big", options: .thisDevice) == Data("short again".utf8))
      for account in ["big", "small"] { try keychain.delete(account, options: .thisDevice) }
      #expect(try keychain.readAll(options: .thisDevice).isEmpty)
    }

    private static func logonError(_ keychain: VaultKeychain) -> VaultKeychain.KeychainError? {
      do {
        _ = try keychain.read("a", options: .thisDevice)
        return nil
      } catch {
        return error as? VaultKeychain.KeychainError
      }
    }
  }
#endif
