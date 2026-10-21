import ComponentKit
import SwiftUI
import VaultKit

/// The sidebar: Items (the record kinds the store holds), Folders (encrypted or synced), Locations (this device and
/// every remote) and Keys (devices, people, the recovery key), with search, iCloud's state and New in the bottom bar.
struct SidebarView: View {
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var search = ""
  @State private var showsNew = false

  var body: some View {
    @Bindable var app = app
    KitSidebar(
      selection: $app.selection, searchText: $search, searchPrompt: "Search Vault",
      columnVisibility: idiom.isTouch ? $columnVisibility : nil
    ) {
      itemsSection
      FoldersSection()
      LocationsSection()
      keysSection
    } bottomBar: {
      if idiom.isTouch {
        // No Settings window on iPhone and iPad: Settings is pushed from the bar.
        Button("Settings", systemImage: "gearshape") { app.selection = .settings }
      }
      Button("New", systemImage: "plus") { showsNew = true }
        .kitMenu(isPresented: $showsNew) { NewMenu() }
    }
    .status {
      HStack(spacing: 6) {
        StatusDot(hue: app.vault.sync?.isRunning == true || app.isDemo ? .green : .gray)
        Text(idiom.isTouch ? "iCloud" : app.cloudSummary)
      }
    }
    .navigationTitle("Vault")
    // About twenty rows: build them all. On iPhone the kit's lazy stack leaves the later cards' rows unbuilt in the
    // compact sidebar (reported to ComponentKit).
    .kitLazyLoading(false)
  }

  private var itemsSection: some View {
    let vault = app.vault
    return KitSection(
      "Items", meta: ["\(app.itemCount) items", app.syncedLine], systemImage: "key.horizontal",
      status: app.vault.sync?.isRunning == true ? .idle : .idle
    ) {
      SidebarRow(value: SidebarItem.logins, "Logins", systemImage: "key") { Count(vault.logins.count) }
      SidebarRow(value: SidebarItem.cards, "Cards", systemImage: "creditcard") { Count(vault.cards.count) }
      SidebarRow(value: SidebarItem.notes, "Notes", systemImage: "doc.text") { Count(app.notes.count) }
      SidebarRow(value: SidebarItem.hosts, "SSH Hosts", systemImage: "server.rack") { Count(vault.hosts.count) }
      SidebarRow(value: SidebarItem.databases, "Databases", systemImage: "cylinder") { Count(vault.databases.count) }
      SidebarRow(value: SidebarItem.projects, "Projects", systemImage: "folder") { Count(vault.projects.count) }
    } accessory: {
      Button("New Item", systemImage: "plus") { app.sheet = .newItem(.login) }
    }
  }

  private var keysSection: some View {
    KitSection(
      "Keys", meta: ["\(app.devices.count) devices", "\(app.sharing.people.count) people"],
      systemImage: "checkmark.shield", hue: .green
    ) {
      SidebarRow(value: SidebarItem.devices, "Devices & People", systemImage: "person.2") {
        Count(app.devices.count + app.sharing.people.count)
      }
      SidebarRow(value: SidebarItem.hub, "Hub", systemImage: "point.3.connected.trianglepath.dotted") {
        let hubs = app.hubs.hubs
        if hubs.contains(where: { !$0.pending.isEmpty }) {
          Count(hubs.reduce(0) { $0 + $1.pending.count }, .attention)
        } else {
          Text(hubs.isEmpty ? "Off" : "\(hubs.flatMap(\.members).count)").kitFont(.caption)
        }
      }
      SidebarRow(value: SidebarItem.recoveryKey, "Recovery Key", systemImage: "key") {
        Text(app.recovery.isOn ? "On" : "Off").kitFont(.caption)
      }
    }
  }
}

/// Encrypted and synced folders. A decrypted folder turns the header's tile into its countdown.
private struct FoldersSection: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let folders = app.folders
    let decrypted = folders.folders.filter { folders.session(for: $0.id) != nil }
    KitSection(Text("Folders")) {
      ForEach(folders.folders) { folder in
        SidebarRow(value: SidebarItem.folder(folder.id), folder.name) {
          RowTile(hue: nil, status: folders.rowStatus(folder.id)) { FolderGlyph(isEncrypted: folder.isEncrypted) }
        } trailing: {
          FolderTrailing(folder: folder)
        }
      }
      if folders.folders.isEmpty {
        Button("New Encrypted Folder…", systemImage: "plus") { app.sheet = .newItem(.folder) }
          .buttonStyle(.kitPlain)
          .padding(.vertical, 4)
      }
    } icon: {
      LiveIcon(hue: decrypted.isEmpty ? .teal : .orange, status: folders.headerStatus, size: 24) {
        FolderGlyph(isEncrypted: true)
      }
    } meta: {
      if let first = decrypted.first, let session = folders.session(for: first.id) {
        MetaLine(decrypted.count == 1 ? "1 decrypted" : "\(decrypted.count) decrypted", "\(session.minutesLeft) min left")
      } else if let activity = folders.folders.compactMap({ app.folders.sync.activity(for: $0.id) }).first(where: { $0.isReceiving }) {
        MetaLine(activity.folderName, activity.progressLine)
      } else {
        MetaLine(["\(folders.folders.count) folders"] + (decrypted.isEmpty ? [] : ["\(decrypted.count) decrypted"]))
      }
    } accessory: {
      Button("New Folder", systemImage: "plus") { app.sheet = .newItem(.folder) }
    }
  }
}

/// A folder row's trailing state: the minutes left while decrypted, a lock while encrypted, edits kept here, or
/// the read-only mode.
private struct FolderTrailing: View {
  let folder: FolderItem
  @Environment(AppModel.self) private var app

  var body: some View {
    if let session = app.folders.session(for: folder.id) {
      Chip("\(session.minutesLeft) min", hue: .orange).controlSize(.small)
    } else if let activity = app.folders.sync.activity(for: folder.id), activity.changedHere.count + activity.conflicts.count > 0 {
      Count(activity.changedHere.count + activity.conflicts.count, .attention)
    } else if folder.isReadOnly {
      Text("Read-only").kitFont(.caption)
    } else if folder.isEncrypted {
      Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.kitTertiary).accessibilityLabel("Encrypted")
    }
  }
}

/// This device and the remotes the user added. A remote that can't be reached shows Offline.
private struct LocationsSection: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let locations = app.remotes.locations
    KitSection(
      "Locations", meta: ["This \(ThisDevice.word)", "\(locations.count - 1) remotes"],
      systemImage: "globe", hue: .indigo
    ) {
      ForEach(locations) { location in
        SidebarRow(value: SidebarItem.location(location.id), location.name, systemImage: location.kind.systemImage) {
          if location.isOffline {
            HStack(spacing: 4) {
              StatusDot(hue: .gray)
              Text("Offline")
            }
            .kitFont(.caption)
          } else if location.kind != .thisDevice {
            Text(location.kind.title).kitFont(.caption)
          }
        }
      }
    } accessory: {
      Button("Add Remote", systemImage: "plus") { app.sheet = .addRemote }
    }
  }
}

/// The New menu of the sidebar's bar.
struct NewMenu: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    Button("New Login…", systemImage: "key.horizontal") { app.sheet = .newItem(.login) }
    Button("New Card…", systemImage: "creditcard") { app.sheet = .newItem(.card) }
    Button("New SSH Host…", systemImage: "server.rack") { app.sheet = .newItem(.host) }
    Divider()
    Button("New Encrypted Folder…", systemImage: "lock.rectangle.stack") { app.sheet = .newItem(.folder) }
    Button("Add Remote…", systemImage: "externaldrive.badge.icloud") { app.sheet = .addRemote }
  }
}

/// A folder with a small lock in it (encrypted), or a plain folder (synced, plain on this device).
struct FolderGlyph: View {
  var isEncrypted: Bool
  @Environment(\.kitGlyphSize) private var size

  var body: some View {
    let side = size ?? 16
    ZStack {
      Image(systemName: "folder").font(.system(size: side * 0.92, weight: .semibold))
      if isEncrypted {
        Image(systemName: "lock.fill").font(.system(size: side * 0.36, weight: .bold)).offset(y: side * 0.08)
      }
    }
    .frame(width: side, height: side)
  }
}
