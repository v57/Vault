import Foundation
import VaultKit

/// What syncing one folder is doing, for the UI: a plain value the app copies into its own observable model
/// (`FolderSync.observe`).
public struct FolderSyncStatus: Sendable, Equatable {
  public enum Phase: String, Sendable {
    case idle
    /// Reading the member list and the other devices' logs.
    case checking
    case receiving
    case sending
    /// Making a snapshot or deleting chunks nothing uses.
    case cleaning
  }

  /// A file on its way in or out.
  public struct Transfer: Sendable, Equatable, Identifiable {
    public var path: String
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public var id: String { path }
    public var name: String { FolderSyncStatus.name(of: path) }
    /// 0…1.
    public var progress: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 1 }
  }

  /// A local edit a read-only device keeps and never sends.
  public struct ChangedFile: Sendable, Equatable, Identifiable {
    public enum Change: String, Sendable {
      case added
      case modified
      case deleted
    }

    public var path: String
    public var change: Change
    /// The local size (0 when deleted).
    public var size: Int64
    public var modified: Date?

    public var id: String { path }
    public var name: String { FolderSyncStatus.name(of: path) }
  }

  /// A file a read-only device changed locally that the remote changed too. The local edit stays until the user
  /// picks (`FolderSync.keepMine` or `revertToRemote`).
  public struct Conflict: Sendable, Equatable, Identifiable {
    public struct Side: Sendable, Equatable {
      /// nil when the file is deleted on that side.
      public var size: Int64?
      public var modified: Date?
      /// The device that wrote it (the remote side).
      public var device: String?
      /// The contents, for a text file of at most 1 MB.
      public var text: String?
    }

    public var path: String
    public var mine: Side
    public var remote: Side

    public var id: String { path }
    public var name: String { FolderSyncStatus.name(of: path) }
  }

  /// A file that arrived from another device.
  public struct Received: Sendable, Equatable, Identifiable, Codable {
    public var path: String
    public var size: Int64
    public var date: Date
    /// The device that wrote it.
    public var device: String
    public var deleted: Bool

    public var id: String { path + "@" + String(date.timeIntervalSince1970) }
    public var name: String { FolderSyncStatus.name(of: path) }
  }

  /// What the remote holds.
  public struct RemoteFacts: Sendable, Equatable, Codable {
    public var chunkCount = 0
    public var chunkBytes: Int64 = 0
    /// Devices with a change log.
    public var changeLogs = 0
    /// Log files across all devices.
    public var logFiles = 0
    public var lastSnapshot: Date?
    /// The end of the last sync that reached the remote.
    public var lastCheck: Date?
  }

  public var phase: Phase = .idle
  /// What this device does now: its own mode, or read-only when its person is a read-only member.
  public var mode: VaultFolder.Mode = .readWrite
  public var role: VaultPerson.Role?
  public var receiving: [Transfer] = []
  public var receivingDone = 0
  public var receivingTotal = 0
  public var receivingBytes: Int64 = 0
  public var sending: [Transfer] = []
  public var sendingDone = 0
  public var sendingTotal = 0
  /// Local edits a read-only device keeps ("Changed here").
  public var changedHere: [ChangedFile] = []
  public var conflicts: [Conflict] = []
  /// Paths of conflict copies: the losing side of edits made at once that couldn't merge.
  public var conflictCopies: [String] = []
  /// Newest first.
  public var receivedRecently: [Received] = []
  public var remote = RemoteFacts()
  /// Changes in the logs from people without write access, ignored.
  public var ignoredChanges = 0
  /// The last sync's error, or a file it couldn't apply.
  public var lastError: String?

  public var isReceiving: Bool { receivingTotal > receivingDone }

  static func name(of path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
}
