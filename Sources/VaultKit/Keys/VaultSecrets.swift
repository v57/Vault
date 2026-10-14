import Foundation

/// Passwords and tokens, kept apart from the items: iCloud Keychain items in the shared group, named after the
/// item they belong to. They sync end to end encrypted, so a connection added on the Mac opens on the iPad
/// without typing the password again.
public enum VaultSecrets {
  static let keychain = VaultKeychain(service: "dev.v57.vault.secrets")

  /// The password saved for an item (a host, a database).
  public static func password(for id: String) -> String? {
    (try? keychain.read("password.\(id)", options: .synced)).flatMap { String(data: $0, encoding: .utf8) }
  }

  /// Saves the password, or deletes it for nil.
  public static func setPassword(_ password: String?, for id: String) throws {
    if let password, !password.isEmpty {
      try keychain.write(Data(password.utf8), account: "password.\(id)", options: .init(synchronizable: true, label: "v57 password"))
    } else {
      try keychain.delete("password.\(id)", options: .synced)
    }
  }

  /// Any other secret by name (an API key).
  public static func secret(_ name: String) -> Data? {
    try? keychain.read(name, options: .synced)
  }

  public static func setSecret(_ data: Data?, named name: String) throws {
    if let data {
      try keychain.write(data, account: name, options: .init(synchronizable: true, label: "v57 secret"))
    } else {
      try keychain.delete(name, options: .synced)
    }
  }
}
