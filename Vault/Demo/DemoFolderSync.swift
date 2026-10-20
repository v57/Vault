import Foundation
import Observation
import VaultKit

/// Sample sync activity for the demo folders, until folder sync over plain storage exists: Photos 2026 receiving
/// from studio-mac on a read-only Mac with two edits kept here and one text conflict; Taxes 2026 sending one file.
@MainActor
@Observable
final class DemoFolderSync: FolderSyncEngine {
  private let vault: Vault
  private var kept: Set<String> = []
  private var reverted: Set<String> = []

  init(vault: Vault) {
    self.vault = vault
  }

  func activity(for folderID: String) -> FolderSyncActivity? {
    guard let folder = vault.folders.first(where: { $0.id == folderID }) else { return nil }
    switch folder.name {
    case "Photos 2026":
      var activity = FolderSyncActivity(folderName: folder.name)
      activity.receiving = [
        .init(name: "IMG_2290.heic", detail: "Porto · Jonas", progress: 0.7),
        .init(name: "IMG_2291.heic", detail: "Porto · Jonas", progress: 0.2),
        .init(name: "IMG_2292.heic", detail: "Porto · Jonas", progress: nil),
        .init(name: "IMG_2293.mov", detail: "Porto · Jonas · 84 MB", progress: nil),
      ]
      activity.receivingDone = 18
      activity.receivingTotal = 40
      activity.receivingBytes = "212 of 480 MB"
      activity.source = "studio-mac"
      activity.changedHere = [
        .init(name: "IMG_2214.heic", detail: "Lisbon · edited in Photos at 10:12 AM"),
        .init(name: "Album.json", detail: "Lisbon · edited at 9:40 AM"),
      ].filter { !kept.contains($0.name) && !reverted.contains($0.name) }
      if !kept.contains("Selects.txt"), !reverted.contains("Selects.txt") {
        activity.conflicts = [
          .init(
            name: "Selects.txt", meta: ["changed here and on MacBook Air", "your edit is kept until you choose"],
            mine: "IMG_2201 cover\nIMG_2214 tram, cropped\nIMG_2230 night", mineRef: "\(DemoVault.thisDevice == "iphone" ? "This iPhone" : "Studio Mac") · 10:12 AM",
            theirs: "IMG_2201 cover\nIMG_2214 tram\nIMG_2251 river", theirsRef: "Jonas · MacBook Air · 10:40 AM")
        ]
      }
      activity.receivedToday = [
        .init(name: "Sintra", detail: "12 files · Jonas · MacBook Air", time: "9:58 AM"),
        .init(name: "Lisbon", detail: "10 files · you · MacBook Air", time: "8:31 AM"),
      ]
      activity.receivedSummary = "22 files · from Jonas and your MacBook Air"
      activity.remoteFacts = [("Chunks", "6,412 · 3.1 GB"), ("Change logs", "3 devices · 1 person"), ("Snapshot", "Oct 19"), ("Checks", "on open, every 5 min while open")]
      activity.checked = "40 s ago"
      return activity
    case "Taxes 2026":
      var activity = FolderSyncActivity(folderName: folder.name)
      activity.sending = ["Estimated payments.numbers": 0.4]
      activity.remoteFacts = [("Here", "Read-write"), ("Last change sent", "3 min ago"), ("The remote holds", "Ciphertext only")]
      activity.checked = "3 min ago"
      return activity
    case "atlas-design":
      var activity = FolderSyncActivity(folderName: folder.name)
      activity.remoteFacts = [("Checked", "1 min ago")]
      activity.checked = "1 min ago"
      return activity
    default:
      return nil
    }
  }

  func keepMine(_ path: String, in folderID: String) { kept.insert(path) }
  func revert(_ path: String, in folderID: String) { reverted.insert(path) }
  func revertAll(in folderID: String) {
    for path in ["IMG_2214.heic", "Album.json"] { reverted.insert(path) }
  }
}
