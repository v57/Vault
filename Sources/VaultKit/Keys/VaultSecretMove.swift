import CryptoKit
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
/// it. The loser is kept in the secrets group as `superseded.<name>`, then `superseded.<name>#2` and on, so nothing is thrown
/// away, and the kit doesn't cover them. Past `supersededLimit` different values of one name the old copy stays where it is
/// and counts as failed; nothing ever deletes one. A keychain item's date is when it was written here, so a copy would seem
/// later than an edit made before another device's move: a copy's source date goes with it as `moved-date.<name>`, good
/// while the value is the one it was written for. Where the keychain has no dates (off Apple platforms) the secrets group
/// keeps what it has.
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
    /// Nothing moved: iCloud is off on this device (`VaultICloud`). Written now, the new copies would be this device's
    /// alone while the deletes of the old ones still reach every device through iCloud Keychain.
    public var waitsForICloud = false

    /// Whether a login's password, a code, a card or a passkey may still be in the shared group after this run.
    public var isComplete: Bool { failed.isEmpty && waiting == 0 && !waitsForICloud }
  }

  static let supersededPrefix = "superseded."
  /// How many different old values of one secret are kept.
  static let supersededLimit = 16
  /// When the value a copy was made of last changed (`moveDate`). Only read from the secrets group.
  static let moveDatePrefix = "moved-date."
  /// Written before the shared copy of the identity goes, so that a build that finds neither copy knows one exists and is on
  /// its way (`VaultPersonalIdentity.current`).
  static let identityMovedMark = "personal-identity.moved"
  /// Vault's own list of what's whose (`noteAccountSecrets`). Only ever read from the secrets group, and not a name
  /// `VaultSecretTiers.isVaultOnly` knows, so one planted in the shared group is neither read nor moved.
  static let accountSecretsPrefix = "account-secrets."
  /// Records a build before the list wrote to ask for a removed account's secrets to be deleted.
  private static let oldCleanupKind = "secretCleanup"

  let secrets: VaultSecretTiers
  let identity: VaultSecretTiers
  let stores: [VaultStore]
  /// Whether iCloud is off on this device: `VaultICloud.isOff` for the keychain's groups.
  let iCloudIsOff: @Sendable () -> Bool

  init(
    secrets: VaultSecretTiers, identity: VaultSecretTiers, stores: [VaultStore],
    iCloudIsOff: @escaping @Sendable () -> Bool = { false }
  ) {
    self.secrets = secrets
    self.identity = identity
    self.stores = stores
    self.iCloudIsOff = iCloudIsOff
  }

  /// The move for this app, nil where it can't run: an app outside the secrets group, or secrets in memory. `stores`:
  /// Personal and the accounts', which say what each password belongs to.
  public static func forThisApp(stores: [VaultStore]) -> VaultSecretMove? {
    guard let secrets = VaultSecrets.backing as? VaultSecretTiers, secrets.vaultOnly != nil,
      let identity = VaultPersonalIdentity.backing as? VaultSecretTiers, identity.vaultOnly != nil
    else { return nil }
    return VaultSecretMove(secrets: secrets, identity: identity, stores: stores, iCloudIsOff: { VaultICloud.isOff })
  }

  /// Moves what it can. While iCloud is off on this device it moves nothing and says so (`Report.waitsForICloud`): the
  /// keychain then writes synced items to this device alone (`VaultKeychain`'s twins), but a delete still reaches every
  /// device, so the move would take the secrets from all the others and leave the only copy here (security audit H3).
  @discardableResult
  public func run() -> Report {
    var report = Report()
    guard let vaultOnly = secrets.vaultOnly, let identityVaultOnly = identity.vaultOnly else { return report }
    guard !iCloudIsOff() else {
      report.waitsForICloud = true
      return report
    }

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
      // In both groups: iCloud Keychain doesn't say which it syncs first.
      let mark = Data("1".utf8)
      try? identityVaultOnly.write(mark, named: Self.identityMovedMark, label: "v57 identity moved")
      try? identity.shared.write(mark, named: Self.identityMovedMark, label: "v57 identity moved")
      move(
        VaultPersonalIdentity.account, data: data, to: VaultPersonalIdentity.account, from: identity.shared,
        into: identityVaultOnly, keepsWhatsThere: true, label: "v57 identity (sharing keys)", report: &report)
    }
    dropStaleMoveDates(in: vaultOnly)
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
      let sourceDate = try shared.modified(name)
      if let existing = try vaultOnly.read(target), existing != data {
        // Different values. Keep the loser before anything changes, and check it.
        let targetDate = try moveDate(of: target, value: existing, in: vaultOnly) ?? vaultOnly.modified(target)
        let takesShared = !keepsWhatsThere && (sourceDate ?? .distantPast) > (targetDate ?? .distantPast)
        try Self.keepSuperseded(takesShared ? existing : data, of: target, in: vaultOnly)
        if takesShared {
          try vaultOnly.write(data, named: target, label: label)
          try setMoveDate(sourceDate, of: target, value: data, in: vaultOnly)
        }
        report.conflicts += 1
      } else if try vaultOnly.read(target) == nil {
        // Another process may add it in between, with this value or another: the read-back below tells.
        if try vaultOnly.addNew(data, named: target, label: label) {
          try setMoveDate(sourceDate, of: target, value: data, in: vaultOnly)
        }
      }
      // The shared copy goes only when its value is in the secrets group, as the secret or as what it replaced.
      guard let now = try vaultOnly.read(target) else { throw MoveError.didntReadBack }
      if now != data {
        guard try Self.isSuperseded(data, of: target, in: vaultOnly) else { throw MoveError.didntReadBack }
      }
      try shared.delete(name)
      report.moved += 1
    } catch {
      report.failed.append(name)
    }
  }

  private enum MoveError: Error { case didntReadBack, tooManyKept }

  // MARK: What's kept

  private static func supersededName(of name: String, slot: Int) -> String {
    supersededPrefix + name + (slot == 1 ? "" : "#\(slot)")
  }

  private static func isSuperseded(_ value: Data, of name: String, in backing: any VaultSecretBacking) throws -> Bool {
    for slot in 1...supersededLimit where try backing.read(supersededName(of: name, slot: slot)) == value { return true }
    return false
  }

  /// Keeps a value a name no longer has, unless it's kept already, in the first free slot. Nothing is ever overwritten.
  static func keepSuperseded(_ value: Data, of name: String, in backing: any VaultSecretBacking) throws {
    var free: String?
    for slot in 1...supersededLimit {
      let slotName = supersededName(of: name, slot: slot)
      guard let held = try backing.read(slotName) else {
        free = free ?? slotName
        continue
      }
      if held == value { return }
    }
    guard let free else { throw MoveError.tooManyKept }
    // Another process may take the slot in between: the next run tries again.
    _ = try backing.addNew(value, named: free, label: "v57 replaced secret")
    guard try backing.read(free) == value else { throw MoveError.didntReadBack }
  }

  /// A secret value something replaced, for the user to look at: `VaultSecretMove` and `VaultRecovery.restore` never delete one.
  public struct Superseded: Sendable, Identifiable, Equatable {
    public var id: String
    /// What it was the value of.
    public var secret: String
    public var value: Data
    /// When it was kept, if the keychain says.
    public var kept: Date?
  }

  /// What's kept on this device, oldest first. Empty outside the secrets group.
  public static func superseded() throws -> [Superseded] {
    let backings = [VaultSecrets.backing, VaultPersonalIdentity.backing].compactMap { ($0 as? VaultSecretTiers)?.vaultOnly }
    var found: [Superseded] = []
    for backing in backings {
      for (name, value) in try backing.all() where name.hasPrefix(supersededPrefix) {
        var secret = String(name.dropFirst(supersededPrefix.count))
        if let mark = secret.lastIndex(of: "#"), Int(secret[secret.index(after: mark)...]) != nil { secret = String(secret[..<mark]) }
        found.append(Superseded(id: name, secret: secret, value: value, kept: try backing.modified(name)))
      }
    }
    return found.sorted { ($0.kept ?? .distantPast, $0.id) < ($1.kept ?? .distantPast, $1.id) }
  }

  // MARK: A copy's date

  private func moveDateValue(_ date: Date, value: Data) -> Data {
    let hash = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    return Data("\(date.timeIntervalSince1970):\(hash)".utf8)
  }

  /// The source's date of a copy that still holds that value: an edit here makes the keychain's own date the right one.
  private func moveDate(of name: String, value: Data, in vaultOnly: any VaultSecretBacking) throws -> Date? {
    guard let stored = try vaultOnly.read(Self.moveDatePrefix + name) else { return nil }
    let parts = String(decoding: stored, as: UTF8.self).split(separator: ":")
    guard parts.count == 2, let seconds = Double(parts[0]) else { return nil }
    let date = Date(timeIntervalSince1970: seconds)
    return moveDateValue(date, value: value) == stored ? date : nil
  }

  private func setMoveDate(_ date: Date?, of name: String, value: Data, in vaultOnly: any VaultSecretBacking) throws {
    if let date {
      try vaultOnly.write(moveDateValue(date, value: value), named: Self.moveDatePrefix + name, label: "v57 secret's date")
    } else {
      try vaultOnly.delete(Self.moveDatePrefix + name)
    }
  }

  /// Dates of copies that were edited or deleted since say nothing any more.
  private func dropStaleMoveDates(in vaultOnly: any VaultSecretBacking) {
    guard let all = try? vaultOnly.all() else { return }
    let values = Dictionary(all.map { ($0.name, $0.data) }, uniquingKeysWith: { first, _ in first })
    for (name, _) in all where name.hasPrefix(Self.moveDatePrefix) {
      let target = String(name.dropFirst(Self.moveDatePrefix.count))
      guard let value = values[target], (try? moveDate(of: target, value: value, in: vaultOnly)) != nil else {
        try? vaultOnly.delete(name)
        continue
      }
    }
  }

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
