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
  /// `start` got past the entitlement check.
  private var wasStarted = false
  /// Zones whose last fetch failed: they haven't seen everything, whatever the fetch as a whole said.

  private var accountsToken: UUID?
  private var engine: CKSyncEngine?
  /// The private database the engine syncs with, for the explicit fetch.
  private var database: CKDatabase?
  /// An explicit fetch is under way: another `syncNow` leaves it to that one.
  private var isFetching = false
  private var observers: [NSObjectProtocol] = []
  private var outboxTimer: Timer?
  private static let log = Logger(subsystem: "dev.v57.vault", category: "sync")

  /// The last problem, for a status line.
  public private(set) var lastError: String?

  /// When this app last fetched from iCloud: an explicit fetch (`syncNow`) that reached every zone, or the engine
  /// fetching a zone. Nil until one has: a send, or a fetch the engine skipped, doesn't count (V-040).
  public var lastSynced: Date? { lock.withLock { synced } }
  private var synced: Date?

  private func noteSynced() { lock.withLock { synced = .now } }

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
  /// them reads. A build without `icloud-container-environment` = `Production` stays off (`VaultCloudEnvironment`
  /// reads it on iOS too), and its store is read-only once the vault has synced in Production (security audit M2).
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
      return VaultCloudEnvironment.current == VaultCloudEnvironment.production
    #endif
  }

  /// Starts syncing once the iCloud account is available, and again whenever it changes. While the user has iCloud off
  /// (`VaultICloud`) it only waits for the switch.
  public func start() {
    guard Self.isEntitled else {
      Self.log.notice(
        "Not entitled for \(VaultConfiguration.cloudContainer, privacy: .public) in Production: the vault stays on this device")
      return
    }
    if switchObserver == nil {
      switchObserver = VaultChangeObserver(name: VaultICloud.changeNotification) { [weak self] in
        self?.followSwitch()
      }
    }
    followSwitch()
  }

  /// Runs or stops to match the user's switch.
  private func followSwitch() {
    let isRunning = lock.withLock { wasStarted }
    if VaultICloud.isOff {
      if isRunning { stop() }
    } else if !isRunning {
      begin()
    }
  }

  /// Leaves CloudKit: no engine, no observers, no pushes. Nothing is lost: the engine's state stays in the store, and
  /// writes wait in the outbox for the next `begin`. What another app had leased goes back when the lease runs out.
  private func stop() {
    let engine: CKSyncEngine? = lock.withLock {
      defer {
        self.engine = nil
        database = nil
        wasStarted = false
      }
      return self.engine
    }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    changeObserver = nil
    outboxTimer?.invalidate()
    outboxTimer = nil
    if let accountsToken {
      zones.accounts.stopObserving(accountsToken)
      self.accountsToken = nil
    }
    let stores = lock.withLock {
      defer { attached = [:] }
      return Array(attached.values)
    }
    for store in stores {
      store.sendsOwnWrites = false
      store.didWriteLocally = nil
    }
    lock.withLock { healthy = nil }
    #if canImport(AppKit)
      NSApplication.shared.unregisterForRemoteNotifications()
    #else
      UIApplication.shared.unregisterForRemoteNotifications()
    #endif
    guard let engine else { return }
    Self.log.notice("iCloud is off: the vault stays on this device")
    Task { await engine.cancelOperations() }
  }

  private func begin() {
    lock.withLock { wasStarted = true }
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
  /// Follows the user's iCloud switch (`VaultICloud`).
  private var switchObserver: VaultChangeObserver?
  private static let productionMark = VaultStore.productionMark

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    outboxTimer?.invalidate()
    if let accountsToken { zones.accounts.stopObserving(accountsToken) }
  }

  private func startIfSignedIn() {
    // Still on the old file: `syncNow` tries again. An engine started now would lose what it fetched.
    guard !store.isWaitingToMigrate, !VaultICloud.isOff else { return }
    let container = CKContainer(identifier: VaultConfiguration.cloudContainer)
    Task {
      do {
        let status = try await container.accountStatus()
        guard status == .available else {
          Self.log.notice("iCloud account not available (\(status.rawValue)): the vault stays on this device")
          return
        }
        // The switch may have moved while CloudKit answered.
        guard !VaultICloud.isOff else { return }
        let subscription = await ensureSubscription(in: container.privateCloudDatabase)
        guard !VaultICloud.isOff else { return }
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
    store.recordCloudEnvironment(VaultCloudEnvironment.production)
    // Opens the accounts' stores, so a store that's still to migrate does it now, before anything is fetched.
    _ = zones.activeZones()
    let saved = zones.needsFullFetch ? nil : (try? store.engineState(name)).flatMap {
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
    database = container.privateCloudDatabase
    isFreshEngine = saved == nil
    lock.unlock()
    Self.log.notice(
      "Engine started (\(saved == nil ? "from nothing" : "saved state", privacy: .public), subscription \(subscriptionID ?? "none", privacy: .public))")

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
    if saved == nil { syncNow() }
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

  /// Fetches every zone and sends now: Sync Now, ⌘R, the app coming to the front, background refresh. Changes from
  /// other devices also arrive by push (the app's own subscription) where the app gets pushes, and at launch.
  ///
  /// The engine's `fetchChanges()` only fetches zones a push or the engine's launch marked changed, and iOS apps get
  /// no pushes without the remote-notification background mode, so on its own it fetched nothing on iPhone and iPad
  /// while the app stayed in front (V-040). `fetchEveryZone` asks the server itself.
  public func syncNow() {
    guard let engine = currentEngine else {
      if store.isWaitingToMigrate { _ = try? store.catchUp() }
      // Whatever moved the store on, a save or a Hub's catch-up or a restore as much as this, CloudKit starts now. Only
      // once `start` has seen the entitlement: asking without it traps.
      if lock.withLock({ wasStarted }) { startIfSignedIn() }
      return
    }
    queueOutbox()
    let database = lock.withLock { self.database }
    Task {
      do {
        try await engine.fetchChanges()
        do {
          if let database, try await fetchEveryZone(from: database) {
            noteSynced()
            onChange()
          }
        } catch let error as CKError where !Self.refusesThisApp(error) {
          // The network or a busy server: the next Sync Now or activation tries again, and the send still goes.
          record(error)
        }
        // The fetch worked: an app whose sync failed before takes its outbox again, so what waited goes up in this
        // pass instead of at the next timer or activation (V-039).
        if isHealthy == false {
          isHealthy = true
          queueOutbox()
        }
        try await engine.sendChanges()
        isHealthy = true
        onChange()
      } catch {
        record(error)
        isHealthy = false
      }
    }
  }

  /// Fetches what changed in every zone since this app's last explicit fetch, past the engine (which skips zones no push
  /// marked changed): lists the changed records' ids and change tags, downloads only those the store doesn't hold at that
  /// tag (`SyncCoordinator.idsToFetch`: what the engine or another app here fetched isn't downloaded again), and applies
  /// them as the engine's fetches are. Each zone keeps its own change token, in its store's engine state, so a reset of
  /// the store's server state starts it again. Returns false when another explicit fetch was under way.
  private func fetchEveryZone(from database: CKDatabase) async throws -> Bool {
    let isMine = lock.withLock {
      defer { isFetching = true }
      return !isFetching
    }
    guard isMine else { return false }
    defer { lock.withLock { isFetching = false } }
    var fetched: Set<String> = []
    // An account whose record arrived in Personal's zone opens its store, and its zone is fetched in the same pass.
    while true {
      let zonesLeft = zones.activeZones().filter { !fetched.contains($0) }
      if zonesLeft.isEmpty { break }
      for zone in zonesLeft {
        fetched.insert(zone)
        try await fetchZone(zone, from: database)
      }
    }
    return true
  }

  private func fetchZone(_ zone: String, from database: CKDatabase) async throws {
    guard case .zone(let coordinator) = zones.route(zone) else { return }
    let zoneID = CKRecordZone.ID(zoneName: zone)
    let tokenName = name + ".fetch." + zone
    var token = (try? coordinator.store.engineState(tokenName)).flatMap {
      try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
    }
    var listed: [(id: String, changeTag: String?)] = []
    var deleted: [String] = []
    var moreComing = true
    while moreComing {
      let changes: (
        modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
        deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool
      )
      do {
        // Only the system fields: what the store already has isn't downloaded.
        changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: [])
      } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
        Self.log.notice("Fetch now in \(zone, privacy: .public): token expired, listing the zone from the start")
        token = nil
        listed = []
        deleted = []
        continue
      } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
        // Not on the server yet, or deleted: the engine makes it or follows the deletion.
        return
      }
      for (id, result) in changes.modificationResultsByID {
        if case .success(let modification) = result { listed.append((id.recordName, modification.record.recordChangeTag)) }
      }
      deleted += changes.deletions.map(\.recordID.recordName)
      token = changes.changeToken
      moreComing = changes.moreComing
    }
    let toDownload = coordinator.idsToFetch(listed)
    var modified: [RemoteRecord] = []
    var unread: [UnreadRecord] = []
    var start = 0
    while start < toDownload.count {
      let chunk = toDownload[start..<min(start + 200, toDownload.count)]
      start += chunk.count
      for (_, result) in try await database.records(for: chunk.map { recordID($0, in: zone) }) {
        switch result {
        case .success(let record):
          switch Self.fetched(record) {
          case .record(let record): modified.append(record)
          case .unread(let record): unread.append(record)
          }
        case .failure(let error as CKError) where error.code == .unknownItem:
          // Deleted since the listing: the next listing says so.
          continue
        case .failure(let error):
          throw error
        }
      }
    }
    Self.log.notice(
      "Fetch now in \(zone, privacy: .public): \(listed.count) changed, \(modified.count + unread.count) downloaded, \(deleted.count) deletions")
    if !modified.isEmpty || !deleted.isEmpty || !unread.isEmpty {
      queue(coordinator.fetched(modified: modified, deleted: deleted, unread: unread), in: zone)
    }
    if let token, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
      try? coordinator.store.setEngineState(data, for: tokenName)
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
    guard isHealthy != false, currentEngine != nil else {
      if isHealthy == false { Self.log.notice("Outbox: not leased, this app's sync is failing") }
      return
    }
    for zone in zones.activeZones() {
      attach(zone)
      if let coordinator = zones.coordinator(forZone: zone) {
        let ids = coordinator.idsToSend()
        if !ids.isEmpty { Self.log.notice("Outbox: \(ids.count) to send in \(zone, privacy: .public)") }
        queue(ids, in: zone)
      }
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
        for store in activeStores { try? store.resetServerState(forAnotherAccount: true) }
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
      var unread: [String: [UnreadRecord]] = [:]
      for modification in changes.modifications {
        let zone = modification.record.recordID.zoneID.zoneName
        switch Self.fetched(modification.record) {
        case .record(let record): modified[zone, default: []].append(record)
        case .unread(let record): unread[zone, default: []].append(record)
        }
      }
      for deletion in changes.deletions {
        deleted[deletion.recordID.zoneID.zoneName, default: []].append(deletion.recordID.recordName)
      }
      for zone in Set(modified.keys).union(deleted.keys).union(unread.keys).sorted() {
        Self.log.notice(
          "Fetched in \(zone, privacy: .public): \(modified[zone]?.count ?? 0) records, \(deleted[zone]?.count ?? 0) deletions, \(unread[zone]?.count ?? 0) unread")
        switch zones.route(zone) {
        case .zone(let coordinator):
          queue(coordinator.fetched(modified: modified[zone] ?? [], deleted: deleted[zone] ?? [], unread: unread[zone] ?? []), in: zone)
        case .retired:
          // An account deleted on a device whose engine couldn't delete its zone.
          syncEngine.state.add(pendingDatabaseChanges: [.deleteZone(CKRecordZone.ID(zoneName: zone))])
        case .foreign:
          break
        }
      }
      isHealthy = true
      noteSynced()
      // Accounts that just arrived in Personal start syncing; deleted ones go.
      queueOutbox()
      onChange()

    case .didFetchChanges:
      // Not a sign that anything was fetched: the engine says so also when it skipped every zone (V-040).
      onChange()

    case .didFetchRecordZoneChanges(let fetch):
      // After this zone's last batch, the engine's events coming in order. One with an error isn't complete.
      guard fetch.error == nil else { break }
      zones.zoneFetched(fetch.zoneID.zoneName, fromNothing: lock.withLock { isFreshEngine })
      // The engine did fetch this zone, even when nothing in it changed.
      noteSynced()

    case .sentDatabaseChanges(let changes):
      for saved in changes.savedZones {
        try? zones.coordinator(forZone: saved.zoneID.zoneName)?.store
          .setEngineState(Data("1".utf8), for: name + ".zone")
      }
      for failure in changes.failedZoneSaves { record(failure.error) }

    case .sentRecordZoneChanges(let changes):
      let failures = changes.failedRecordSaves.map { "\($0.error.code.rawValue)" }.joined(separator: ",")
      Self.log.notice(
        "Sent: \(changes.savedRecords.count) saved, \(changes.deletedRecordIDs.count) deleted, \(changes.failedRecordSaves.count) failed [\(failures, privacy: .public)]")
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
        // CloudKit won't take this app's writes at all: it stops leasing the device's outbox, so an app whose sync
        // works sends them (V-039).
        if Self.refusesThisApp(failure.error) { isHealthy = false }
      }
      onChange()

    default:
      break
    }
  }

  public func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    // A send that was under way when the user turned iCloud off takes nothing more; it waits in the outbox.
    guard !VaultICloud.isOff else { return nil }
    let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
    guard !pending.isEmpty else { return nil }
    let skipped = OSAllocatedUnfairLock(initialState: 0)
    let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [zones] recordID in
      // Nil when another app holds the lease or nothing is waiting, or the zone's account is gone: the engine drops it.
      guard let coordinator = zones.coordinator(forZone: recordID.zoneID.zoneName),
        let outgoing = coordinator.record(for: recordID.recordName)
      else {
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        skipped.withLock { $0 += 1 }
        return nil
      }
      return Self.makeRecord(outgoing, id: recordID)
    }
    Self.log.notice(
      "Send: \(batch?.recordsToSave.count ?? 0) records, \(batch?.recordIDsToDelete.count ?? 0) deletions, \(skipped.withLock { $0 }) not this app's to send")
    return batch
  }

  // MARK: Records

  static let recordType = "Item"

  /// Payloads bigger than this go as an asset (a record holds about 1 MB in all).
  static let assetThreshold = 700_000

  /// Where a format 2 payload goes: fields old builds don't read (security audit M1). An old build takes a record only
  /// with a `keyID` and a `payload` (or `payloadAsset`); a format 2 record clears all three and fills these instead. If
  /// CloudKit honours the clearing, an old build skips the record. If it kept a cleared field, the server still holds
  /// the old format 1 `keyID` and payload together, which an old build opens as the version it had: never a payload it
  /// can't read under a key name it has, which it would store over its own copy and lose the item (Ideas/Security V1).
  static let sealedField = "sealed"
  static let sealedAssetField = "sealedAsset"

  static func makeRecord(_ outgoing: OutgoingRecord, id: CKRecord.ID) -> CKRecord {
    let record =
      outgoing.systemFields.flatMap(unarchive) ?? CKRecord(recordType: recordType, recordID: id)
    let isFormat2 = VaultItemSeal.parse(outgoing.payload) != nil
    let (field, assetField) = isFormat2 ? (sealedField, sealedAssetField) : ("payload", "payloadAsset")
    // Clearing a field counts as a change even on a record rebuilt from system fields alone, so the save carries it.
    for cleared in isFormat2 ? ["keyID", "payload", "payloadAsset"] : [sealedField, sealedAssetField] {
      record[cleared] = nil
    }
    if !isFormat2 { record["keyID"] = outgoing.keyID as NSString }
    if outgoing.payload.count > assetThreshold, let file = try? assetFile(for: outgoing) {
      record[field] = nil
      record[assetField] = CKAsset(fileURL: file)
    } else {
      record[field] = outgoing.payload as NSData
      record[assetField] = nil
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
    for field in ["payloadAsset", sealedAssetField] {
      if let url = (record[field] as? CKAsset)?.fileURL, url.path.contains("/VaultAssets/") {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  /// What a fetched record gave. A record whose payload couldn't be had is still a record: the sync engine's position has
  /// moved past it.
  enum FetchedRecord {
    case record(RemoteRecord)
    case unread(UnreadRecord)
  }

  static func fetched(_ record: CKRecord) -> FetchedRecord {
    let id = record.recordID.recordName
    // The format 2 fields first: where CloudKit kept a cleared format 1 payload, it's the older version.
    let asset = (record[sealedAssetField] ?? record["payloadAsset"]) as? CKAsset
    let payload: Data
    if let data = (record[sealedField] ?? (record[sealedAssetField] == nil ? record["payload"] : nil)) as? Data {
      payload = data
    } else if let url = asset?.fileURL, let data = try? Data(contentsOf: url) {
      payload = data
    } else {
      return .unread(UnreadRecord(id: id, changeTag: record.recordChangeTag, hasPayload: asset != nil))
    }
    guard let keyID = VaultItemSeal.parse(payload)?.keyID ?? record["keyID"] as? String else {
      return .unread(UnreadRecord(id: id, changeTag: record.recordChangeTag, hasPayload: false))
    }
    return .record(
      RemoteRecord(id: id, keyID: keyID, payload: payload, changeTag: record.recordChangeTag, systemFields: archive(record)))
  }

  static func remote(_ record: CKRecord) -> RemoteRecord? {
    if case .record(let remote) = fetched(record) { return remote }
    return nil
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

  /// Errors that say CloudKit refuses this app (its container, entitlement or account), not this one record.
  static func refusesThisApp(_ error: CKError) -> Bool {
    switch error.code {
    case .permissionFailure, .badContainer, .missingEntitlement, .notAuthenticated, .managedAccountRestricted: true
    default: false
    }
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
