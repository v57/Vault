import Foundation

/// The accounts' stores on this device (`VaultAccount`), opened on first use: `<id>.sqlite` beside Personal's
/// `Vault.sqlite`, sealed with Personal's keys. One per Personal store (`forPersonal`), shared by `Vaults` and the sync
/// engine (`SyncZones`), so both use one connection per account.
///
/// Thread-safe.
public final class VaultAccountStores: @unchecked Sendable {
  public let personal: VaultStore
  private let notifier: VaultChangeNotifier?
  private let lock = NSRecursiveLock()
  private var stores: [String: VaultStore] = [:]
  private var observers: [UUID: @Sendable (Event) -> Void] = [:]

  public enum Event: Sendable {
    /// An account's store was opened in this process.
    case opened(account: String, store: VaultStore)
    /// An account's store was removed (the account was deleted, here or on another device).
    case removed(account: String)
  }

  public enum AccountError: LocalizedError, Equatable {
    case invalidID(String)
    case deleted(String)
    /// Personal's store couldn't open, so neither can the accounts.
    case noStore
    case personal

    public var errorDescription: String? {
      switch self {
      case .invalidID(let id): "“\(id)” isn’t an account id."
      case .deleted: "This account was deleted."
      case .noStore: "The shared store couldn’t be opened."
      case .personal: "Personal can’t be deleted."
      }
    }
  }

  public init(personal: VaultStore, notifier: VaultChangeNotifier? = SystemChangeNotifier()) {
    self.personal = personal
    self.notifier = notifier
  }

  nonisolated(unsafe) private static var registries: [ObjectIdentifier: VaultAccountStores] = [:]
  private static let registriesLock = NSLock()

  /// The accounts beside a Personal store: the same object for every caller in the process.
  public static func forPersonal(_ store: VaultStore) -> VaultAccountStores {
    registriesLock.withLock {
      if let stores = registries[ObjectIdentifier(store)] { return stores }
      let stores = VaultAccountStores(personal: store)
      registries[ObjectIdentifier(store)] = stores
      return stores
    }
  }

  public static func fileName(forAccount id: String) -> String { "\(id).sqlite" }

  public func fileURL(forAccount id: String) -> URL {
    personal.directory.appendingPathComponent(Self.fileName(forAccount: id))
  }

  // MARK: Accounts

  /// The accounts, by name.
  public func accounts() throws -> [VaultAccount] {
    try personal.records(VaultAccount.self).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  /// Whether Personal holds the account's tombstone: it was deleted (an id Personal never saw is not).
  public func isDeleted(account id: String) -> Bool {
    (try? personal.item(id: id))?.isDeleted == true
  }

  /// Makes an account: its record in Personal. Its store opens on first use.
  public func create(name: String, color: String = "blue") throws -> VaultAccount {
    let account = VaultAccount(name: name, color: color)
    try personal.save(account)
    return account
  }

  // MARK: Stores

  /// The account's store, opened on first use. It opens before the account's record has arrived (another device's
  /// records may come first); it refuses an account that was deleted.
  public func store(forAccount id: String) throws -> VaultStore {
    guard VaultAccount.isValidID(id) else { throw AccountError.invalidID(id) }
    let (store, isNew): (VaultStore, Bool) = try lock.withLock {
      if let store = stores[id] { return (store, false) }
      guard !isDeleted(account: id) else { throw AccountError.deleted(id) }
      let store = try VaultStore(
        directory: personal.directory, fileName: Self.fileName(forAccount: id), accountID: id, keys: personal.keys,
        deviceID: personal.deviceID, notifier: notifier, owner: personal.owner)
      stores[id] = store
      return (store, true)
    }
    if isNew { notify(.opened(account: id, store: store)) }
    return store
  }

  /// The ids of the accounts whose stores this process opened.
  public var openAccounts: [String] { lock.withLock { stores.keys.sorted() } }

  /// Closes the account's store here and removes its file (its zone and record are the caller's). With `secrets`, the
  /// passwords and other secrets of its records go too (`VaultSecrets`, synced: on every device).
  public func remove(account id: String, secrets: Bool) throws {
    guard VaultAccount.isValidID(id) else { throw AccountError.invalidID(id) }
    let store = lock.withLock { stores.removeValue(forKey: id) }
    if secrets {
      let store = try store ?? VaultStore(
        directory: personal.directory, fileName: Self.fileName(forAccount: id), accountID: id, keys: personal.keys,
        deviceID: personal.deviceID, notifier: nil, owner: personal.owner)
      for item in try store.allIDs() { try VaultSecrets.deleteSecrets(forItem: item) }
    }
    VaultStore.removeFiles(at: fileURL(forAccount: id))
    notify(.removed(account: id))
  }

  /// Removes the stores of accounts deleted on another device (or by another app here): the open ones and the files
  /// left on disk. Returns their ids.
  @discardableResult
  public func removeDeletedAccounts() -> [String] {
    var ids = Set(openAccounts)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: personal.directory.path)) ?? []
    for file in files where file.hasSuffix(".sqlite") && file != VaultStore.fileName {
      ids.insert(String(file.dropLast(".sqlite".count)))
    }
    let deleted = ids.filter { VaultAccount.isValidID($0) && isDeleted(account: $0) }.sorted()
    for id in deleted { try? remove(account: id, secrets: false) }
    return deleted
  }

  // MARK: Observing

  /// Calls `handler` (on the thread that opened or removed) for every store opened or removed; returns a token for
  /// `stopObserving`.
  @discardableResult
  public func observe(_ handler: @escaping @Sendable (Event) -> Void) -> UUID {
    let id = UUID()
    lock.withLock { observers[id] = handler }
    return id
  }

  public func stopObserving(_ token: UUID) {
    lock.withLock { _ = observers.removeValue(forKey: token) }
  }

  private func notify(_ event: Event) {
    for handler in lock.withLock({ Array(observers.values) }) { handler(event) }
  }
}
