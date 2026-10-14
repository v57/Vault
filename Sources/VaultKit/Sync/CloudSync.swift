import CloudKit
import Foundation
import os

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// Syncs the store with the private CloudKit database through `CKSyncEngine`, one engine per app.
///
/// There's no helper process: every app that opens the vault runs its own engine (with its own saved state)
/// against the same `Vault` zone. The app that writes leases and sends its change; every app fetches and
/// merges, and `VaultStore.apply` skips what another app on the device already applied. Conflicts merge field
/// by field (`SyncCoordinator`), so an iPhone and a Mac editing the same item at once both keep their edits.
///
/// CloudKit only ever sees the item id, the key id and the AES-GCM payload.
public final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
  public let store: VaultStore
  private let coordinator: SyncCoordinator
  private let onChange: @Sendable () -> Void
  private let name: String
  private let zoneID = CKRecordZone.ID(zoneName: "Vault")
  private let lock = NSLock()
  private var engine: CKSyncEngine?
  private var observers: [NSObjectProtocol] = []
  private var outboxTimer: Timer?
  private static let log = Logger(subsystem: "dev.v57.vault", category: "sync")

  /// The last problem, for a status line.
  public private(set) var lastError: String?

  public init(store: VaultStore, onChange: @escaping @Sendable () -> Void = {}) {
    self.store = store
    coordinator = SyncCoordinator(store: store)
    self.onChange = onChange
    name = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
  }

  /// Whether this app is signed with the vault's CloudKit container (without it CloudKit traps).
  public static var isEntitled: Bool {
    #if os(macOS)
      guard let task = SecTaskCreateFromSelf(nil) else { return false }
      let containers =
        SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        as? [String]
      let services =
        SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]
      return containers?.contains(VaultConfiguration.cloudContainer) == true && services?.contains("CloudKit") == true
    #else
      return true
    #endif
  }

  /// Starts syncing once the iCloud account is available, and again whenever it changes.
  public func start() {
    guard Self.isEntitled else {
      Self.log.notice("Not entitled for \(VaultConfiguration.cloudContainer, privacy: .public): the vault stays on this device")
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

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    outboxTimer?.invalidate()
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
        startEngine(container)
      } catch {
        record(error)
      }
    }
  }

  private func startEngine(_ container: CKContainer) {
    let saved = (try? store.engineState(name)).flatMap {
      try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
    }
    lock.lock()
    guard engine == nil else {
      lock.unlock()
      return
    }
    let configuration = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
    let engine = CKSyncEngine(configuration)
    self.engine = engine
    lock.unlock()

    if saved == nil || (try? store.engineState(name + ".zone")) == nil {
      engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }
    store.sendsOwnWrites = true
    store.didWriteLocally = { [weak self] ids in self?.queue(ids) }
    if let purged = try? store.purgeTombstones(), !purged.isEmpty {
      engine.state.add(pendingRecordZoneChanges: purged.map { .deleteRecord(recordID($0)) })
    }
    queueOutbox()
  }

  /// Sends and fetches now (the app came to the front).
  public func syncNow() {
    guard let engine = currentEngine else { return }
    queueOutbox()
    Task {
      do {
        try await engine.fetchChanges()
        try await engine.sendChanges()
      } catch {
        record(error)
      }
    }
  }

  private var currentEngine: CKSyncEngine? {
    lock.lock()
    defer { lock.unlock() }
    return engine
  }

  /// Leases what's waiting in the outbox and hands it to the engine.
  private func queueOutbox() {
    queue(coordinator.idsToSend())
  }

  private func queue(_ ids: [String]) {
    guard let engine = currentEngine, !ids.isEmpty else { return }
    engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(recordID($0)) })
  }

  private func recordID(_ id: String) -> CKRecord.ID {
    CKRecord.ID(recordName: id, zoneID: zoneID)
  }

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
        try? store.resetServerState()
      @unknown default:
        break
      }

    case .fetchedDatabaseChanges(let changes):
      for deletion in changes.deletions where deletion.zoneID == zoneID {
        switch deletion.reason {
        case .purged:
          // The user deleted the data in iCloud settings: delete it here too.
          try? store.deleteAll()
        case .deleted, .encryptedDataReset:
          try? store.resetServerState()
          try? store.setEngineState(nil, for: name + ".zone")
          syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
          queueOutbox()
        @unknown default:
          break
        }
      }

    case .fetchedRecordZoneChanges(let changes):
      let modified = changes.modifications.compactMap { Self.remote($0.record) }
      let deleted = changes.deletions.map(\.recordID.recordName)
      let resend = coordinator.fetched(modified: modified, deleted: deleted)
      queue(resend)
      onChange()

    case .sentDatabaseChanges(let changes):
      if changes.savedZones.contains(where: { $0.zoneID == zoneID }) {
        try? store.setEngineState(Data("1".utf8), for: name + ".zone")
      }
      for failure in changes.failedZoneSaves { record(failure.error) }

    case .sentRecordZoneChanges(let changes):
      for saved in changes.savedRecords {
        let action = coordinator.saved(
          id: saved.recordID.recordName, changeTag: saved.recordChangeTag, systemFields: Self.archive(saved))
        if action == .resend { queue([saved.recordID.recordName]) }
      }
      for failure in changes.failedRecordSaves {
        let id = failure.record.recordID.recordName
        let action = coordinator.failed(id: id, Self.failure(failure.error))
        switch action {
        case .resend, .retryLater:
          syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
        case .createZoneThenResend:
          syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
          syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
        case .done:
          break
        }
        if action == .retryLater || action == .done { record(failure.error) }
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
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [coordinator] recordID in
      // Nil when another app holds the lease or nothing is waiting: the engine drops it.
      guard let outgoing = coordinator.record(for: recordID.recordName) else {
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
      }
      return Self.makeRecord(outgoing, id: recordID)
    }
  }

  // MARK: Records

  static let recordType = "Item"

  static func makeRecord(_ outgoing: OutgoingRecord, id: CKRecord.ID) -> CKRecord {
    let record =
      outgoing.systemFields.flatMap(unarchive) ?? CKRecord(recordType: recordType, recordID: id)
    record["payload"] = outgoing.payload as NSData
    record["keyID"] = outgoing.keyID as NSString
    return record
  }

  static func remote(_ record: CKRecord) -> RemoteRecord? {
    guard let payload = record["payload"] as? Data, let keyID = record["keyID"] as? String else { return nil }
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
