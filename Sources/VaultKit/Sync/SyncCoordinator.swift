import Foundation

/// What went wrong sending one record, in CloudKit-neutral terms.
public enum SyncFailure: Error, Sendable, Equatable {
  /// Someone saved the record since this device last saw it; `server` is their copy.
  case conflict(server: RemoteRecord)
  /// The server has no such record (it was purged), so the change tag is stale.
  case unknownItem
  /// The record zone doesn't exist yet (first launch, or the user deleted the iCloud data).
  case zoneMissing
  /// Network, throttling, account trouble: try again later.
  case retryLater
  /// The record can't be saved as it is (too big, bad data): give up on it.
  case permanent
}

/// What the sync engine should do next with a record.
public enum SyncAction: Sendable, Equatable {
  case done
  case resend
  case createZoneThenResend
  case retryLater
}

/// A fetched record that couldn't be read, whatever it held.
public struct UnreadRecord: Sendable, Equatable {
  public var id: String
  public var changeTag: String?
  /// It has a payload that couldn't be read (an asset whose file wasn't there), which the server still holds. With
  /// false it never had one: there's nothing to wait for, and it's refused.
  public var hasPayload: Bool

  public init(id: String, changeTag: String?, hasPayload: Bool) {
    self.id = id
    self.changeTag = changeTag
    self.hasPayload = hasPayload
  }
}

/// The sync logic between the store and CloudKit, without CloudKit: `CloudSync` feeds it `CKSyncEngine`'s
/// events, and the tests feed it a fake server. One per process.
///
/// Sending: the engine asks for records by id; only items whose outbox lease this process holds become
/// records, so two apps never send the same change. Results come back here: a conflict merges the server's
/// copy into the store and sends again on top of it, which is how edits made on two devices at once both land.
///
/// Fetching: every record goes through `VaultStore.apply`, which skips versions the store already has (the
/// other apps on the device fetch the same changes).
public final class SyncCoordinator: @unchecked Sendable {
  public let store: VaultStore
  private let lock = NSLock()
  /// The version of each record on its way (to tell whether the item changed during the send), and when it
  /// left: one the engine never reported back on counts as gone after five minutes.
  private var inFlight: [String: (record: OutgoingRecord, sent: Date)] = [:]

  private var heldRecords: [String: RemoteRecord] = [:]
  private var heldDeletions: Set<String> = []
  private var fetchHasCompleted = false

  public init(store: VaultStore) {
    self.store = store
  }

  /// Outbox rows this process may send now (leasing them).
  public func idsToSend(limit: Int = 400) -> [String] {
    store.catchUpIfDue()
    retryHeld()
    return (try? store.claimOutbox(limit: limit)) ?? []
  }

  /// The record for an id, or nil when this process shouldn't send it now: another app holds the lease,
  /// nothing is waiting, or it's already on its way (a send that finds a newer version sends again).
  public func record(for id: String) -> OutgoingRecord? {
    lock.lock()
    let isOnItsWay = inFlight[id].map { Date.now.timeIntervalSince($0.sent) < 300 } ?? false
    lock.unlock()
    guard !isOnItsWay, let record = try? store.outgoing(id: id) else { return nil }
    lock.lock()
    inFlight[id] = (record, .now)
    lock.unlock()
    return record
  }

  private func takeRecord(_ id: String) -> OutgoingRecord? {
    lock.lock()
    defer { lock.unlock() }
    return inFlight.removeValue(forKey: id)?.record
  }

  /// The server saved a record. Returns `.resend` when the item changed while it was on its way.
  public func saved(id: String, changeTag: String?, systemFields: Data?) -> SyncAction {
    let sent = takeRecord(id)
    let again =
      (try? store.markSent(
        id: id, version: sent?.version ?? 0, changeTag: changeTag, systemFields: systemFields,
        sent: sent.map { ($0.keyID, $0.payload) })) ?? true
    return again ? .resend : .done
  }

  /// The server refused a record.
  public func failed(id: String, _ failure: SyncFailure) -> SyncAction {
    _ = takeRecord(id)
    switch failure {
    case .conflict(let server):
      // Merge their copy in; the merged item goes up again with the server's change tag. If it couldn't be read now, a
      // send would only meet the same conflict.
      switch try? store.apply(server) {
      case nil, .deferred: return .retryLater
      default: return (try? store.pendingIDs().contains(id)) == true ? .resend : .done
      }
    case .unknownItem:
      try? store.forgetServerRecord(id: id)
      return .resend
    case .zoneMissing:
      return .createZoneThenResend
    case .retryLater:
      // This app tries again, but holds nothing meanwhile: its next try takes the lease again unless another app has
      // sent the row. An app whose sends keep failing (or that's suspended between tries) would otherwise renew its lease
      // on every try and keep the device's other apps from ever sending the write (V-039).
      try? store.releaseLease(id: id)
      return .retryLater
    case .permanent:
      try? store.releaseLease(id: id)
      return .done
    }
  }

  /// A fetch from the start reached the end (`VaultStore.fetchCompleted`), which it hasn't with records still held here.
  public func fetchCompleted() {
    let isHolding = lock.withLock {
      fetchHasCompleted = !heldRecords.isEmpty || !heldDeletions.isEmpty
      return fetchHasCompleted
    }
    if !isHolding { store.fetchCompleted() }
  }

  /// What an explicit fetch downloads (`CloudSync.syncNow`, V-040): of the records a listing found changed since the
  /// app's last explicit fetch (ids and change tags, no payloads), those the store doesn't already hold at that tag.
  /// Whatever the sync engine or another app on the device fetched already isn't downloaded again.
  public func idsToFetch(_ listed: [(id: String, changeTag: String?)]) -> [String] {
    let known = (try? store.changeTags(ids: listed.map(\.id))) ?? [:]
    return listed.filter { $0.changeTag == nil || known[$0.id] != $0.changeTag }.map(\.id)
  }

  /// Records fetched from the server. `unread`: records that came without a payload this device could get at.
  public func fetched(modified: [RemoteRecord], deleted: [String], unread: [UnreadRecord] = []) -> [String] {
    store.withLock {
      store.withKeySweep {
        var toSend: [String] = []
        for record in unread { try? store.noteUnread(record) }
        for record in modified {
          do {
            switch try store.apply(record) {
            case .merged(needsSend: true), .refused(needsSend: true): toSend.append(record.id)
            default: break
            }
            lock.withLock { _ = heldRecords.removeValue(forKey: record.id) }
          } catch {
            lock.withLock { heldRecords[record.id] = record }
          }
        }
        for id in deleted {
          do {
            try store.applyDeletion(id: id)
            lock.withLock { _ = heldDeletions.remove(id) }
          } catch {
            lock.withLock { _ = heldDeletions.insert(id) }
          }
        }
        return toSend
      }
    }
  }

  /// `apply` threw only when it couldn't even write the record down (`VaultStore.apply`), or while the store waits to
  /// migrate. The sync engine's position has moved past those, so they're tried again here. A process that ends first
  /// loses them, which a store still to finish makes up for with its next full fetch.
  private func retryHeld() {
    let (records, deletions) = lock.withLock { (heldRecords, heldDeletions) }
    guard !records.isEmpty || !deletions.isEmpty else { return }
    _ = fetched(modified: Array(records.values), deleted: Array(deletions))
    let isDone = lock.withLock {
      guard heldRecords.isEmpty, heldDeletions.isEmpty, fetchHasCompleted else { return false }
      fetchHasCompleted = false
      return true
    }
    if isDone { store.fetchCompleted() }
  }
}
