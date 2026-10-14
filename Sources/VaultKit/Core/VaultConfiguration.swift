import Foundation

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

  /// The keychain access group for the vault keys, passwords, the SSH identity and the GitHub token
  /// (`$(AppIdentifierPrefix)dev.v57.shared` in the entitlements).
  public static let keychainGroup = "\(teamID).dev.v57.shared"

  /// The CloudKit container the store syncs through.
  public static let cloudContainer = "iCloud.dev.v57"

  /// Markdown's iCloud Drive container: the notes folder Markdown and Shell share.
  public static let notesContainer = "iCloud.dev.v57.md"

  /// The Darwin notification posted after every write, so the other apps on the device reload.
  public static let changeNotification = "dev.v57.vault.changed"

  /// The store's folder: the app group container, or Application Support when the app isn't entitled
  /// (a debug build signed without the group), so it still runs, without sharing.
  public static func defaultDirectory() -> URL {
    #if DEBUG
      // Testing a second device on one Mac: a fresh store that fetches everything from iCloud.
      if let path = ProcessInfo.processInfo.environment["VAULT_DIRECTORY"] {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif
    let fileManager = FileManager.default
    if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup),
      isUsable(group)
    {
      return group.appendingPathComponent("Vault", isDirectory: true)
    }
    return URL.applicationSupportDirectory.appendingPathComponent("dev.v57.vault", isDirectory: true)
  }

  /// The group container exists and can be written (unsandboxed macOS apps get a URL for any group,
  /// entitled or not, so check by creating the folder).
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
