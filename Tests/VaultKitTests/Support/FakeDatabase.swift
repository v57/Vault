import Foundation

@testable import VaultKit

/// CloudKit's private database with zones: a `FakeCloud` per zone, made on first save as CloudKit's zone save would,
/// and a log of deleted zones that every engine sees.
final class FakeDatabase: @unchecked Sendable {
  private(set) var zones: [String: FakeCloud] = [:]
  private(set) var deletedZones: [(sequence: Int, name: String)] = []
  private var sequence = 0

  var zoneNames: [String] { zones.keys.sorted() }

  func zone(_ name: String) -> FakeCloud {
    if let zone = zones[name] { return zone }
    let zone = FakeCloud()
    zones[name] = zone
    return zone
  }

  func deleteZone(_ name: String) {
    guard zones.removeValue(forKey: name) != nil else { return }
    sequence += 1
    deletedZones.append((sequence, name))
  }
}

/// One app syncing every zone through one engine, as `CloudSync` does: `SyncZones` routes each zone to its store.
final class FakeZonedApp {
  let zones: SyncZones
  private var tokens: [String: Int] = [:]
  private var seenDeletions = 0

  init(zones: SyncZones) {
    self.zones = zones
  }

  /// Sends every active zone's outbox, handling conflicts like CloudSync does, and deletes the zones of deleted
  /// accounts (unless `deletingZones` is off: a device whose engine couldn't).
  func push(_ database: FakeDatabase, deletingZones: Bool = true) {
    for zone in zones.activeZones() {
      guard let sync = zones.coordinator(forZone: zone) else { continue }
      sync.store.sendsOwnWrites = true
      let cloud = database.zone(zone)
      var queue = sync.idsToSend()
      var rounds = 0
      while !queue.isEmpty, rounds < 1000 {
        rounds += 1
        let id = queue.removeFirst()
        guard let record = sync.record(for: id) else { continue }
        let action: SyncAction
        switch cloud.save(record) {
        case .success(let tag): action = sync.saved(id: id, changeTag: tag, systemFields: Data(tag.utf8))
        case .failure(let failure): action = sync.failed(id: id, failure)
        }
        if action == .resend || action == .createZoneThenResend { queue.append(id) }
      }
    }
    // After `activeZones`, which removes the stores of accounts whose tombstone arrived.
    if deletingZones {
      for zone in zones.takeZonesToDelete() { database.deleteZone(zone) }
    }
  }

  /// Fetches the database's zone deletions, then the changed zones (`only`: just these, in this order).
  func pull(_ database: FakeDatabase, only: [String]? = nil) {
    if only == nil {
      for deletion in database.deletedZones where deletion.sequence > seenDeletions {
        seenDeletions = deletion.sequence
        tokens[deletion.name] = nil
        _ = zones.zoneDeleted(deletion.name, reason: .deleted)
      }
    }
    for name in only ?? database.zoneNames {
      guard let cloud = database.zones[name] else { continue }
      switch zones.route(name) {
      case .zone(let sync):
        let changes = cloud.changes(since: tokens[name] ?? 0)
        tokens[name] = changes.token
        _ = sync.fetched(modified: changes.modified, deleted: changes.deleted)
      case .retired:
        database.deleteZone(name)
      case .foreign:
        break
      }
    }
  }

  func sync(_ database: FakeDatabase) {
    push(database)
    pull(database)
    push(database)
  }
}

/// Hub's `hub-vault` with several vaults: a `FakeMailbox` per vault id.
final class FakeHub: @unchecked Sendable {
  private let lock = NSLock()
  private var vaults: [String: FakeMailbox] = [:]

  func mailbox(_ vault: String) -> FakeMailbox {
    lock.withLock {
      if let box = vaults[vault] { return box }
      let box = FakeMailbox()
      vaults[vault] = box
      return box
    }
  }

  func device(_ id: String) -> HubMailbox { View(hub: self, device: id) }

  struct View: HubMailbox {
    let hub: FakeHub
    let device: String
    func join(vault: String) async throws -> HubMailboxJoin { hub.mailbox(vault).join(device) }
    func push(vault: String, envelopes: [HubEnvelope]) async throws -> Int { hub.mailbox(vault).push(device, envelopes) }
    func pull(vault: String, after: Int, limit: Int) async throws -> HubMailboxPull {
      hub.mailbox(vault).pull(device, after, limit)
    }
    func ack(vault: String, seq: Int) async throws { hub.mailbox(vault).ack(device, seq) }
    func leave(vault: String, device: String) async throws { hub.mailbox(vault).leave(device) }
  }
}

/// A device: Personal's store, the accounts beside it, one app's engine and the app's `Vaults`.
@MainActor
final class FakeDevice {
  let name: String
  let directory = temporaryDirectory()
  let personal: VaultStore
  let stores: VaultAccountStores
  let app: FakeZonedApp
  let vaults: Vaults

  /// `personalKeys` shared by every device stand for iCloud Keychain.
  init(_ name: String, personalKeys: VaultKeyProvider) throws {
    self.name = name
    personal = try VaultStore(directory: directory, keys: personalKeys, deviceID: name, notifier: nil, owner: "\(name).app")
    stores = VaultAccountStores(personal: personal, notifier: nil)
    app = FakeZonedApp(zones: SyncZones(accounts: stores))
    vaults = Vaults(personal: Vault(store: personal), stores: stores)
  }

  /// Syncs, then reloads the vaults as the store's change notification would.
  func sync(_ database: FakeDatabase) {
    app.sync(database)
    reload()
  }

  func reload() {
    vaults.personal.reload()
    for account in vaults.accounts { vaults.vault(for: account)?.reload() }
  }

  func vault(_ name: String) -> Vault? {
    vaults.accounts.first { $0.name == name }.flatMap { vaults.vault(for: $0) }
  }

  var files: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".sqlite") }
      .sorted()
  }
}
