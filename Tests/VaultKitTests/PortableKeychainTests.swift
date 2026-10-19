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
