import ComponentKit
import SwiftUI
import VaultFiles
import VaultKit

/// A folder: the sync view while it has sync work to show (board 06), otherwise its files (board 03, and board 05
/// while decrypted for other apps).
struct FolderScreen: View {
  let folderID: String
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if let folder = app.folders.folder(folderID) {
      if folder.record.isShared && folder.record.remoteID == nil || folder.record.remoteID != nil && folder.localURL == nil {
        FolderSetupView(folder: folder)
      } else if let activity = app.folders.sync.activity(for: folderID),
        !activity.conflicts.isEmpty || !activity.changedHere.isEmpty || activity.isReceiving
      {
        SyncFolderView(folder: folder, activity: activity)
      } else if idiom == .phone {
        PhoneFolderView(folder: folder)
      } else {
        FolderBrowser(folder: folder)
      }
    } else {
      EmptyState(systemImage: "folder", title: "No Folder", message: "This folder isn’t in the vault any more.")
        .kitPane(.content)
    }
  }
}

// MARK: - Files

/// The folder's files: a path bar, the table (Name, Size, Modified and how each file stands with the remote or the
/// plain copy), the inspector with encryption, remote and members.
private struct FolderBrowser: View {
  let folder: FolderItem
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var path = ""
  @State private var history: [String] = []
  @State private var forward: [String] = []
  @State private var selection: Set<String> = []
  @State private var search = ""

  private var session: FolderSession? { app.folders.session(for: folder.id) }

  var body: some View {
    let session = session
    let totals = app.folders.totals(folder.id)
    let entries = app.folders.entries(folder.id, path: path).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    ListAndInspector(name: "folder") {
      VStack(spacing: 0) {
        pathBar
        if let session {
          Banner(
            "\(idiom.isTouch ? String(localized: "In Files: On My \(ThisDevice.word) › Vault › \(folder.name)") : String(localized: "Decrypted for other apps until \(session.lockDate.formatted(date: .omitted, time: .shortened))"))",
            message: idiom.isTouch
              ? "Other apps open it in place until \(session.lockDate.formatted(date: .omitted, time: .shortened)). Locking seals your edits and moves it out of Files."
              : "\(KitDesktop.fileManagerName), Terminal and other apps see a plain copy. Saved edits are sealed back into the encrypted folder.",
            systemImage: "lock.open", hue: .orange)
          .padding(.horizontal, KitMetrics.gutter)
          .padding(.bottom, KitMetrics.gutter)
        }
        KitGrid(entries, columns: columns(session: session), selection: $selection, primaryAction: open)
          .padding(.horizontal, KitMetrics.gutter)
      }
      .paneStatusBar(systemImage: session == nil ? "arrow.triangle.2.circlepath" : "lock.open", hue: session == nil ? .green : .teal, status: statusBarStatus) {
        Text(statusLine)
        Text("\(totals.items) items · \(Bytes.text(totals.bytes))").foregroundStyle(.kitSecondary)
      }
    } inspector: {
      FolderInspector(folder: folder, totals: totals)
    }
    .kitToolbar(folder.name, title: {
      KitTitle(
        folder.name, meta: session.map { _ in [String(localized: "Decrypted"), String(localized: "locks in \(session?.minutesLeft ?? 0) min")] } ?? [folder.isEncrypted ? String(localized: "Encrypted") : String(localized: "Plain here"), folder.isEncrypted ? String(localized: "only v57 apps can read it") : syncWord],
        systemImage: session == nil ? "lock.rectangle.stack" : "lock.open", hue: session == nil ? .teal : .orange,
        status: session.map { .working(progress: $0.fractionLeft) } ?? .idle)
    }) {
      if let session {
        ToolbarSlot(priority: 1) {
          ToolGroup {
            Button(KitDesktop.fileManagerName, systemImage: "folder") { KitDesktop.reveal([session.copyURL]) }
            #if os(macOS)
              Button("Terminal", systemImage: "terminal") { KitDesktop.openTerminal(at: session.copyURL) }
            #endif
          }
        } menu: {
          KitOpenWithRow([.fileManager(revealing: [session.copyURL])])
        }
        ToolGroup { Button("Lock Now", systemImage: "lock") { app.folders.lock(folder.id) } }
      } else {
        ToolbarSlot(priority: 1) {
          ToolGroup(iconOnly: true) {
            if let url = folder.localURL { Button("Show Encrypted Folder", systemImage: "folder") { KitDesktop.reveal([url]) } }
            Button("Export Decrypted…", systemImage: "square.and.arrow.down") { exportDecrypted() }
          }
        } menu: {
          Button("Export Decrypted…", systemImage: "square.and.arrow.down") { exportDecrypted() }
            .kitMenuPreview("Saves a plain copy of \(folder.name) where you pick, outside the vault. Other apps can read it there.")
        }
        if folder.isEncrypted {
          ToolGroup { Button("Decrypt…", systemImage: "lock.open") { app.sheet = .decrypt(folder.id) } }
        }
      }
      ToolbarSearch(text: $search, prompt: "Search \(folder.name)")
    }
  }

  private var pathBar: some View {
    HStack(spacing: 4) {
      Button("Back", systemImage: "chevron.left") { goBack() }
        .buttonStyle(.kitIcon).disabled(history.isEmpty)
      Button("Forward", systemImage: "chevron.right") { goForward() }
        .buttonStyle(.kitIcon).disabled(forward.isEmpty)
      let parts = path.split(separator: "/").map(String.init)
      KitPathBar(components: [KitPathItem("Folders", icon: { FolderGlyph(isEncrypted: true) }, action: { go("") })]
        + [KitPathItem(folder.name, action: { go("") })]
        + parts.enumerated().map { index, part in
          KitPathItem(part, action: { go(parts.prefix(index + 1).joined(separator: "/")) })
        })
      Spacer()
    }
    .padding(.horizontal, KitMetrics.gutter + 2)
    .frame(height: 36)
  }

  private func go(_ target: String) {
    guard target != path else { return }
    history.append(path)
    forward = []
    path = target
    selection = []
  }

  private func goBack() {
    guard let last = history.popLast() else { return }
    forward.append(path)
    path = last
  }

  private func goForward() {
    guard let next = forward.popLast() else { return }
    history.append(path)
    path = next
  }

  private func open(_ ids: Set<String>) {
    guard let id = ids.first, let entry = app.folders.entries(folder.id, path: path).first(where: { $0.id == id }) else { return }
    if entry.isDirectory {
      go(entry.path)
    } else if let session {
      KitDesktop.open(session.copyURL.appendingPathComponent(entry.path))
    }
  }

  private func exportDecrypted() { app.exportDecrypted(folder, isTouch: idiom.isTouch) }

  private var statusBarStatus: WorkStatus {
    if let session, session.activity.phase == .sealing { return .working(progress: session.activity.fraction) }
    let sync = app.folders.sync.activity(for: folder.id)
    if let sending = sync?.sending.values.first { return .working(progress: sending) }
    if let error = sync?.error { return .failed(error) }
    if sync?.isWorking == true { return .working }
    if sync?.waiting != nil { return .idle }
    return session == nil ? .done : .idle
  }

  /// The header's second word for a plain folder: synced, waiting for its owner, or kept only here.
  private var syncWord: String {
    guard folder.record.remoteID != nil else { return String(localized: "only here") }
    let sync = app.folders.sync.activity(for: folder.id)
    if sync?.waiting != nil { return String(localized: "waiting") }
    if sync?.error != nil { return String(localized: "not synced") }
    return String(localized: "synced")
  }

  private var statusLine: String {
    if let session {
      if session.activity.phase == .sealing, let file = session.activity.file {
        return String(localized: "Sealing \(file) · \(Bytes.text(session.activity.fileBytes)) of \(Bytes.text(session.activity.fileSize))")
      }
      return session.sealedEdits == 0 ? String(localized: "Watching for edits to seal back") : String(localized: "\(session.sealedEdits) edits sealed back")
    }
    if let remote = folder.record.remoteID.flatMap(app.vault.remote(id:)) {
      let sync = app.folders.sync.activity(for: folder.id)
      if let error = sync?.error { return error }
      if sync?.isWorking == true { return String(localized: "Checking \(remote.name)…") }
      if let waiting = sync?.waiting { return String(localized: "\(waiting) · checked \(sync?.checked ?? "")") }
      return String(localized: "Synced through \(remote.name) · checked \(sync?.checked ?? "")")
    }
    return String(localized: "On this device only")
  }

  private func columns(session: FolderSession?) -> [KitGridColumn<FileEntry>] {
    let sync = app.folders.sync.activity(for: folder.id)
    let folders = app.folders
    let id = folder.id
    return [
      KitGridColumn("Name", width: idiom.isTouch ? 260 : 300) { KitFileCell($0.name, isFolder: $0.isDirectory) },
      KitGridColumn("Size", width: 90, alignment: .trailing) { entry in
        entry.isDirectory ? String(localized: "\(folders.itemCount(id, path: entry.path)) items") : Bytes.text(entry.size)
      },
      KitGridColumn("Modified", width: 150) { entry in entry.modified.map(RelativeTime.dayTime) ?? "—" },
      KitGridColumn(session == nil ? "Sync" : "Sealed", width: 110) { entry in
        if let session, session.activity.phase == .sealing, session.activity.file == entry.path {
          RowProgress(value: session.activity.fraction, title: "Sealing")
        } else if let progress = sync?.sending[entry.name] {
          RowProgress(value: progress, title: "Sending")
        } else {
          Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.kitTertiary)
            .accessibilityLabel(session == nil ? "Synced" : "Sealed")
        }
      },
    ]
  }
}

/// A short progress bar with its word in the accent ("Sending", "Sealing").
struct RowProgress: View {
  var value: Double
  var title: LocalizedStringKey

  var body: some View {
    HStack(spacing: 6) {
      KitProgressBar(value: value).frame(width: 36)
      Text(title).kitFont(.caption).foregroundStyle(Hue.accent.text)
    }
  }
}

/// The folder's inspector: what it is, how it's kept on each device, the remote, the members.
private struct FolderInspector: View {
  let folder: FolderItem
  let totals: (items: Int, bytes: Int64)
  @Environment(AppModel.self) private var app

  var body: some View {
    let vault = app.vault
    let session = app.folders.session(for: folder.id)
    InspectorHeader(
      folder.name,
      meta: [folder.isEncrypted ? String(localized: "Encrypted folder") : String(localized: "Synced folder"), folder.sharedWith == nil ? "" : String(localized: "shared"), String(localized: "\(totals.items) items"), Bytes.text(totals.bytes)],
      systemImage: "lock.rectangle.stack", hue: .teal) {}
    if let session {
      KitSection(Text("Decrypted until \(session.lockDate.formatted(date: .omitted, time: .shortened))")) {
        InspectorRow("Plain copy", copyText: session.copyURL.path) {
          Text("…/Decrypted/\(session.copyURL.lastPathComponent)").kitFont(.mono).lineLimit(1).truncationMode(.head)
        }
        InspectorRow("Spotlight", value: String(localized: "Excluded"), copyable: false)
        #if os(macOS)
          InspectorRow("Time Machine", value: String(localized: "Excluded"), copyable: false)
        #endif
        InspectorRow("Sealed back", value: session.activity.phase == .sealing ? String(localized: "\(session.sealedEdits) edits · 1 sealing") : String(localized: "\(session.sealedEdits) edits"), copyable: false)
        HStack(spacing: 6) {
          Button("+30 min", systemImage: "timer") { app.folders.extend(folder.id) }.buttonStyle(.kit)
          Button("Show in \(KitDesktop.fileManagerName)") { KitDesktop.reveal([session.copyURL]) }.buttonStyle(.kit)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      } icon: {
        LiveIcon(systemImage: "lock.open", hue: .orange, status: .working(progress: session.fractionLeft), size: 24)
      } meta: {
        MetaLine(String(localized: "\(session.minutesLeft) min left"), String(localized: "opened by you at \(session.session.started.formatted(date: .omitted, time: .shortened))"))
      } accessory: {
        EmptyView()
      }
    } else if folder.isEncrypted {
      KitSection("Encrypted", meta: [String(localized: "names too"), String(localized: "64 KB sealed chunks")], systemImage: "lock", hue: .teal) {
        ForEach(app.devices) { device in
          InspectorRow(device.id == vault.deviceID ? "This \(ThisDevice.word)" : "\(device.deviceName)") {
            switch folder.record.storage(for: device.id) {
            case .encrypted where folder.record.storages[device.id] != nil || device.id == vault.deviceID:
              Chip("Encrypted", hue: .teal).controlSize(.small)
            case .plain where folder.record.storages[device.id] != nil:
              Text("Plain")
            default:
              Text("Not synced").foregroundStyle(.kitSecondary)
            }
          }
        }
      }
    }
    RemoteCard(folder: folder)
    MembersCard(folder: folder)
    if session == nil {
      ActionBar {
        if folder.isEncrypted { Button("Decrypt…") { app.sheet = .decrypt(folder.id) } }
        if !folder.record.isShared { Button("Share…") { app.sheet = .share(folder.id) } }
      }
    }
  }
}

/// The folder's remote: where it syncs and how each device keeps it.
struct RemoteCard: View {
  let folder: FolderItem
  @Environment(AppModel.self) private var app

  var body: some View {
    if let remote = folder.record.remoteID.flatMap(app.vault.remote(id:)) {
      let kind = LocationKind(remote.kind)
      let facts = app.folders.sync.activity(for: folder.id)?.remoteFacts ?? []
      KitSection(remote.name, meta: [remote.kind == .s3 && remote.endpoint.contains("r2.") ? "Cloudflare R2" : kind.title, remote.kind == .s3 ? remote.bucket : (folder.record.remotePath ?? remote.path)], systemImage: kind.systemImage, hue: .indigo) {
        if facts.isEmpty || facts.first?.0 == "Checked" {
          InspectorRow("Here", value: mode(folder.record, app.vault.deviceID), copyable: false)
          ForEach(app.otherDevices.filter { folder.record.storages[$0.id] != nil }) { device in
            InspectorRow(device.deviceName, value: mode(folder.record, device.id), copyable: false)
          }
        }
        ForEach(facts, id: \.0) { fact in InspectorRow(fact.0, value: fact.1, copyable: false) }
      } accessory: {
        Button("Sync Now") { Task { await app.folders.sync.sync(folder.id) } }.buttonStyle(.kit).controlSize(.small)
      }
    } else if !folder.record.isShared {
      KitSection("Remote", meta: String(localized: "only on this \(ThisDevice.word)"), systemImage: "externaldrive.badge.icloud", hue: .indigo) {
        Text("Sync it through a remote for your other devices and the people you share it with.")
          .kitFont(.caption).padding(.horizontal, 8).padding(.vertical, 4)
      } accessory: {
        Button("Sync…") { app.sheet = .syncFolder(folder.id) }.buttonStyle(.kit).controlSize(.small)
      }
    }
  }

  private func mode(_ record: VaultFolder, _ device: String) -> String {
    let mode = record.mode(for: device) == .readOnly ? String(localized: "Read-only") : String(localized: "Read-write")
    return "\(mode) · \(record.storage(for: device) == .encrypted ? String(localized: "Encrypted") : String(localized: "Plain"))"
  }
}

/// Who the folder is shared with: you (the owner) and every member with their role.
struct MembersCard: View {
  let folder: FolderItem
  @Environment(AppModel.self) private var app

  var body: some View {
    if folder.record.isShared { sharedWithYou } else { yours }
  }

  /// A folder someone shared with the user: its owner signs the member list, so only they and the user show.
  private var sharedWithYou: some View {
    let owner = folder.record.ownerSigningKey.flatMap { key in app.sharing.people.first { $0.record.signingKey == key } }
    let mode = folder.record.mode(for: app.vault.deviceID) == .readOnly ? String(localized: "Only receives here") : String(localized: "Sends edits here")
    return KitSection(
      "Members", meta: String(localized: "shared by \(owner?.name ?? String(localized: "someone"))"), systemImage: "person.2", hue: .purple
    ) {
      PersonRow(
        name: owner?.name ?? String(localized: "Someone"),
        detail: [String(localized: "Owner"), owner?.record.verified.map { String(localized: "verified \(RelativeTime.day($0))") } ?? String(localized: "not verified")].joined(separator: " · "),
        verified: owner?.status == .verified)
      PersonRow(name: app.ownerName, detail: mode)
    }
  }

  private var yours: some View {
    let members = app.sharing.people.filter { $0.record.roles[folder.id] != nil }
    return KitSection(
      "Members", meta: members.isEmpty ? [String(localized: "only you")] : [String(localized: "\(members.count + 1) people"), String(localized: "signed by you")],
      systemImage: "person.2", hue: .purple
    ) {
      PersonRow(name: app.ownerName, detail: members.isEmpty ? String(localized: "Owner · \(app.devices.count) devices") : String(localized: "Owner"))
      ForEach(members) { person in
        PersonRow(
          name: person.name,
          detail: [person.record.roles[folder.id] == .readOnly ? String(localized: "Read-only") : String(localized: "Read-write"), person.record.verified.map { String(localized: "verified \(RelativeTime.day($0))") } ?? String(localized: "not verified")].joined(separator: " · "),
          verified: person.status == .verified)
      }
    } accessory: {
      Button("Share…") { app.sheet = .share(folder.id) }.buttonStyle(.kit).controlSize(.small)
    }
  }
}

/// A person in a card: their initials, name and a line, a green shield once verified.
struct PersonRow: View {
  var name: String
  var detail: String
  var verified = false

  var body: some View {
    HStack(spacing: 10) {
      Avatar(name: name, letters: LetterTile.initials(name), size: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(name).lineLimit(1)
        Text(detail).kitFont(.caption).lineLimit(1)
      }
      Spacer(minLength: 6)
      if verified {
        Image(systemName: "checkmark.shield").foregroundStyle(Hue.green.fill).accessibilityLabel("Verified")
      }
    }
    .padding(.horizontal, 8)
    .frame(minHeight: 40)
  }
}

extension LetterTile {
  /// "AT" for "Aiko Tanaka".
  static func initials(_ name: String) -> String {
    name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
  }
}

/// Byte counts as the design writes them: "412 KB", "2.4 MB", "1.3 GB".
enum Bytes {
  static func text(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}

extension RelativeTime {
  /// "Today, 9:14 AM", "Yesterday", "Oct 18".
  static func dayTime(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
      ? String(localized: "Today, \(date.formatted(date: .omitted, time: .shortened))") : day(date)
  }
}

extension AppModel {
  /// Export Decrypted…: a plain copy of `folder` where the user picks, outside the vault. On iPhone and iPad (no save
  /// panel) the copy is made in the temporary folder for the system's exporter (Files), then removed.
  func exportDecrypted(_ folder: FolderItem, isTouch: Bool) {
    Task {
      do {
        if isTouch {
          let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
          defer { try? FileManager.default.removeItem(at: temporary) }
          try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
          let plain = temporary.appendingPathComponent(folder.name, isDirectory: true)
          try folders.exportDecrypted(folder.id, to: plain)
          _ = try await KitDesktop.saveCopy(of: plain, title: String(localized: "Export Decrypted"), prompt: String(localized: "Export"))
        } else {
          guard let url = await KitDesktop.chooseSaveLocation(title: String(localized: "Export Decrypted"), prompt: String(localized: "Export"), name: folder.name) else { return }
          try folders.exportDecrypted(folder.id, to: url)
        }
      } catch {
        folders.lastError = error.localizedDescription
      }
    }
  }
}
