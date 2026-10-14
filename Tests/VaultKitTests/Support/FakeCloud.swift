import CryptoKit
import Foundation

@testable import VaultKit

/// A CloudKit stand-in: records with change tags, conflicts on stale tags, and a change feed.
final class FakeCloud: @unchecked Sendable {
  private(set) var records: [String: RemoteRecord] = [:]
  private var log: [(sequence: Int, id: String, deleted: Bool)] = []
  private var sequence = 0
  private(set) var saves = 0

  /// The change tag a record was built on. Real records carry it in their archived system fields; here the
  /// system fields are just the tag's bytes.
  private func tag(of record: OutgoingRecord) -> String? {
    record.systemFields.flatMap { String(data: $0, encoding: .utf8) }
  }

  func save(_ record: OutgoingRecord) -> Result<String, SyncFailure> {
    let base = tag(of: record)
    if let current = records[record.id] {
      guard current.changeTag == base else { return .failure(.conflict(server: current)) }
    } else if base != nil {
      return .failure(.unknownItem)
    }
    sequence += 1
    saves += 1
    let newTag = "tag\(sequence)"
    records[record.id] = RemoteRecord(
      id: record.id, keyID: record.keyID, payload: record.payload, changeTag: newTag, systemFields: Data(newTag.utf8))
    log.append((sequence, record.id, false))
    return .success(newTag)
  }

  func delete(_ id: String) {
    guard records.removeValue(forKey: id) != nil else { return }
    sequence += 1
    log.append((sequence, id, true))
  }

  func changes(since token: Int) -> (modified: [RemoteRecord], deleted: [String], token: Int) {
    let entries = log.filter { $0.sequence > token }
    let ids = Set(entries.map(\.id))
    let modified = ids.compactMap { records[$0] }.sorted { $0.id < $1.id }
    let deleted = ids.filter { records[$0] == nil }.sorted()
    return (modified, deleted, sequence)
  }
}

/// One app on one device: its own connection to the device's store, its own sync engine state.
final class FakeApp {
  let store: VaultStore
  let sync: SyncCoordinator
  private var token = 0

  init(directory: URL, keys: VaultKeyProvider, device: String, name: String) throws {
    store = try VaultStore(directory: directory, keys: keys, deviceID: device, notifier: nil, owner: name)
    store.sendsOwnWrites = true
    sync = SyncCoordinator(store: store)
  }

  /// Sends what this app may send, handling conflicts like CloudSync does.
  func push(_ cloud: FakeCloud) {
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

  func pull(_ cloud: FakeCloud) {
    let changes = cloud.changes(since: token)
    token = changes.token
    _ = sync.fetched(modified: changes.modified, deleted: changes.deleted)
  }

  func sync(_ cloud: FakeCloud) {
    push(cloud)
    pull(cloud)
    push(cloud)
  }
}

/// A temporary folder per device.
func temporaryDirectory() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("VaultTests-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
