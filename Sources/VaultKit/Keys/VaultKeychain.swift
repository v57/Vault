#if canImport(Security)
import Foundation
import Security

/// Generic-password items in a keychain access group: the shared one by default, or `VaultConfiguration.secretsGroup`.
///
/// Items live in the data-protection keychain, where the access group decides who can read them: only apps
/// signed by the team that list `dev.v57.shared` in their entitlements. Other apps, other users and
/// processes without the entitlement get nothing (no prompt to click through, unlike the old login
/// keychain).
///
/// A build signed by another team, without the entitlement, falls back to the app's own items in the data-protection
/// keychain, so it still works on its own; `isShared` tells.
///
/// A build with no application identifier at all (ad-hoc signed, or a plain `swift test` binary) can't use the
/// data-protection keychain, only the old file keychain, where items don't sync and an access list guards them. A Debug
/// build does that, so it can run while being worked on. **A Release build refuses:** every call throws
/// `errSecMissingEntitlement`, so a signing mistake shows up as an error rather than as secrets quietly kept somewhere
/// weaker. `isAvailable` tells.
public struct VaultKeychain: Sendable {
  public let service: String
  public let accessGroup: String?

  public init(service: String = "dev.v57.vault", accessGroup: String? = VaultConfiguration.keychainGroup) {
    self.service = service
    self.accessGroup = accessGroup
  }

  public enum KeychainError: LocalizedError, Equatable {
    case status(OSStatus)

    public var errorDescription: String? {
      switch self {
      case .status(let status):
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error"
        return "Keychain: \(message) (\(status))"
      }
    }
  }

  /// Which kind of item to read or write.
  public struct Options: Sendable {
    /// Synced through iCloud Keychain to the user's other devices.
    public var synchronizable: Bool
    public var label: String?

    public init(synchronizable: Bool, label: String? = nil) {
      self.synchronizable = synchronizable
      self.label = label
    }

    public static let synced = Options(synchronizable: true)
    public static let thisDevice = Options(synchronizable: false)
  }

  /// Whether the shared group is usable (the app is entitled), checked once per process.
  public static let isShared: Bool = isEntitled(to: VaultConfiguration.keychainGroup)

  /// Whether this app lists an access group. Asks with a read of an item that doesn't exist, which answers
  /// `errSecMissingEntitlement` for a group the app doesn't list, so it reads nothing either way.
  public static func isEntitled(to group: String) -> Bool {
    guard dataProtection else { return false }
    let probe = VaultKeychain(service: "dev.v57.vault.probe", accessGroup: group)
    let status = SecItemCopyMatching(probe.query(account: "probe", options: .thisDevice, group: group) as CFDictionary, nil)
    return status != errSecMissingEntitlement
  }

  /// Whether keychain calls work at all in this build: false only for a Release build with no application identifier.
  public static var isAvailable: Bool { dataProtection || fileKeychainIsAllowed }

  /// The old file keychain is for builds being worked on.
  static var fileKeychainIsAllowed: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  private func checkAvailable() throws {
    guard Self.isAvailable else { throw KeychainError.status(errSecMissingEntitlement) }
  }

  private var effectiveGroup: String? { Self.isShared ? accessGroup : nil }

  private func query(account: String?, options: Options, group: String?) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: Self.dataProtection,
    ]
    // The file keychain can't sync; its items are always this device's.
    if Self.dataProtection {
      query[kSecAttrSynchronizable as String] = options.synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
    }
    if let account { query[kSecAttrAccount as String] = account }
    if let group, Self.dataProtection { query[kSecAttrAccessGroup as String] = group }
    return query
  }

  /// The data-protection keychain needs a signed app with an application identifier; without one (a plain
  /// `swift test` binary, or an ad-hoc build: someone building the apps without the team's signing) only the old
  /// file keychain works. Reading the data-protection keychain without it can still succeed; adding fails.
  private static let dataProtection: Bool = {
    #if os(macOS)
      guard let task = SecTaskCreateFromSelf(nil) else { return false }
      return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
    #else
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.v57.vault.probe",
        kSecUseDataProtectionKeychain as String: true,
      ]
      return SecItemCopyMatching(query as CFDictionary, nil) != errSecMissingEntitlement
    #endif
  }()

  public func read(_ account: String, options: Options) throws -> Data? {
    try checkAvailable()
    var query = query(account: account, options: options, group: effectiveGroup)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError.status(status) }
    return result as? Data
  }

  /// An item's label and when it last changed, without its data; nil when there's no such item.
  public func attributes(of account: String, options: Options) throws -> (label: String?, modified: Date?)? {
    try checkAvailable()
    var query = query(account: account, options: options, group: effectiveGroup)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError.status(status) }
    let item = result as? [String: Any]
    return (item?[kSecAttrLabel as String] as? String, item?[kSecAttrModificationDate as String] as? Date)
  }

  /// Every item's account and data in this service.
  public func readAll(options: Options) throws -> [(account: String, data: Data)] {
    try checkAvailable()
    // The file keychain can't return the data of several items at once (-50): list the accounts, then read each.
    guard Self.dataProtection else {
      return try accounts(options: options).compactMap { account in
        try read(account, options: options).map { (account, $0) }
      }
    }
    var query = query(account: nil, options: options, group: effectiveGroup)
    query[kSecReturnData as String] = true
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw KeychainError.status(status) }
    let items = result as? [[String: Any]] ?? []
    return items.compactMap { item in
      guard let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data
      else { return nil }
      return (account, data)
    }
  }

  private func accounts(options: Options) throws -> [String] {
    try checkAvailable()
    var query = query(account: nil, options: options, group: effectiveGroup)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw KeychainError.status(status) }
    return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
  }

  /// Adds the item, or replaces its data.
  public func write(_ data: Data, account: String, options: Options) throws {
    try checkAvailable()
    let base = query(account: account, options: options, group: effectiveGroup)
    let update: [String: Any] = [kSecValueData as String: data]
    var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      status = add(data, account: account, options: options)
    }
    guard status == errSecSuccess else { throw KeychainError.status(status) }
  }

  /// Adds the item and fails with `errSecDuplicateItem` if it exists: for values that must not be replaced,
  /// like a key another device may already have used.
  public func addNew(_ data: Data, account: String, options: Options) throws {
    try checkAvailable()
    let status = add(data, account: account, options: options)
    guard status == errSecSuccess else { throw KeychainError.status(status) }
  }

  private func add(_ data: Data, account: String, options: Options) -> OSStatus {
    var query = query(account: account, options: options, group: effectiveGroup)
    query[kSecValueData as String] = data
    if Self.dataProtection {
      query[kSecAttrAccessible as String] =
        options.synchronizable
        ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
    if let label = options.label { query[kSecAttrLabel as String] = label }
    return SecItemAdd(query as CFDictionary, nil)
  }

  public func delete(_ account: String, options: Options) throws {
    try checkAvailable()
    let status = SecItemDelete(query(account: account, options: options, group: effectiveGroup) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
  }
}
#endif
