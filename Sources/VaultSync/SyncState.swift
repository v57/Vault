import Foundation
import VaultKit

/// What one device remembers about one synced folder between syncs: its index of the local copy as last synced,
/// the changes it read, how far it read each device's log, and its own counters. `FolderSync` keeps it sealed in
/// `Configuration.stateURL` (it holds plaintext names).
struct SyncState: Codable {
  /// A path as this device last synced it.
  struct IndexEntry: Codable, Equatable {
    var exists: Bool
    /// SHA-256 of the contents as synced (empty when it doesn't exist).
    var hash: String
    var size: Int64
    /// The local modification time when synced (seconds since 1970), for telling unchanged files apart without
    /// reading them.
    var modified: Double
    /// The remote heads the local copy reflects (empty for a conflict copy made here that no log has yet).
    var heads: [HybridClock]

    static func absent(_ heads: [HybridClock]) -> IndexEntry {
      IndexEntry(exists: false, hash: "", size: 0, modified: 0, heads: heads)
    }

    func matches(_ file: LocalFile?) -> Bool {
      guard let file else { return !exists }
      return exists && size == file.size && abs(modified - file.modified.timeIntervalSince1970) < 0.001
    }
  }

  var membersVersion = 0
  var index: [String: IndexEntry] = [:]
  /// Every change read, by path and clock.
  var changes: [String: [String: KnownChange]] = [:]
  /// How far each device's log was read (the last sequence number, read without gaps).
  var read: [String: Int] = [:]
  var nextSequence = 1
  /// The last clock this device issued.
  var clock = HybridClock.zero
  var snapshot: String?
  var snapshotCovered: [String: Int] = [:]
  var snapshotDate: Date?
  /// Read-only: remote heads the user chose to keep their own edit over (Keep Mine).
  var acknowledged: [String: [HybridClock]] = [:]
  /// Conflict copies made here or received.
  var conflictCopies: Set<String> = []
  /// Chunks first seen unreferenced, for the grace period before deleting them.
  var unreferencedSince: [String: Date] = [:]
  var lastCleanup: Date?
  var lastFacts: Date?
  var facts = FolderSyncStatus.RemoteFacts()
  var received: [FolderSyncStatus.Received] = []
  /// The signing keys seen in each device's log (for keeping a removed writer's earlier entries).
  var deviceAuthors: [String: Set<Data>] = [:]
  var ignored = 0

  func heads(_ path: String) -> [KnownChange] {
    guard let changes = changes[path] else { return [] }
    var parents = Set<HybridClock>()
    for change in changes.values { parents.formUnion(change.change.parents) }
    return changes.values.filter { !parents.contains($0.clock) }.sorted { $0.clock > $1.clock }
  }
}
