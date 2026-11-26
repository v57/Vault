import Foundation
import PlatformNotifications
import VaultKit
import VaultSync

/// Settings ▸ Sync ▸ Notify about conflicts: a notification for each conflict a folder's sync finds (a file changed here
/// and on another device) and each file edited in a read-only folder. Each one is notified once: what was notified is
/// remembered per folder across launches, and forgotten once it's resolved, so it notifies again if it comes back. The
/// system asks for permission at the first one, never at launch. Opening it opens the folder.
@MainActor
final class ConflictNotifier {
  static let shared = ConflictNotifier()
  /// The Settings switch (on unless turned off).
  static let settingKey = "notifyConflicts"
  /// `info` key of the folder a notification is about.
  static let folderKey = "folder"

  private let defaults = UserDefaults.standard

  /// Looks at a folder's sync status after a pass that reached the remote; statuses in between are skipped (the
  /// lists are rebuilt only at the end of a pass).
  func update(folderID: String, folderName: String, status: FolderSyncStatus) {
    guard status.phase == .idle, status.remote.lastCheck != nil else { return }
    let key = "notifiedConflicts.\(folderID)"
    let readOnly = status.mode == .readOnly
    let conflicts = Dictionary(status.conflicts.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
    let edits = readOnly
      ? Dictionary(status.changedHere.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first }) : [:]
    let current = Set(conflicts.keys.map { "conflict:" + $0 } + edits.keys.map { "readOnly:" + $0 })
    let notified = Set(defaults.stringArray(forKey: key) ?? [])
    guard current != notified else { return }
    defaults.set(current.sorted(), forKey: key)
    guard defaults.object(forKey: Self.settingKey) as? Bool ?? true else { return }
    let newConflicts = conflicts.filter { !notified.contains("conflict:" + $0.key) }.map(\.value).sorted()
    let newEdits = edits.filter { !notified.contains("readOnly:" + $0.key) }.map(\.value).sorted()
    guard !newConflicts.isEmpty || !newEdits.isEmpty else { return }
    var notifications: [UserNotification] = []
    if !newConflicts.isEmpty {
      notifications.append(
        UserNotification(
          id: "conflict.\(folderID)", title: String(localized: "Conflict in \(folderName)"),
          body: newConflicts.count == 1
            ? String(localized: "“\(newConflicts[0])” changed here and on another device. Your edit is kept until you choose.")
            : String(localized: "\(newConflicts.count) files changed here and on another device. Your edits are kept until you choose."),
          thread: folderID, info: [Self.folderKey: folderID]))
    }
    if !newEdits.isEmpty {
      notifications.append(
        UserNotification(
          id: "readOnly.\(folderID)", title: String(localized: "Edited in \(folderName), which is read-only"),
          body: newEdits.count == 1
            ? String(localized: "“\(newEdits[0])” changed here. It isn’t sent; revert it in the folder.")
            : String(localized: "\(newEdits.count) files changed here. They aren’t sent; revert them in the folder."),
          thread: folderID, info: [Self.folderKey: folderID]))
    }
    Task {
      guard UserNotifications.isSupported else { return }
      switch await UserNotifications.permission() {
      case .denied: return
      case .notAsked: guard await UserNotifications.requestPermission() else { return }
      case .allowed: break
      }
      for notification in notifications { try? await UserNotifications.post(notification) }
    }
  }
}
