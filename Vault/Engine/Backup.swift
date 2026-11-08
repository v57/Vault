import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

// The recovery kit and the encrypted backup, on the user's real vault (security audit H2). Both only run when the user
// asks; neither talks to a server beyond the records they write, which sync like any edit.

// MARK: - Recovery key

/// The recovery kit on Personal's store (`VaultRecovery`): what it seals syncs as records, so every device wraps new keys
/// to it. The accounts' stores share Personal's keys, so a replacement rotates them along.
@MainActor
@Observable
final class LiveRecovery: RecoveryService {
  @ObservationIgnored private let vault: Vault
  /// Bumped after each change, so views reading `isOn` draw again.
  private(set) var revision = 0

  init(vault: Vault) {
    self.vault = vault
  }

  private var recovery: VaultRecovery? { vault.store.map { VaultRecovery(store: $0) } }

  /// Personal's store opened, so there's somewhere to keep the kit's public key.
  var isAvailable: Bool { vault.store != nil }

  var isOn: Bool {
    _ = revision
    return recovery?.isOn ?? false
  }

  func create() throws -> [String] {
    guard let recovery else { throw NotYetAvailable(what: "The recovery key") }
    defer { revision += 1 }
    return try recovery.create().words
  }

  func check(_ text: String) throws -> Bool {
    guard let recovery else { throw NotYetAvailable(what: "The recovery key") }
    return try recovery.check(text)
  }

  func replace() async throws -> [String] {
    guard let recovery else { throw NotYetAvailable(what: "The recovery key") }
    defer { revision += 1 }
    return try await recovery.replace(alongWith: Self.accountStores()).words
  }

  func turnOff() async throws {
    guard let recovery else { return }
    defer { revision += 1 }
    try await recovery.turnOff()
  }

  func recover(_ text: String) async throws -> String {
    guard let recovery else { throw NotYetAvailable(what: "The recovery key") }
    if let refusal = recovery.store.writeRefusal { throw refusal }
    let recovered = try await recovery.recover(text)
    let result = try recovery.restore(recovered, alongWith: Self.accountStores())
    revision += 1
    Vaults.reloadAll()
    AppModel.moveSecrets()
    var parts = ["\(result.restoredKeys.count) vault keys", "\(result.restoredSecrets.count) passwords and secrets"]
    if result.identityRestored { parts.append("your identity") }
    if !result.refusedKeys.isEmpty { parts.append("\(result.refusedKeys.count) keys refused") }
    return "Brought back " + ListFormatter.localizedString(byJoining: parts) + "."
  }

  /// The accounts' stores beside Personal.
  @MainActor static func accountStores() -> [VaultStore] {
    Vaults.shared.accounts.compactMap { Vaults.shared.vault(for: $0)?.store }
  }
}

// MARK: - Encrypted backup

/// The whole vault in one file the user keeps (`VaultBackup`): every record of Personal and the accounts, the vault
/// keys, both keychain groups' secrets, the identity and this device's own keys, sealed under a passphrase. Saved where
/// the user picks, never to iCloud by default.
@MainActor
enum BackupActions {
  /// The file's name as offered in the save panel.
  static var defaultFilename: String {
    let date = Date.now.formatted(.iso8601.year().month().day())
    return "Vault Backup \(date).\(VaultBackup.fileExtension)"
  }

  /// Where the save and open panels start: Downloads on the Mac, the app's own Documents on iPhone and iPad (On My
  /// iPhone), both off iCloud.
  static var defaultDirectory: URL? {
    #if os(macOS)
      FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    #else
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    #endif
  }

  /// Personal's store first, then each account's.
  private static func stores() throws -> [VaultStore] {
    guard let personal = Vaults.shared.personal.store else { throw BackupUnavailable() }
    return [personal] + LiveRecovery.accountStores()
  }

  static func export(passphrase: String) async throws -> Data {
    let sources = VaultBackup.Sources(stores: try stores(), deviceName: VaultDevice.name)
    return try await Task.detached(priority: .userInitiated) {
      try VaultBackup.make(from: sources, passphrase: passphrase)
    }.value
  }

  static func open(_ data: Data, passphrase: String) async throws -> VaultBackupContents {
    try await Task.detached(priority: .userInitiated) {
      try VaultBackup.open(data, passphrase: passphrase)
    }.value
  }

  /// Puts a backup back: into an empty vault after a lost keychain, or merged into this one (what changed here since
  /// stays). `devicesOwnKeys` brings back this device's id and keys too, for the device the backup was made on.
  static func restore(_ contents: VaultBackupContents, devicesOwnKeys: Bool) throws -> VaultBackupRestoreResult {
    guard let personal = Vaults.shared.personal.store, let accounts = Vaults.shared.stores else {
      throw BackupUnavailable()
    }
    // Nothing goes back, the keychain included, into a vault this build may not write (security audit M2).
    if let refusal = personal.writeRefusal { throw refusal }
    let targets = VaultBackup.Targets(personal: personal) { try accounts.store(forAccount: $0) }
    let result = try VaultBackup.restore(contents, to: targets, devicesOwnKeys: devicesOwnKeys)
    Vaults.reloadAll()
    AppModel.moveSecrets()
    return result
  }

  struct BackupUnavailable: LocalizedError {
    var errorDescription: String? { "The vault on this device couldn’t be opened, so there’s nothing to back up or restore into." }
  }
}

extension Vaults {
  /// Reads Personal and every open account's records again, after keys or records came back.
  @MainActor static func reloadAll() {
    for account in shared.allAccounts { shared.vault(for: account)?.reload(force: true) }
  }
}

/// The backup's bytes for the save panel.
struct BackupFile: FileDocument {
  static let readableContentTypes: [UTType] = [.data]
  var data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
