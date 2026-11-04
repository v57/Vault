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
///
/// It also deletes what an account's removal in another app couldn't reach (`noteAccountSecrets`).
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
  /// Vault's own list of what's whose (`noteAccountSecrets`). Only ever read from the secrets group, and not a name
  /// `VaultSecretTiers.isVaultOnly` knows, so one planted in the shared group is neither read nor moved.
  static let accountSecretsPrefix = "account-secrets."
  /// Records a build before the list wrote to ask for a removed account's secrets to be deleted.
  private static let oldCleanupKind = "secretCleanup"

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
    noteAccountSecrets(in: vaultOnly)
    finishRemovedAccounts(in: vaultOnly, shared: secrets.shared)
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

  // MARK: A removed account's secrets

  /// An app outside the secrets group can remove an account but not its logins' secrets, so those are left for Vault. Every
  /// app holds the vault key and can write any record, so no record can say which: Vault keeps a list of its own per live
  /// account, `account-secrets.<account>`, in the group only it can write, and goes by that once Personal holds the account's
  /// tombstone. Whoever can write records can at most delete a real account, whose secrets go; never a secret of another
  /// account, or of Personal. A secret the list missed (made and left behind between two runs of this) stays, and nothing can
  /// read it but Vault.
  private func noteAccountSecrets(in vaultOnly: any VaultSecretBacking) {
    guard let personal = stores.first(where: { $0.accountID == nil }), let secrets = try? vaultOnly.all() else { return }
    var lists: [String: Set<String>] = [:]
    var owners = Set<String>()
    for (name, data) in secrets {
      if name.hasPrefix(Self.accountSecretsPrefix) {
        lists[String(name.dropFirst(Self.accountSecretsPrefix.count))] = Self.ids(in: data)
      } else if let owner = VaultRecovery.owner(ofSecret: name) {
        owners.insert(owner)
      }
    }
    for store in stores.sorted(by: { ($0.accountID ?? "") < ($1.accountID ?? "") }) {
      guard let account = store.accountID, (try? personal.isLive(account: account)) == true,
        let held = try? store.allIDs()
      else { continue }
      let previous = lists[account] ?? []
      var ids = previous
      for id in held where owners.contains(id) && !ids.contains(id) {
        // A login that's Personal's or another account's doesn't become this one's by a row appearing here.
        let isElsewhere = stores.contains { $0 !== store && ((try? $0.knows(id: id)) ?? true) }
        let isListed = lists.contains { $0.key != account && $0.value.contains(id) }
        if !isElsewhere && !isListed { ids.insert(id) }
      }
      guard ids != previous else { continue }
      let data = Data(ids.sorted().joined(separator: "\n").utf8)
      if (try? vaultOnly.write(data, named: Self.accountSecretsPrefix + account, label: "v57 account's secrets")) != nil {
        lists[account] = ids
      }
    }
  }

  /// Deletes the secrets on the list of an account Personal holds a tombstone for, except what any other store holds. Waits
  /// for Personal and every live account's store to be here and settled (`VaultStore.isSettled`): a row that says a
  /// login has moved elsewhere may still be on its way. Records the kit once asked for this by are just dropped.
  private func finishRemovedAccounts(in vaultOnly: any VaultSecretBacking, shared: any VaultSecretBacking) {
    guard let personal = stores.first(where: { $0.accountID == nil }) else { return }
    for leftover in (try? personal.items(kind: Self.oldCleanupKind)) ?? [] { try? personal.delete(id: leftover.id) }
    guard personal.isSettled, let live = try? personal.records(VaultAccount.self),
      live.allSatisfy({ account in stores.contains { $0.accountID == account.id && $0.isSettled } }),
      let secrets = try? vaultOnly.all()
    else { return }
    for (name, data) in secrets where name.hasPrefix(Self.accountSecretsPrefix) {
      let account = String(name.dropFirst(Self.accountSecretsPrefix.count))
      guard let row = try? personal.item(id: account), row.kind == VaultAccount.kind, row.isDeleted else { continue }
      let others = stores.filter { $0.accountID != account }
      var done = true
      for id in Self.ids(in: data) {
        do {
          guard try !others.contains(where: { try $0.knows(id: id) }) else { continue }
          for secret in Self.names(forItem: id) {
            try vaultOnly.delete(secret)
            try shared.delete(secret)
            VaultSecrets.didChange?(secret, nil)
          }
        } catch {
          done = false
        }
      }
      if done { try? vaultOnly.delete(name) }
    }
  }

  private static func ids(in list: Data) -> Set<String> {
    Set(String(decoding: list, as: UTF8.self).split(separator: "\n").map(String.init))
  }

  /// The secrets kept for an item that only Vault can reach.
  static func names(forItem id: String) -> [String] {
    [
      VaultSecrets.loginSecret(id), VaultLogin.oneTimeCodeSecret(id), VaultCard.numberSecret(id), VaultCard.codeSecret(id),
      VaultPasskey.keySecret(id),
    ]
  }
}
