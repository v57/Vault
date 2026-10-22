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
  @State private var showsSettings = false
  @Environment(\.kitIdiom) private var idiom

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
            if idiom == .phone {
              // Full width under the two copies (iPhone).
              HStack(spacing: KitMetrics.gutter) {
                Button { withKitAnimation { sync.keepMine(conflict.name, in: folder.id) } } label: {
                  Text("Keep Mine").frame(maxWidth: .infinity)
                }
                .buttonStyle(.kit)
                Button { withKitAnimation { sync.revert(conflict.name, in: folder.id) } } label: {
                  Text("Revert to Remote").frame(maxWidth: .infinity)
                }
                .buttonStyle(.kitPrimary)
              }
              .controlSize(.small)
              .padding([.horizontal, .bottom], 6)
            }
          } accessory: {
            if idiom != .phone {
              HStack(spacing: 6) {
                Button("Keep Mine") { withKitAnimation { sync.keepMine(conflict.name, in: folder.id) } }.buttonStyle(.kit)
                Button("Revert to Remote") { withKitAnimation { sync.revert(conflict.name, in: folder.id) } }.buttonStyle(.kitPrimary)
              }
              .controlSize(.small)
            }
          }
        }
        if !activity.changedHere.isEmpty {
          KitSection(
            "Changed here", meta: folder.isReadOnly ? ["this \(ThisDevice.word) only receives", "these edits aren’t sent"] : ["not sent yet"],
            systemImage: "pencil", hue: .orange
          ) {
            ForEach(activity.changedHere) { file in
              HStack(spacing: 10) {
                RowTile(systemImage: KitFileCell.Kind.of(file.name).systemImage)
                VStack(alignment: .leading, spacing: 1) {
                  Text(file.name).lineLimit(1)
                  Text(file.detail).kitFont(.caption).lineLimit(1)
                }
                Spacer()
                if idiom != .phone {
                  Button("Keep Mine") { withKitAnimation { sync.keepMine(file.name, in: folder.id) } }.buttonStyle(.kitPlain)
                }
                Button("Revert") { withKitAnimation { sync.revert(file.name, in: folder.id) } }.buttonStyle(.kit)
              }
              .controlSize(.small)
              .padding(.horizontal, 8)
              .frame(minHeight: 46)
            }
          } accessory: {
            HStack(spacing: 6) {
              Count(edits, .attention)
              if idiom != .phone {
                Button("Revert All") { withKitAnimation { sync.revertAll(in: folder.id) } }.buttonStyle(.kit).controlSize(.small)
              }
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
      .paneStatusBar(systemImage: "arrow.triangle.2.circlepath", status: activity.isReceiving ? .working(progress: Double(activity.receivingDone) / Double(activity.receivingTotal)) : .done) {
        Text("Receiving \(activity.progressLine) · checked \(activity.source) \(activity.checked)")
        Text("\(totals.items) items · \(Bytes.text(totals.bytes))").foregroundStyle(.kitSecondary)
      }
    } inspector: {
      SyncInspector(folder: folder)
    }
    .kitToolbar(folder.name, title: {
      KitTitle(
        folder.name,
        meta: [activity.isReceiving ? "Receiving \(activity.progressLine)" : "Synced", edits > 0 && idiom != .phone ? "\(edits) edits kept here" : "",
               activity.conflicts.isEmpty ? "" : "\(activity.conflicts.count) conflict"],
        systemImage: "arrow.triangle.2.circlepath",
        status: activity.isReceiving ? .working(progress: Double(activity.receivingDone) / Double(activity.receivingTotal)) : .idle)
    }) {
      if idiom == .phone {
        Button("Folder Settings", systemImage: "ellipsis") { showsSettings = true }.buttonStyle(.kitRound)
      } else {
        ToolGroup {
          Button("Sync Now", systemImage: "arrow.clockwise") { app.syncNow() }
          if let url = folder.localURL { Button(KitDesktop.fileManagerName, systemImage: "folder") { KitDesktop.reveal([url]) } }
        }
        ToolbarSearch(text: $search, prompt: "Search \(folder.name)")
      }
    }
    .phoneBottomBar(prompt: "Search \(folder.name)", search: $search) {
      Button("Sync Now", systemImage: "arrow.clockwise") { app.syncNow() }
    }
    .navigationDestination(isPresented: $showsSettings) {
      PushedDetail(title: folder.name, meta: ["Synced folder", folder.isEncrypted ? "encrypted here" : "plain here"], systemImage: "folder", hue: .blue) {
        SyncInspector(folder: folder)
      } trailing: {
        EmptyView()
      } actions: {
        if let url = folder.localURL { Button("Open in Files", systemImage: "folder") { KitDesktop.reveal([url]) } }
      }
    }
  }
}

/// This device's mode and storage for the folder, the other devices' choices, members and the remote.
private struct SyncInspector: View {
  let folder: FolderItem
  @Environment(AppModel.self) private var app
  @Environment(\.pushedDetail) private var pushed

  var body: some View {
    let record = folder.record
    let device = app.vault.deviceID
    if !pushed {
      InspectorHeader(folder.name, meta: ["Synced folder", folder.isEncrypted ? "encrypted here" : "plain here"], systemImage: "folder", hue: .blue) {}
    }
    KitSection(
      "On this \(ThisDevice.word)",
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
    RecordsCard(folder: folder)
    RemoteCard(folder: folder)
  }
}

/// How the vault's records travel (iCloud, each Hub that syncs them) apart from this folder's files, which go through
/// the folder's remote.
private struct RecordsCard: View {
  let folder: FolderItem
  @Environment(AppModel.self) private var app

  var body: some View {
    let iCloud = app.isDemo || app.vault.sync?.isRunning == true
    let hubs = app.hubs.hubs.filter(\.syncsRecords)
    let sources = (iCloud ? ["iCloud"] : []) + hubs.map(\.name)
    KitSection(
      "Records",
      meta: [sources.isEmpty ? "only on this \(ThisDevice.word)" : ListFormatter.localizedString(byJoining: sources),
             iCloud && !hubs.isEmpty ? "this \(ThisDevice.word) bridges them" : ""],
      systemImage: "arrow.triangle.2.circlepath", hue: .blue
    ) {
      InspectorRow("iCloud", value: iCloud ? app.syncedLine.prefix(1).uppercased() + app.syncedLine.dropFirst() : "Off", copyable: false)
      ForEach(hubs) { hub in
        InspectorRow(hub.name, value: hub.recordSyncLine.isEmpty ? "Waiting for the connection" : hub.recordSyncLine, copyable: false)
      }
      InspectorRow(
        "This folder’s files",
        value: folder.record.remoteID.flatMap(app.vault.remote(id:)).map { "through \($0.name)" } ?? "only on your devices", copyable: false)
    }
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
