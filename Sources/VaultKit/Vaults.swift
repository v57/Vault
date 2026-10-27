import Foundation
import Observation

/// Personal and the accounts (`VaultAccount`), each a `Vault` of its own: its own key, store file, CloudKit zone and
/// Hub mailbox. Account vaults open on first use.
///
/// `Vaults.shared` sits on `Vault.shared`, which stays Personal, so code that knows only Personal keeps working. A
/// window shows one account; apps hand its vault down the view tree.
@MainActor
@Observable
public final class Vaults {
  public static let shared = Vaults()

  public let personal: Vault
  /// The accounts' stores; nil when Personal's store couldn't open.
  @ObservationIgnored public let stores: VaultAccountStores?
  /// The account vaults this process opened, by account id.
  private var opened: [String: Vault] = [:]
  /// Why an account couldn't be made, opened or deleted, for the UI.
  public var error: String?

  /// Personal's vault and the accounts beside it (`stores` for tests; by default the keychain's keys).
  public init(personal: Vault = .shared, stores: VaultAccountStores? = nil) {
    self.personal = personal
    self.stores = stores ?? personal.store.map(VaultAccountStores.forPersonal)
    personal.didReload = { [weak self] in self?.personalReloaded() }
    personalReloaded()
  }

  /// The accounts beside Personal, by name.
  public var accounts: [VaultAccount] { personal.accounts }

  /// Personal, then the accounts.
  public var allAccounts: [VaultAccount] { [.personal] + accounts }

  public func account(id: String?) -> VaultAccount? {
    guard let id else { return nil }
    return id == VaultAccount.personal.id ? .personal : accounts.first { $0.id == id }
  }

  /// The account's vault, opened on first use; nil when its store can't open (`error` says why) or the account
  /// was deleted.
  public func vault(for account: VaultAccount) -> Vault? {
    if account.isPersonal { return personal }
    if let vault = opened[account.id] { return vault }
    guard let stores else { return nil }
    do {
      let vault = Vault(store: try stores.store(forAccount: account.id), accountID: account.id)
      vault.sync = personal.sync
      opened[account.id] = vault
      return vault
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }

  /// Makes an account: its key (synced by iCloud Keychain) and its record in Personal. Its zone is made on the
  /// server when its vault first syncs.
  @discardableResult
  public func createAccount(name: String, color: String = "blue") throws -> VaultAccount {
    guard let stores else { throw VaultAccountStores.AccountError.noStore }
    let account = try stores.create(name: name, color: color)
    personal.reload()
    return account
  }

  /// Renames or recolors an account.
  public func save(_ account: VaultAccount) {
    guard !account.isPersonal else { return }
    personal.save(account)
  }

  // MARK: Matching

  /// The accounts in the order matching tries them: an organization's before Personal, so a team or GitHub owner
  /// that Personal also holds goes to the organization.
  private var matchOrder: [VaultAccount] { accounts + [.personal] }

  /// The account that holds an Apple developer team (a project's `DEVELOPMENT_TEAM`): the one whose keys sign it.
  public func account(forTeam teamID: String) -> VaultAccount? {
    let teamID = teamID.trimmingCharacters(in: .whitespaces)
    guard !teamID.isEmpty else { return nil }
    return matchOrder.first { account in
      vault(for: account)?.appleTeams.contains { $0.teamID.caseInsensitiveCompare(teamID) == .orderedSame } == true
    }
  }

  /// The account that holds projects of a GitHub user or organization (`github.com/<owner>/…` remotes).
  public func account(forGitHubOwner owner: String) -> VaultAccount? {
    let owner = owner.trimmingCharacters(in: .whitespaces)
    guard !owner.isEmpty else { return nil }
    return matchOrder.first { account in
      vault(for: account)?.projects.contains { $0.gitHubOwner?.caseInsensitiveCompare(owner) == .orderedSame } == true
    }
  }

  // MARK: Following Personal

  /// Drops the vaults of accounts deleted elsewhere and removes their stores here.
  private func personalReloaded() {
    guard let stores else { return }
    for id in stores.removeDeletedAccounts() { opened[id] = nil }
    for id in opened.keys where stores.isDeleted(account: id) { opened[id] = nil }
  }
}
