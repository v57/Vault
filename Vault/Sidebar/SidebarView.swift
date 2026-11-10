import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

/// The sidebar: the window's account, Items (the record kinds the store holds), Folders (encrypted or synced),
/// Locations (this device and every remote) and Keys (devices, people, the recovery key), with search, iCloud's state
/// and New in the bottom bar.
struct SidebarView: View {
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var search = ""
  @State private var showsNew = false

  var body: some View {
    SelectingSidebar(searchText: $search, columnVisibility: idiom.isTouch ? $columnVisibility : nil) {
      // The window's account; nothing while Personal is the only one.
      VaultAccountPicker(meta: String(localized: "\(app.itemCount) items"))
      itemsSection
      DocumentsSection()
      FoldersSection()
      LocationsSection()
      keysSection
    } bottomBar: {
      if idiom.isTouch {
        // No Settings window on iPhone and iPad: Settings is pushed from the bar.
        Button("Settings", systemImage: "gearshape") { app.open(.settings) }
      }
      Button("New", systemImage: "plus") { showsNew = true }
        .kitMenu(isPresented: $showsNew) { NewMenu() }
    } status: {
      HStack(spacing: 6) {
        StatusDot(hue: app.vault.sync?.isRunning == true || app.isDemo ? .green : .gray)
        // iCloud off on this device: nothing syncs, so the status says where the vault is.
        Text(idiom.isTouch ? (app.keepsSecretsInICloud ? String(localized: "iCloud") : String(localized: "This \(ThisDevice.word)")) : app.cloudSummary)
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
      "Items", meta: [String(localized: "\(app.itemCount) items"), app.syncedLine], systemImage: "key.horizontal",
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
      "Keys", meta: [String(localized: "\(app.devices.count) devices"), String(localized: "\(app.sharing.people.count) people")],
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

/// The kit's sidebar on the app's selection. Its own view: `$app.selection` reads the selection as the binding is
/// made, so made in `SidebarView` it rebuilt every section and row on each click.
private struct SelectingSidebar<Content: View, BottomBar: View, Status: View>: View {
  @Binding var searchText: String
  let columnVisibility: Binding<NavigationSplitViewVisibility>?
  let content: Content
  let bottomBar: BottomBar
  let status: Status
  @Environment(AppModel.self) private var app

  init(
    searchText: Binding<String>, columnVisibility: Binding<NavigationSplitViewVisibility>?,
    @ViewBuilder content: () -> Content, @ViewBuilder bottomBar: () -> BottomBar, @ViewBuilder status: () -> Status
  ) {
    _searchText = searchText
    self.columnVisibility = columnVisibility
    self.content = content()
    self.bottomBar = bottomBar()
    self.status = status()
  }

  var body: some View {
    // A row tapped again opens its screen again: on iPhone, after Back, the row is still the selection.
    let selection = Binding<SidebarItem?>(
      get: { app.selection },
      set: { item in if let item { app.open(item) } else { app.selection = nil } })
    KitSidebar(
      selection: selection, searchText: $searchText, searchPrompt: "Search Vault",
      columnVisibility: columnVisibility
    ) {
      content
    } bottomBar: {
      bottomBar
    }
    .status { status }
  }
}

/// Documents: every one, the inbox (not filed yet) and the collections, with what's coming up in the header.
private struct DocumentsSection: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let vault = app.vault
    let inbox = vault.documents(in: DocumentScope.inbox).count
    let renew = vault.documentEvents.filter { $0.remindOn <= .now }.count
    KitSection(
      "Documents", meta: [String(localized: "\(vault.documents.count) documents")] + (renew > 0 ? [String(localized: "\(renew) to renew")] : []),
      systemImage: "doc.text.image", hue: .blue
    ) {
      SidebarRow(value: SidebarItem.documents(DocumentScope.all), "All Documents", systemImage: "doc.on.doc") {
        Count(vault.documents.count)
      }
      if inbox > 0 {
        SidebarRow(value: SidebarItem.documents(DocumentScope.inbox), "Inbox", systemImage: "tray") {
          Count(inbox, .attention)
        }
      }
      ForEach(vault.documentCollections) { collection in
        SidebarRow(
          value: SidebarItem.documents(collection.id), collection.name, systemImage: DocumentSymbol.image(collection.symbol),
          hue: Hue(colorName: collection.color)
        ) {
          Count(vault.documents.filter { $0.collection == collection.id }.count)
        }
      }
    } accessory: {
      Button("New Document", systemImage: "plus") { app.newDocument() }
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
        MetaLine(decrypted.count == 1 ? String(localized: "1 decrypted") : String(localized: "\(decrypted.count) decrypted"), String(localized: "\(session.minutesLeft) min left"))
      } else if let activity = folders.folders.compactMap({ app.folders.sync.activity(for: $0.id) }).first(where: { $0.isReceiving }) {
        MetaLine(activity.folderName, activity.progressLine)
      } else {
        MetaLine([String(localized: "\(folders.folders.count) folders")] + (decrypted.isEmpty ? [] : [String(localized: "\(decrypted.count) decrypted")]))
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
      "Locations", meta: [String(localized: "This \(ThisDevice.word)"), String(localized: "\(locations.count - 1) remotes")],
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
    Button("New Document…", systemImage: "doc.viewfinder") { app.newDocument() }
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
