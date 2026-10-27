import Foundation

/// The vaults one app's sync engine carries, without CloudKit: Personal in the `Vault` zone and each account in
/// `Vault-<id>`, every zone routed to its own store and `SyncCoordinator`. CloudKit allows one sync engine per database
/// in Production, so `CloudSync` runs one for all of them and asks this where each record goes.
public final class SyncZones: @unchecked Sendable {
  /// Personal's zone, as it has been since the first build.
  public static let personalZone = "Vault"
  static let accountZonePrefix = "Vault-"

  public static func zoneName(forAccount id: String) -> String { accountZonePrefix + id }

  /// The account a zone holds; nil for Personal's and for zones that aren't the vault's.
  public static func accountID(inZone name: String) -> String? {
    guard name.hasPrefix(accountZonePrefix) else { return nil }
    let id = String(name.dropFirst(accountZonePrefix.count))
    return VaultAccount.isValidID(id) ? id : nil
  }

  public let accounts: VaultAccountStores
  public let personal: SyncCoordinator
  private let lock = NSLock()
  private var coordinators: [String: SyncCoordinator] = [:]
  /// Account zones deleted on the server while this process ran: they stay retired even before the account's
  /// tombstone arrives, so the engine doesn't make them again.
  private var deletedZones: Set<String> = []
  private var token: UUID?

  public init(accounts: VaultAccountStores) {
    self.accounts = accounts
    personal = SyncCoordinator(store: accounts.personal)
    token = accounts.observe { [weak self] event in
      if case .removed(let id) = event {
        self?.lock.withLock { _ = self?.coordinators.removeValue(forKey: Self.zoneName(forAccount: id)) }
      }
    }
  }

  deinit {
    if let token { accounts.stopObserving(token) }
  }

  public enum Route {
    case zone(SyncCoordinator)
    /// The zone of an account deleted on some device: nothing in it is kept, and the zone should go.
    case retired
    /// Not one of the vault's zones.
    case foreign
  }

  /// Where a zone's records go. An account's store opens on first use, so records that arrive before the account's
  /// record (or before any app here opened it) are kept.
  public func route(_ zone: String) -> Route {
    if zone == Self.personalZone { return .zone(personal) }
    guard let id = Self.accountID(inZone: zone) else { return .foreign }
    if lock.withLock({ deletedZones.contains(zone) }) { return .retired }
    if let coordinator = lock.withLock({ coordinators[zone] }) { return .zone(coordinator) }
    do {
      let store = try accounts.store(forAccount: id)
      return .zone(
        lock.withLock {
          if let coordinator = coordinators[zone], coordinator.store === store { return coordinator }
          let coordinator = SyncCoordinator(store: store)
          coordinators[zone] = coordinator
          return coordinator
        })
    } catch VaultAccountStores.AccountError.deleted {
      return .retired
    } catch {
      return .foreign
    }
  }

  public func coordinator(forZone zone: String) -> SyncCoordinator? {
    if case .zone(let coordinator) = route(zone) { return coordinator }
    return nil
  }

  /// Personal's zone and every live account's, their stores opened: the zones this app sends from. Stores of
  /// accounts deleted elsewhere are removed first.
  public func activeZones() -> [String] {
    accounts.removeDeletedAccounts()
    let ids = Set((try? accounts.accounts().map(\.id)) ?? []).union(accounts.openAccounts)
    return [Self.personalZone]
      + ids.sorted().map(Self.zoneName(forAccount:)).filter { coordinator(forZone: $0) != nil }
  }

  public enum ZoneDeletion: Sendable {
    /// The user deleted the app's data in iCloud settings.
    case purged
    /// A device deleted the zone.
    case deleted
    /// The user reset their encrypted data (lost the account's keys): the zone must be made again.
    case encryptedDataReset
  }

  /// A zone was deleted on the server. Returns whether to make it again (and send everything in it).
  ///
  /// Personal comes back unless the user purged it. An account's zone is deleted only by deleting the account, so its
  /// store here goes too; its record's tombstone comes through Personal.
  public func zoneDeleted(_ zone: String, reason: ZoneDeletion) -> Bool {
    if zone == Self.personalZone {
      switch reason {
      case .purged:
        try? accounts.personal.deleteAll()
        return false
      case .deleted, .encryptedDataReset:
        try? accounts.personal.resetServerState()
        return true
      }
    }
    guard let id = Self.accountID(inZone: zone) else { return false }
    switch reason {
    case .purged, .deleted:
      lock.withLock { _ = deletedZones.insert(zone) }
      try? accounts.remove(account: id, keys: false)
      return false
    case .encryptedDataReset:
      guard let store = coordinator(forZone: zone)?.store else { return false }
      try? store.resetServerState()
      return true
    }
  }
}
