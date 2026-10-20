import ComponentKit
import SwiftUI
import VaultKit

/// Board 06: a synced folder at work. Conflicts first (your edit is kept until you choose), then the edits kept
/// here on a read-only device, what's arriving and what arrived today. The inspector sets this device's mode and
/// how the folder sits on disk; each device chooses for itself.
struct SyncFolderView: View {
  let folder: FolderItem
  let activity: FolderSyncActivity
  @Environment(AppModel.self) private var app
  @State private var search = ""

  var body: some View {
    let sync = app.folders.sync
    let totals = app.folders.totals(folder.id)
    let edits = activity.changedHere.count
    ListAndInspector(name: "sync") {
      CardScroll {
        ForEach(activity.conflicts) { conflict in
          KitSection(conflict.name, meta: conflict.meta, systemImage: "exclamationmark.triangle", hue: .purple) {
            TextConflict(
              mine: ConflictSide("Mine", ref: conflict.mineRef, code: conflict.mine),
              theirs: ConflictSide("Remote", ref: conflict.theirsRef, code: conflict.theirs)
            )
            .padding([.horizontal, .bottom], 6)
          } accessory: {
            HStack(spacing: 6) {
              Button("Keep Mine") { withKitAnimation { sync.keepMine(conflict.name, in: folder.id) } }.buttonStyle(.kit)
              Button("Revert to Remote") { withKitAnimation { sync.revert(conflict.name, in: folder.id) } }.buttonStyle(.kitPrimary)
            }
            .controlSize(.small)
          }
        }
        if !activity.changedHere.isEmpty {
          KitSection(
            "Changed here", meta: folder.isReadOnly ? ["this \(KitDevice.name.contains("iPad") ? "iPad" : "Mac") only receives", "these edits aren’t sent"] : ["not sent yet"],
            systemImage: "pencil", hue: .orange
          ) {
            ForEach(activity.changedHere) { file in
              HStack(spacing: 10) {
                RowTile(systemImage: KitFileCell.Kind.of(file.name).systemImage)
                VStack(alignment: .leading, spacing: 1) {
                  Text(file.name)
                  Text(file.detail).kitFont(.caption)
                }
                Spacer()
                Button("Keep Mine") { withKitAnimation { sync.keepMine(file.name, in: folder.id) } }.buttonStyle(.kitPlain)
                Button("Revert") { withKitAnimation { sync.revert(file.name, in: folder.id) } }.buttonStyle(.kit)
              }
              .controlSize(.small)
              .padding(.horizontal, 8)
              .frame(minHeight: 46)
            }
          } accessory: {
            HStack(spacing: 6) {
              Count(edits, .attention)
              Button("Revert All") { withKitAnimation { sync.revertAll(in: folder.id) } }.buttonStyle(.kit).controlSize(.small)
            }
          }
        }
        if activity.isReceiving {
          KitSection(
            "Receiving", meta: ["\(activity.progressLine) files", activity.receivingBytes, "from \(activity.source)"],
            systemImage: "arrow.down", status: .working(progress: Double(activity.receivingDone) / Double(activity.receivingTotal))
          ) {
            ForEach(activity.receiving) { transfer in
              HStack(spacing: 10) {
                RowTile(systemImage: KitFileCell.Kind.of(transfer.name).systemImage)
                VStack(alignment: .leading, spacing: 1) {
                  Text(transfer.name)
                  Text(transfer.detail).kitFont(.caption)
                }
                Spacer()
                if let progress = transfer.progress {
                  HStack(spacing: 6) {
                    KitProgressBar(value: progress).frame(width: 50)
                    Text("\(Int(progress * 100))%").kitFont(.caption).foregroundStyle(Hue.accent.text).monospacedDigit()
                  }
                } else {
                  Text("Waiting").kitFont(.caption).foregroundStyle(.kitTertiary)
                }
              }
              .padding(.horizontal, 8)
              .frame(minHeight: 40)
            }
          }
        }
        if !activity.receivedToday.isEmpty {
          KitSection("Received today", meta: activity.receivedSummary, systemImage: "checkmark", hue: .green, status: .done) {
            ForEach(activity.receivedToday) { item in
              HStack(spacing: 10) {
                RowTile(systemImage: "folder")
                VStack(alignment: .leading, spacing: 1) {
                  Text(item.name)
                  Text(item.detail).kitFont(.caption)
                }
                Spacer()
                Text(item.time).kitFont(.caption).foregroundStyle(.kitTertiary)
              }
              .padding(.horizontal, 8)
              .frame(minHeight: 40)
            }
          }
        }
      }
      .kitStatusBar(systemImage: "arrow.triangle.2.circlepath", status: activity.isReceiving ? .working(progress: Double(activity.receivingDone) / Double(activity.receivingTotal)) : .done) {
        Text("Receiving \(activity.progressLine) · checked \(activity.source) \(activity.checked)")
        Text("\(totals.items) items · \(Bytes.text(totals.bytes))").foregroundStyle(.kitSecondary)
      }
    } inspector: {
      SyncInspector(folder: folder)
    }
    .kitToolbar(folder.name, title: {
      KitTitle(
        folder.name,
        meta: [activity.isReceiving ? "Receiving \(activity.progressLine)" : "Synced", edits > 0 ? "\(edits) edits kept here" : "",
               activity.conflicts.isEmpty ? "" : "\(activity.conflicts.count) conflict"],
        systemImage: "arrow.triangle.2.circlepath",
        status: activity.isReceiving ? .working(progress: Double(activity.receivingDone) / Double(activity.receivingTotal)) : .idle)
    }) {
      ToolGroup {
        Button("Sync Now", systemImage: "arrow.clockwise") { app.syncNow() }
        if let url = folder.localURL { Button(KitDesktop.fileManagerName, systemImage: "folder") { KitDesktop.reveal([url]) } }
      }
      ToolbarSearch(text: $search, prompt: "Search \(folder.name)")
    }
  }
}

/// This device's mode and storage for the folder, the other devices' choices, members and the remote.
private struct SyncInspector: View {
  let folder: FolderItem
  @Environment(AppModel.self) private var app

  var body: some View {
    let record = folder.record
    let device = app.vault.deviceID
    InspectorHeader(folder.name, meta: ["Synced folder", folder.isEncrypted ? "encrypted here" : "plain here"], systemImage: "folder", hue: .blue) {}
    KitSection(
      "On this \(KitDevice.name.contains("iPad") ? "iPad" : "Mac")",
      meta: [app.thisDevice?.deviceName ?? KitDevice.name, folder.localURL.map { ProjectsView.tilde($0.path) } ?? ""],
      systemImage: "desktopcomputer"
    ) {
      FormChoiceRow(
        title: "Mode", help: record.mode(for: device) == .readOnly ? "Edits here aren’t sent" : "Edits here are sent",
        selection: Binding(get: { record.mode(for: device) }, set: { app.folders.setMode($0, for: folder.id) }),
        options: [("Read-write", .readWrite), ("Read-only", .readOnly)])
      FormChoiceRow(
        title: "On disk", help: record.storage(for: device) == .plain ? "Plain: every app sees the files" : "Encrypted: only v57 apps",
        selection: Binding(get: { record.storage(for: device) }, set: { app.folders.setStorage($0, for: folder.id) }),
        options: [("Plain", .plain), ("Encrypted", .encrypted)])
    }
    let others = app.otherDevices
    if !others.isEmpty {
      KitSection("Your other devices", meta: "each chooses for itself", systemImage: "laptopcomputer", hue: .gray) {
        ForEach(others) { other in
          let storage = record.storages[other.id]
          InspectorRow(other.deviceName, value: storage == nil ? "Not synced" : "\(record.mode(for: other.id) == .readOnly ? "Read-only" : "Read-write") · \(storage == .encrypted ? "Encrypted" : other.platform == "iOS" ? "Plain in Files" : "Plain")", copyable: false)
        }
      }
    }
    MembersCard(folder: folder)
    RemoteCard(folder: folder)
  }
}

/// A form line with a segmented choice at its end (Mode: Read-write | Read-only).
private struct FormChoiceRow<Value: Hashable>: View {
  var title: String
  var help: String
  @Binding var selection: Value
  var options: [(String, Value)]

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(help).kitFont(.caption).lineLimit(2)
      }
      Spacer(minLength: 8)
      KitSegmented(selection: $selection, options: options).controlSize(.small)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  }
}
