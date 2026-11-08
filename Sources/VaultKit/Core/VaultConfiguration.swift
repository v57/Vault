import Foundation

#if canImport(Security)
  import Security
#endif

/// Where the vault lives: the identifiers every app declares in its entitlements.
public enum VaultConfiguration {
  /// The team that signs every v57 app.
  public static let teamID = "AUCR797TMH"

  /// The app group whose container holds the store. macOS uses the team-prefixed form, which macOS 15 lets a
  /// Developer ID app open without a prompt; iOS requires the `group.` form.
  public static var appGroup: String {
    #if os(macOS)
      "\(teamID).dev.v57"
    #else
      "group.dev.v57"
    #endif
  }

  /// The keychain access group every v57 app lists: the vault keys, connection passwords, the SSH identity, the Hub keys
  /// and the GitHub token (`$(AppIdentifierPrefix)dev.v57.shared` in the entitlements).
  public static let keychainGroup = "\(teamID).dev.v57.shared"

  /// The keychain access group only Vault and its AutoFill extension list: login passwords, one-time codes, cards,
  /// passkeys and the personal identity (`$(AppIdentifierPrefix)dev.v57.secrets`). See `VaultSecretTiers`.
  public static let secretsGroup = "\(teamID).dev.v57.secrets"

  /// The keychain access group of apps that read the vault's records but hold no secrets (Get, Player, Hub; security
  /// audit M4, V3): a copy of the vault keys and this device's id, which apps in the shared group keep current
  /// (`VaultKeychain.mirrorRecordKeys`). No passwords, no device key, no Hub keys.
  public static let recordsGroup = "\(teamID).dev.v57.records"

  /// The keychain access group of this device's Hub keys, which only Vault and the Hub app list (`HubKeyStore`).
  public static let deviceGroup = "\(teamID).dev.v57.device"

  /// This app's own keychain group (its application identifier): what no other app reads. A records-only app keeps its
  /// SSH key there (`VaultIdentity`).
  public static var ownGroup: String { "\(teamID).\(Bundle.main.bundleIdentifier ?? "dev.v57")" }

  /// The CloudKit container the store syncs through.
  public static let cloudContainer = "iCloud.dev.v57"

  /// Markdown's iCloud Drive container: the notes folder Markdown and Shell share.
  public static let notesContainer = "iCloud.dev.v57.md"

  /// The Darwin notification posted after every write, so the other apps on the device reload.
  public static let changeNotification = "dev.v57.vault.changed"

  /// The store's folder: the app group container, or Application Support when the app isn't entitled
  /// (a debug build signed without the group), so it still runs, without sharing. With secrets in memory (a demo run
  /// or a test) it's a temporary folder: that run's keys die with it, so anything it wrote to the user's store would
  /// sync sealed with a key no device has.
  public static func defaultDirectory() -> URL {
    #if DEBUG
      // Testing a second device on one Mac: a fresh store that fetches everything from iCloud.
      if let path = ProcessInfo.processInfo.environment["VAULT_DIRECTORY"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif
    if VaultSecrets.isInMemory { return memoryRunDirectory }
    #if canImport(Security)
      let fileManager = FileManager.default
      if isEntitledToGroup, let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup),
        isUsable(group)
      {
        return group.appendingPathComponent("Vault", isDirectory: true)
      }
    #endif
    // Off Apple platforms every app of the user shares Application Support (Windows: AppData).
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.v57.vault", isDirectory: true)
  }

  /// The file that says iCloud is off on this device (`VaultICloud`), beside the store. A run with secrets in memory has
  /// its own, so a demo can't turn iCloud off for the real apps.
  static var iCloudOffFile: URL {
    (VaultSecrets.isInMemory ? memoryRunDirectory : storeDirectoryOnce).appendingPathComponent("iCloud-off")
  }

  /// `defaultDirectory()` for a process keeping real secrets, worked out once: the keychain asks for each synced item.
  private static let storeDirectoryOnce = defaultDirectory()

  /// The store's folder in a run with secrets in memory, one per process.
  private static let memoryRunDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("dev.v57.vault-\(UUID().uuidString)", isDirectory: true)

  /// Whether this build is signed with the app group. Unsandboxed macOS apps get a container URL for any group,
  /// and one built without the team's signing (someone else's build, signed to run locally) that opens the
  /// signed apps' container gets "Operation not permitted" and a privacy prompt instead of a store.
  private static var isEntitledToGroup: Bool {
    #if !canImport(Security)
      return false
    #elseif os(macOS)
      guard let task = SecTaskCreateFromSelf(nil),
        let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
          as? [String]
      else { return false }
      return groups.contains(appGroup)
    #else
      // iOS hands out only the containers the app is entitled to.
      return true
    #endif
  }

  /// The group container exists and can be written.
  private static func isUsable(_ url: URL) -> Bool {
    let folder = url.appendingPathComponent("Vault", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      return true
    } catch {
      return false
    }
  }
}
