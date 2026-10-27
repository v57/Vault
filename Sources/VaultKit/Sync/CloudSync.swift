#if canImport(CloudKit)
import CloudKit
import Foundation
import os

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// Syncs the stores with the private CloudKit database through `CKSyncEngine`, one engine per app.
///
/// There's no helper process: every app that opens the vault runs its own engine (with its own saved state)
/// against the same zones: Personal's `Vault` and each account's `Vault-<id>` (`SyncZones` routes each zone to its
/// store; CloudKit allows one engine per database in Production). The app that writes leases and sends its change;
/// every app fetches and merges, and `VaultStore.apply` skips what another app on the device already applied.
/// Conflicts merge field by field (`SyncCoordinator`), so an iPhone and a Mac editing the same item at once both keep
/// their edits.
///
/// CloudKit only ever sees the item id, the key id and the AES-GCM payload.
public final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
  /// Personal's store, which also keeps the engine's state.
  public let store: VaultStore
  public let zones: SyncZones
  private let onChange: @Sendable () -> Void
  private let name: String
  private let lock = NSLock()
  /// The stores whose writes this engine queues, by zone.
  private var attached: [String: VaultStore] = [:]
  /// The engine started without saved state: every zone is made again (saving an existing zone changes nothing).
  private var isFreshEngine = false
  private var accountsToken: UUID?
  private var engine: CKSyncEngine?
  private var observers: [NSObjectProtocol] = []
  private var outboxTimer: Timer?
  private static let log = Logger(subsystem: "dev.v57.vault", category: "sync")

  /// The last problem, for a status line.
  public private(set) var lastError: String?

  /// Whether this app's sync works: nil until it's known. While it fails, the app takes no outbox leases and
  /// leaves its own writes unleased, so an app whose sync works sends them.
  private var isHealthy: Bool? {
    get { lock.withLock { healthy } }
    set {
      lock.withLock { healthy = newValue }
      for store in lock.withLock({ Array(attached.values) }) { store.sendsOwnWrites = newValue != false }
    }
  }
  private var healthy: Bool?

  /// Syncs Personal (`store`) and the accounts beside it (`VaultAccountStores.forPersonal`).
  public convenience init(store: VaultStore, onChange: @escaping @Sendable () -> Void = {}) {
    self.init(zones: SyncZones(accounts: .forPersonal(store)), onChange: onChange)
  }

  public init(zones: SyncZones, onChange: @escaping @Sendable () -> Void = {}) {
    self.zones = zones
    store = zones.accounts.personal
    self.onChange = onChange
    name = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
  }

  /// Whether this app is signed with the vault's CloudKit container (without it CloudKit traps), in CloudKit's
  /// Production environment.
  ///
  /// Every app on a device shares one store, and what one app sends is sent for all of them, so they must all sync
  /// in one environment: a debug build signed for Development would take the others' writes to a database none of
  /// them reads. On the Mac a build without `icloud-container-environment` = `Production` stays off; iOS can't read
  /// its entitlements, so there it's the app's job.
  public static var isEntitled: Bool {
    #if os(macOS)
      guard let task = SecTaskCreateFromSelf(nil) else { return false }
      let containers =
        SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        as? [String]
      let services =
        SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]
      let environment =
        SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil)
        as? String
      return containers?.contains(VaultConfiguration.cloudContainer) == true && services?.contains("CloudKit") == true
        && environment == "Production"
    #else
      return true
    #endif
  }

  /// Starts syncing once the iCloud account is available, and again whenever it changes.
  public func start() {
    guard Self.isEntitled else {
      Self.log.notice(
        "Not entitled for \(VaultConfiguration.cloudContainer, privacy: .public) in Production: the vault stays on this device")
      return
    }
    observers.append(
      NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
        self?.startIfSignedIn()
      })
    #if canImport(AppKit)
      let activation = NSApplication.didBecomeActiveNotification
    #else
      let activation = UIApplication.didBecomeActiveNotification
    #endif
    observers.append(
      NotificationCenter.default.addObserver(forName: activation, object: nil, queue: .main) { [weak self] _ in
        self?.syncNow()
      })
    // Other apps' writes that nobody sends (their writer has no sync, or quit before its lease ran out).
    changeObserver = VaultChangeObserver { [weak self] in self?.queueOutbox() }
    outboxTimer = Timer.scheduledTimer(withTimeInterval: store.lease, repeats: true) { [weak self] _ in
      self?.queueOutbox()
    }
    // CloudKit's pushes (other devices' changes) come through the app's remote notification registration,
    // once the app is running (`start` may be called from the App's init).
    DispatchQueue.main.async {
      #if canImport(AppKit)
        NSApplication.shared.registerForRemoteNotifications()
      #else
        UIApplication.shared.registerForRemoteNotifications()
      #endif
    }
    startIfSignedIn()
  }

  /// Whether the engine runs (signed in, entitled).
  public var isRunning: Bool { currentEngine != nil }

  private var changeObserver: VaultChangeObserver?
  private static let productionMark = "environment.production"

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    outboxTimer?.invalidate()
    if let accountsToken { zones.accounts.stopObserving(accountsToken) }
  }

  private func startIfSignedIn() {
    let container = CKContainer(identifier: VaultConfiguration.cloudContainer)
    Task {
      do {
        let status = try await container.accountStatus()
        guard status == .available else {
          Self.log.notice("iCloud account not available (\(status.rawValue)): the vault stays on this device")
          return
        }
        let subscription = await ensureSubscription(in: container.privateCloudDatabase)
        startEngine(container, subscriptionID: subscription)
      } catch {
        record(error)
      }
    }
  }

  /// Each app's own database subscription (its pushes): a sync engine left to itself uses one fixed
  /// subscription id, which the first app to save it owns, and the server refuses it to every other app
  /// ("Invalid bundle ID for container"). Made once; nil when it can't be saved (the engine then fetches on
  /// launch and activation only).
  private func ensureSubscription(in database: CKDatabase) async -> CKSubscription.ID? {
    let id = "vault-" + name
    if (try? store.engineState(name + ".subscription")) != nil { return id }
    let subscription = CKDatabaseSubscription(subscriptionID: id)
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true
    subscription.notificationInfo = info
    do {
      _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
      try? store.setEngineState(Data("1".utf8), for: name + ".subscription")
      return id
    } catch {
      record(error)
      isHealthy = false
      return nil
    }
  }

  private func startEngine(_ container: CKContainer, subscriptionID: CKSubscription.ID?) {
    // Until 2026-10-26 debug builds synced in Development and releases in Production, so a write one sent went to
    // a database the others never read: every item goes up once more, now that they all use Production.
    if (try? store.engineState(Self.productionMark)) == nil {
      try? store.resetServerState()
      try? store.setEngineState(Data("1".utf8), for: Self.productionMark)
    }
    let saved = (try? store.engineState(name)).flatMap {
      try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
    }
    lock.lock()
    guard engine == nil else {
      lock.unlock()
      return
    }
    var configuration = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
    configuration.subscriptionID = subscriptionID
    let engine = CKSyncEngine(configuration)
    self.engine = engine
    isFreshEngine = saved == nil
    lock.unlock()

    accountsToken = zones.accounts.observe { [weak self] event in
      switch event {
      case .opened(let id, _): self?.attach(SyncZones.zoneName(forAccount: id))
      case .removed(let id):
        self?.detach(SyncZones.zoneName(forAccount: id))
        self?.queueZoneDeletions()
      }
    }
    for zone in zones.activeZones() { attach(zone) }
    queueOutbox()
  }

  /// Starts carrying a zone: makes it on the server unless this app did already, queues the store's own writes, and
  /// deletes CloudKit's copies of old tombstones.
  private func attach(_ zone: String) {
    guard let engine = currentEngine, let store = zones.coordinator(forZone: zone)?.store else { return }
    let (isNew, isFresh) = lock.withLock {
      guard attached[zone] !== store else { return (false, isFreshEngine) }
      attached[zone] = store
      return (true, isFreshEngine)
    }
    guard isNew else { return }
    let zoneID = CKRecordZone.ID(zoneName: zone)
    if isFresh || (try? store.engineState(name + ".zone")) == nil {
      engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }
    store.sendsOwnWrites = isHealthy != false
    store.didWriteLocally = { [weak self] ids in self?.queue(ids, in: zone) }
    if let purged = try? store.purgeTombstones(), !purged.isEmpty {
      engine.state.add(pendingRecordZoneChanges: purged.map { .deleteRecord(recordID($0, in: zone)) })
    }
  }

  /// Stops carrying an account's zone whose store was removed here; what waited to go up in it is dropped.
  private func detach(_ zone: String) {
    lock.withLock { _ = attached.removeValue(forKey: zone) }
    guard let engine = currentEngine else { return }
    let zoneID = CKRecordZone.ID(zoneName: zone)
    engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges.filter { change in
      switch change {
      case .saveRecord(let id), .deleteRecord(let id): id.zoneID == zoneID
      @unknown default: false
      }
    })
  }

  /// Deletes the zones of deleted accounts on the server (`SyncZones.takeZonesToDelete`).
  private func queueZoneDeletions() {
    guard let engine = currentEngine else { return }
    let zoneIDs = zones.takeZonesToDelete().map { CKRecordZone.ID(zoneName: $0) }
    if !zoneIDs.isEmpty { engine.state.add(pendingDatabaseChanges: zoneIDs.map { .deleteZone($0) }) }
  }

  /// Sends now, and fetches what pushes reported (the app came to the front). Changes from other devices
  /// arrive by push (the app's own subscription) within a minute or so, and at launch.
  public func syncNow() {
    guard let engine = currentEngine else { return }
    queueOutbox()
    Task {
      do {
        try await engine.fetchChanges()
        try await engine.sendChanges()
        isHealthy = true
      } catch {
        record(error)
        isHealthy = false
      }
    }
  }

  private var currentEngine: CKSyncEngine? {
    lock.lock()
    defer { lock.unlock() }
    return engine
  }

  /// Leases what's waiting in every zone's outbox and hands it to the engine (not while this app's sync fails).
  /// Accounts that arrived since are attached first.
  private func queueOutbox() {
    guard isHealthy != false, currentEngine != nil else { return }
    for zone in zones.activeZones() {
      attach(zone)
      if let coordinator = zones.coordinator(forZone: zone) { queue(coordinator.idsToSend(), in: zone) }
    }
    queueZoneDeletions()
  }

  private func queue(_ ids: [String], in zone: String) {
    guard let engine = currentEngine, !ids.isEmpty else { return }
    engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(recordID($0, in: zone)) })
  }

  private func recordID(_ id: String, in zone: String) -> CKRecord.ID {
    CKRecord.ID(recordName: id, zoneID: CKRecordZone.ID(zoneName: zone))
  }

  /// The stores of every zone this app carries.
  private var activeStores: [VaultStore] { lock.withLock { Array(attached.values) } }

  private func record(_ error: Error) {
    lastError = error.localizedDescription
    Self.log.error("Sync: \(error.localizedDescription, privacy: .public)")
  }

  // MARK: CKSyncEngineDelegate

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    switch event {
    case .stateUpdate(let update):
      try? store.setEngineState(try? JSONEncoder().encode(update.stateSerialization), for: name)

    case .accountChange(let change):
      switch change.changeType {
      case .signIn:
        queueOutbox()
      case .switchAccounts, .signOut:
        // What the old account's server held means nothing now; everything goes up again on the next account.
        for store in activeStores { try? store.resetServerState() }
      @unknown default:
        break
      }

    case .fetchedDatabaseChanges(let changes):
      for deletion in changes.deletions {
        let zone = deletion.zoneID.zoneName
        let reason: SyncZones.ZoneDeletion
        switch deletion.reason {
        case .purged: reason = .purged
        case .deleted: reason = .deleted
        case .encryptedDataReset: reason = .encryptedDataReset
        @unknown default: continue
        }
        lock.withLock { _ = attached.removeValue(forKey: zone) }
        if zones.zoneDeleted(zone, reason: reason), let store = zones.coordinator(forZone: zone)?.store {
          try? store.setEngineState(nil, for: name + ".zone")
          syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: deletion.zoneID))])
        } else {
          detach(zone)
        }
      }
      queueOutbox()

    case .fetchedRecordZoneChanges(let changes):
      var modified: [String: [RemoteRecord]] = [:]
      var deleted: [String: [String]] = [:]
      for modification in changes.modifications {
        if let record = Self.remote(modification.record) {
          modified[modification.record.recordID.zoneID.zoneName, default: []].append(record)
        }
      }
      for deletion in changes.deletions {
        deleted[deletion.recordID.zoneID.zoneName, default: []].append(deletion.recordID.recordName)
      }
      for zone in Set(modified.keys).union(deleted.keys).sorted() {
        switch zones.route(zone) {
        case .zone(let coordinator):
          queue(coordinator.fetched(modified: modified[zone] ?? [], deleted: deleted[zone] ?? []), in: zone)
        case .retired:
          // An account deleted on a device whose engine couldn't delete its zone.
          syncEngine.state.add(pendingDatabaseChanges: [.deleteZone(CKRecordZone.ID(zoneName: zone))])
        case .foreign:
          break
        }
      }
      isHealthy = true
      // Accounts that just arrived in Personal start syncing; deleted ones go.
      queueOutbox()
      onChange()

    case .sentDatabaseChanges(let changes):
      for saved in changes.savedZones {
        try? zones.coordinator(forZone: saved.zoneID.zoneName)?.store
          .setEngineState(Data("1".utf8), for: name + ".zone")
      }
      for failure in changes.failedZoneSaves { record(failure.error) }

    case .sentRecordZoneChanges(let changes):
      if !changes.savedRecords.isEmpty { isHealthy = true }
      for saved in changes.savedRecords {
        Self.removeAssetFile(of: saved)
        let zone = saved.recordID.zoneID.zoneName
        guard let coordinator = zones.coordinator(forZone: zone) else { continue }
        let action = coordinator.saved(
          id: saved.recordID.recordName, changeTag: saved.recordChangeTag, systemFields: Self.archive(saved))
        if action == .resend { queue([saved.recordID.recordName], in: zone) }
      }
      for failure in changes.failedRecordSaves {
        Self.removeAssetFile(of: failure.record)
        let id = failure.record.recordID.recordName
        guard let coordinator = zones.coordinator(forZone: failure.record.recordID.zoneID.zoneName) else { continue }
        let action = coordinator.failed(id: id, Self.failure(failure.error))
        switch action {
        case .resend, .retryLater:
          syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
        case .createZoneThenResend:
          syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: failure.record.recordID.zoneID))])
          syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
        case .done:
          break
        }
        // A conflict that merged is the normal path, not a problem to report.
        if action == .retryLater || (action == .done && failure.error.code != .serverRecordChanged) {
          record(failure.error)
        }
      }
      onChange()

    default:
      break
    }
  }

  public func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
    guard !pending.isEmpty else { return nil }
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [zones] recordID in
      // Nil when another app holds the lease or nothing is waiting, or the zone's account is gone: the engine drops it.
      guard let coordinator = zones.coordinator(forZone: recordID.zoneID.zoneName),
        let outgoing = coordinator.record(for: recordID.recordName)
      else {
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
      }
      return Self.makeRecord(outgoing, id: recordID)
    }
  }

  // MARK: Records

  static let recordType = "Item"

  /// Payloads bigger than this go as an asset (a record holds about 1 MB in all).
  static let assetThreshold = 700_000

  static func makeRecord(_ outgoing: OutgoingRecord, id: CKRecord.ID) -> CKRecord {
    let record =
      outgoing.systemFields.flatMap(unarchive) ?? CKRecord(recordType: recordType, recordID: id)
    record["keyID"] = outgoing.keyID as NSString
    if outgoing.payload.count > assetThreshold, let file = try? assetFile(for: outgoing) {
      record["payload"] = nil
      record["payloadAsset"] = CKAsset(fileURL: file)
    } else {
      record["payload"] = outgoing.payload as NSData
      record["payloadAsset"] = nil
    }
    return record
  }

  /// The encrypted payload as a file for a `CKAsset` (removed after the send).
  static func assetFile(for outgoing: OutgoingRecord) throws -> URL {
    let folder = URL.cachesDirectory.appendingPathComponent("VaultAssets", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("\(outgoing.id)-\(outgoing.version)")
    try outgoing.payload.write(to: file, options: .atomic)
    return file
  }

  static func removeAssetFile(of record: CKRecord) {
    if let url = (record["payloadAsset"] as? CKAsset)?.fileURL, url.path.contains("/VaultAssets/") {
      try? FileManager.default.removeItem(at: url)
    }
  }

  static func remote(_ record: CKRecord) -> RemoteRecord? {
    guard let keyID = record["keyID"] as? String else { return nil }
    let payload: Data
    if let data = record["payload"] as? Data {
      payload = data
    } else if let url = (record["payloadAsset"] as? CKAsset)?.fileURL, let data = try? Data(contentsOf: url) {
      payload = data
    } else {
      return nil
    }
    return RemoteRecord(
      id: record.recordID.recordName, keyID: keyID, payload: payload, changeTag: record.recordChangeTag,
      systemFields: archive(record))
  }

  static func archive(_ record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  static func unarchive(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    coder.requiresSecureCoding = true
    defer { coder.finishDecoding() }
    return CKRecord(coder: coder)
  }

  static func failure(_ error: CKError) -> SyncFailure {
    switch error.code {
    case .serverRecordChanged:
      guard let server = error.serverRecord.flatMap(remote) else { return .retryLater }
      return .conflict(server: server)
    case .zoneNotFound, .userDeletedZone:
      return .zoneMissing
    case .unknownItem:
      return .unknownItem
    case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
      .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled, .quotaExceeded:
      return .retryLater
    default:
      return .permanent
    }
  }
}
#endif
