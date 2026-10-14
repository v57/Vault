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
  /// The version of each record on its way, to tell whether the item changed during the send.
  private var inFlight: [String: Int64] = [:]

  public init(store: VaultStore) {
    self.store = store
  }

  /// Outbox rows this process may send now (leasing them).
  public func idsToSend(limit: Int = 400) -> [String] {
    (try? store.claimOutbox(limit: limit)) ?? []
  }

  /// The record for an id, or nil when this process shouldn't send it (no lease, sent already).
  public func record(for id: String) -> OutgoingRecord? {
    guard let record = try? store.outgoing(id: id) else { return nil }
    lock.lock()
    inFlight[id] = record.version
    lock.unlock()
    return record
  }

  private func takeVersion(_ id: String) -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return inFlight.removeValue(forKey: id) ?? 0
  }

  /// The server saved a record. Returns `.resend` when the item changed while it was on its way.
  public func saved(id: String, changeTag: String?, systemFields: Data?) -> SyncAction {
    let version = takeVersion(id)
    let again = (try? store.markSent(id: id, version: version, changeTag: changeTag, systemFields: systemFields)) ?? true
    return again ? .resend : .done
  }

  /// The server refused a record.
  public func failed(id: String, _ failure: SyncFailure) -> SyncAction {
    _ = takeVersion(id)
    switch failure {
    case .conflict(let server):
      // Merge their copy in; the merged item goes up again with the server's change tag.
      _ = try? store.apply(server)
      return (try? store.pendingIDs().contains(id)) == true ? .resend : .done
    case .unknownItem:
      try? store.forgetServerRecord(id: id)
      return .resend
    case .zoneMissing:
      return .createZoneThenResend
    case .retryLater:
      return .retryLater
    case .permanent:
      try? store.releaseLease(id: id)
      return .done
    }
  }

  /// Records fetched from the server.
  public func fetched(modified: [RemoteRecord], deleted: [String]) -> [String] {
    var toSend: [String] = []
    for record in modified {
      if case .merged(let needsSend) = (try? store.apply(record)) ?? .unchanged, needsSend {
        toSend.append(record.id)
      }
    }
    for id in deleted { try? store.applyDeletion(id: id) }
    return toSend
  }
}
