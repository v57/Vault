import Foundation

/// Moves what only Vault should read out of the keychain group every app lists and into the secrets group
/// (`VaultSecretTiers`). Only Vault or its AutoFill extension can do this, since nothing else lists both groups.
///
/// Each secret goes one at a time, and a kill at any point loses nothing: the old copy is removed only after the new one
/// reads back with the same bytes, and running again picks up where it stopped. Run it whenever Vault comes to the front:
/// a device still on an old build writes to the shared group, and iCloud Keychain brings that in at any time.
///
/// What moves:
/// - `otp.`, `card.number.`, `card.code.`, `passkey.` and the recovery digest's key, under the same name.
/// - `password.<id>` as `login.<id>`, when `<id>` is a login in one of the stores. Connection passwords share that name,
///   so one whose record isn't here (yet) stays where it is and counts in `waiting`.
/// - The personal identity, to its own service.
///
/// Two different values under one name happen when an old build edited a secret after it moved. For a secret the
/// later-modified one wins; for the identity what's in the secrets group always stays, because folder keys are wrapped to
/// it. The loser is kept in the secrets group as `superseded.<name>`, so nothing is thrown away, and the kit doesn't cover it.
public struct VaultSecretMove: Sendable {
  /// What a run found.
  public struct Report: Sendable, Equatable {
    /// Secrets now only in the secrets group.
    public var moved = 0
    /// Of those, ones that were there under the same name with another value.
    public var conflicts = 0
    /// Couldn't be moved this time: the old copy stays, and the next run tries again.
    public var failed: [String] = []
    /// `password.<id>` whose record isn't in these stores: left in the shared group, readable by every app.
    public var waiting = 0

    /// Whether a login's password, a code, a card or a passkey may still be in the shared group after this run.
    public var isComplete: Bool { failed.isEmpty && waiting == 0 }
  }

  static let supersededPrefix = "superseded."

  let secrets: VaultSecretTiers
  let identity: VaultSecretTiers
  let stores: [VaultStore]

  init(secrets: VaultSecretTiers, identity: VaultSecretTiers, stores: [VaultStore]) {
    self.secrets = secrets
    self.identity = identity
    self.stores = stores
  }

  /// The move for this app, nil where it can't run: an app outside the secrets group, or secrets in memory. `stores`:
  /// Personal and the accounts', which say what each password belongs to.
  public static func forThisApp(stores: [VaultStore]) -> VaultSecretMove? {
    guard let secrets = VaultSecrets.backing as? VaultSecretTiers, secrets.vaultOnly != nil,
      let identity = VaultPersonalIdentity.backing as? VaultSecretTiers, identity.vaultOnly != nil
    else { return nil }
    return VaultSecretMove(secrets: secrets, identity: identity, stores: stores)
  }

  @discardableResult
  public func run() -> Report {
    var report = Report()
    guard let vaultOnly = secrets.vaultOnly, let identityVaultOnly = identity.vaultOnly else { return report }

    let shared: [(name: String, data: Data)]
    do {
      shared = try secrets.shared.all()
    } catch {
      report.failed.append("shared group")
      return report
    }
    for (name, data) in shared.sorted(by: { $0.name < $1.name }) {
      guard let target = target(of: name, report: &report) else { continue }
      move(
        name, data: data, to: target, from: secrets.shared, into: vaultOnly, keepsWhatsThere: false,
        label: "v57 secret", report: &report)
    }

    if let data = try? identity.shared.read(VaultPersonalIdentity.account) {
      move(
        VaultPersonalIdentity.account, data: data, to: VaultPersonalIdentity.account, from: identity.shared,
        into: identityVaultOnly, keepsWhatsThere: true, label: "v57 identity (sharing keys)", report: &report)
    }
    finishCleanups(in: vaultOnly, shared: secrets.shared)
    return report
  }

  /// Where a shared item goes, nil for one that stays.
  private func target(of name: String, report: inout Report) -> String? {
    if VaultSecretTiers.isVaultOnly(name) { return name }
    guard name.hasPrefix("password.") else { return nil }
    let id = String(name.dropFirst("password.".count))
    switch kind(of: id) {
    case VaultLogin.kind: return VaultSecrets.loginSecret(id)
    case nil:
      report.waiting += 1
      return nil
    default: return nil
    }
  }

  /// A record's kind, deleted or not, in whichever store has it.
  private func kind(of id: String) -> String? {
    for store in stores {
      if let item = try? store.item(id: id), !item.kind.isEmpty { return item.kind }
    }
    return nil
  }

  private func move(
    _ name: String, data: Data, to target: String, from shared: any VaultSecretBacking, into vaultOnly: any VaultSecretBacking,
    keepsWhatsThere: Bool, label: String, report: inout Report
  ) {
    do {
      if let existing = try vaultOnly.read(target), existing != data {
        // Different values. Keep the loser before anything changes, and check it.
        let takesShared =
          try !keepsWhatsThere && (shared.modified(name) ?? .distantPast) > (vaultOnly.modified(target) ?? .distantPast)
        let loser = takesShared ? existing : data
        let kept = Self.supersededPrefix + target
        try vaultOnly.write(loser, named: kept, label: "v57 replaced secret")
        guard try vaultOnly.read(kept) == loser else { throw MoveError.didntReadBack }
        if takesShared { try vaultOnly.write(data, named: target, label: label) }
        report.conflicts += 1
      } else if try vaultOnly.read(target) == nil {
        // Another process may add it in between, with this value or another: the read-back below tells.
        _ = try vaultOnly.addNew(data, named: target, label: label)
      }
      // The shared copy goes only when its value is in the secrets group, as the secret or as what it replaced.
      guard let now = try vaultOnly.read(target) else { throw MoveError.didntReadBack }
      if now != data {
        guard try vaultOnly.read(Self.supersededPrefix + target) == data else { throw MoveError.didntReadBack }
      }
      try shared.delete(name)
      report.moved += 1
    } catch {
      report.failed.append(name)
    }
  }

  private enum MoveError: Error { case didntReadBack }

  /// Deletes what an account's removal in another app couldn't reach (`VaultSecretCleanup`).
  private func finishCleanups(in vaultOnly: any VaultSecretBacking, shared: any VaultSecretBacking) {
    for store in stores where store.accountID == nil {
      for cleanup in (try? store.records(VaultSecretCleanup.self)) ?? [] {
        var done = true
        for item in cleanup.items {
          for name in VaultSecretCleanup.names(forItem: item) {
            do {
              try vaultOnly.delete(name)
              try shared.delete(name)
              VaultSecrets.didChange?(name, nil)
            } catch {
              done = false
            }
          }
        }
        if done { try? store.delete(id: cleanup.id) }
      }
    }
  }
}

/// The items of an account deleted in an app outside the secrets group, for Vault to delete their logins' secrets: that
/// app couldn't reach them. Sealed in Personal like any record, and gone once Vault has done it.
struct VaultSecretCleanup: VaultRecord {
  static let kind = "secretCleanup"

  var id: String
  var items: [String]

  static func recordID(account: String) -> String { "secret-cleanup.\(account)" }

  static func names(forItem id: String) -> [String] {
    [
      VaultSecrets.loginSecret(id), VaultLogin.oneTimeCodeSecret(id), VaultCard.numberSecret(id), VaultCard.codeSecret(id),
      VaultPasskey.keySecret(id),
    ]
  }

  init(id: String, items: [String]) {
    self.id = id
    self.items = items
  }

  init(id: String, values: [String: JSONValue]) {
    self.id = id
    items = (values["items"]?.stringValue ?? "").split(separator: "\n").map(String.init)
  }

  var values: [String: JSONValue] { ["items": .string(items.joined(separator: "\n"))] }
}
