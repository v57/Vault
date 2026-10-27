import Foundation

#if os(macOS)
  import Security
#endif

extension VaultKeychain {
  /// Moves an item an app kept in the Mac's login keychain (a generic password under this keychain's service, written
  /// without the data-protection keychain) into this keychain, and returns its data; nil when there is none, and
  /// always off the Mac. For apps that kept their own secrets with `SecItem` before using VaultKeychain:
  ///
  /// ```swift
  /// let keys = VaultKeychain(service: "dev.v57.dev.provider-key", accessGroup: nil)
  /// let key = try keys.read(account, options: .thisDevice) ?? keys.adoptLoginKeychainItem(account, options: .thisDevice)
  /// ```
  ///
  /// The login keychain's item is deleted once the copy is written, unless this keychain is the login keychain itself
  /// (a build without an application identifier), where the item simply stays.
  @discardableResult
  public func adoptLoginKeychainItem(_ account: String, options: Options) -> Data? {
    #if os(macOS)
      let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecUseDataProtectionKeychain as String: false,
      ]
      var query = item
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
        return nil
      }
      guard Self.usesDataProtectionKeychain else { return data }
      do {
        try write(data, account: account, options: options)
        SecItemDelete(item as CFDictionary)
      } catch {}
      return data
    #else
      return nil
    #endif
  }

  #if os(macOS)
    /// Whether this process's items go to the data-protection keychain (it has an application identifier), as
    /// VaultKeychain decides; otherwise they are the login keychain's.
    private static let usesDataProtectionKeychain: Bool = {
      guard let task = SecTaskCreateFromSelf(nil) else { return false }
      return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
    }()
  #endif
}
