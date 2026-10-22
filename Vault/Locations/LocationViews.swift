import ComponentKit
import SwiftUI
import VaultKit

/// Board 10: a remote is plain storage folders sync through. The sheet takes its kind and credentials (the secret
/// goes to iCloud Keychain), tests it only when asked, and says the remote only ever holds ciphertext.
struct AddRemoteSheet: View {
  @Environment(\.kitIdiom) private var idiom
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var draft = RemoteDraft()
  @State private var test: WorkStatus = .idle
  @State private var testLine = ""
  @State private var error: String?

  var body: some View {
    KitSheet(
      title: "Add Remote", meta: "Plain storage that Vault syncs folders through, for you or the people you share with.",
      systemImage: "archivebox", hue: .indigo, width: 720
    ) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Kind").kitFont(.headline).padding(.leading, 4)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: KitMetrics.gutter), count: idiom == .phone ? 2 : 5), spacing: KitMetrics.gutter) {
          kindCard(.s3, "S3", "R2, B2, MinIO", "archivebox")
          kindCard(.sftp, "SFTP", "SSH hosts", "server.rack")
          kindCard(.smb, "SMB", "File shares", "externaldrive.connected.to.line.below")
          kindCard(.icloud, "iCloud", "CloudKit", "icloud")
          if idiom != .phone { kindCard(.ftp, "FTP", "Later", "network").disabled(true) }
        }
      }
      VStack(spacing: 12) {
        FieldRow {
          LabeledField("Name") { TextField("backups", text: $draft.name).kitField() }
          switch draft.kind {
          case .s3: LabeledField("Bucket") { TextField("atlas-backups", text: $draft.bucket).kitField(mono: true) }
          case .sftp:
            LabeledField("Host") {
              KitSegmented(selection: Binding(get: { draft.hostID ?? "" }, set: { draft.hostID = $0 }), options: app.vault.hosts.prefix(4).map { ($0.displayName, $0.id) })
            }
          default: LabeledField("Path") { TextField("/vault", text: $draft.path).kitField(mono: true) }
          }
        }
        if draft.kind == .s3 || draft.kind == .smb {
          FieldRow {
            LabeledField(draft.kind == .s3 ? "Endpoint" : "Address") {
              TextField(draft.kind == .s3 ? "https://…r2.cloudflarestorage.com" : "smb://nas.local/vault", text: $draft.endpoint).kitField(mono: true)
            }

          }
          FieldRow {
            LabeledField(draft.kind == .s3 ? "Access key ID" : "User") { TextField("", text: $draft.accessKeyID).kitField(mono: true) }
            LabeledField(draft.kind == .s3 ? "Secret access key" : "Password") {
              SecureField("", text: $draft.secret).kitField(mono: true) {
                Label("Keychain", systemImage: "lock").kitFont(.caption).labelStyle(.titleAndIcon)
              }
            }
          }
        }
      }
      Banner(
        "The remote only ever holds ciphertext.",
        message: ThisDevice.isTouch
          ? "Reached only while Vault is open, or when \(ThisDevice.system) runs its background refresh."
          : "It sees chunk sizes and timing, nothing more. Vault reaches it only while a v57 app is open, and only for folders you sync through it.",
        systemImage: "shield", hue: .blue)
      if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
    } footer: {
      SheetStatus(testLine.isEmpty ? "Not tested yet" : testLine, systemImage: LocationKind(draft.kind).systemImage, hue: test.isFinished && test != .done ? .red : .green, status: test)
      Button("Test") { runTest() }.disabled(draft.name.isEmpty)
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Add") { add() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(draft.name.isEmpty)
    }
    .onAppear {
      if app.isDemo, draft.name.isEmpty {
        draft = RemoteDraft(kind: .s3, name: "backups", endpoint: "https://4f1c09e2b7.r2.cloudflarestorage.com", bucket: "atlas-backups", accessKeyID: "8d2e61b0c4f9a7e3", secret: "r2-secret-demo")
        testLine = idiom == .phone ? "Reached · 2.1 GB" : "Reached atlas-backups · 2.1 GB used"
        test = .done
      }
    }
  }

  private func kindCard(_ kind: VaultRemote.Kind, _ title: String, _ subtitle: String, _ image: String) -> some View {
    ChoiceCard(isOn: Binding(get: { draft.kind == kind }, set: { if $0 { draft.kind = kind; test = .idle; testLine = "" } })) {
      ChoiceCardLabel(title, subtitle: subtitle) { Tile(systemImage: image, hue: .indigo, size: 28) }
    }
    .kindCardHover()
  }

  private func runTest() {
    test = .working
    testLine = "Reaching \(draft.name)…"
    Task {
      switch await app.remotes.test(draft) {
      case .success(let line):
        testLine = line
        test = .done
      case .failure(let failure):
        testLine = failure.localizedDescription
        test = .failed(failure.localizedDescription)
      }
    }
  }

  private func add() {
    do {
      try app.remotes.add(draft)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// A location's files: this device's home folder, or what a remote holds (ciphertext: chunks, logs, member lists).
struct LocationView: View {
  let locationID: String
  @Environment(AppModel.self) private var app
  @State private var path = ""
  @State private var entries: [RemoteFileInfo] = []
  @State private var status: WorkStatus = .idle
  @State private var selection: Set<String> = []

  var body: some View {
    let location = app.remotes.locations.first { $0.id == locationID }
    let remote = app.vault.remote(id: locationID)
    ListAndInspector(name: "location") {
      VStack(spacing: 0) {
        HStack(spacing: 4) {
          Button("Up", systemImage: "chevron.up") { path = RemotePath.parent(path) }.buttonStyle(.kitIcon).disabled(path.isEmpty)
          KitPathBar([location?.name ?? "Location"] + path.split(separator: "/").map(String.init))
          Spacer()
        }
        .padding(.horizontal, KitMetrics.gutter + 2)
        .frame(height: 36)
        if app.remotes.fileSystem(for: locationID) == nil {
          EmptyState(
            systemImage: location?.kind.systemImage ?? "globe",
            title: location?.isOffline == true ? "\(location?.name ?? "") Is Offline" : "Can’t Browse \(location?.kind.title ?? "This Remote") Yet",
            message: location?.isOffline == true
              ? "Vault couldn’t reach it the last time it checked. It tries again when a folder that syncs through it opens."
              : NotYetAvailable(what: "Browsing \(location?.kind.title ?? "") remotes").errorDescription)
        } else {
          KitGrid(entries, columns: [
            KitGridColumn("Name", width: 300) { KitFileCell($0.name, isFolder: $0.isDirectory) },
            KitGridColumn("Size", width: 90, alignment: .trailing) { $0.isDirectory ? "—" : Bytes.text($0.size) },
            KitGridColumn("Modified", width: 150) { $0.modified.map(RelativeTime.dayTime) ?? "—" },
          ], selection: $selection) { ids in
            if let id = ids.first, entries.first(where: { $0.id == id })?.isDirectory == true { path = id }
          }
          .padding(.horizontal, KitMetrics.gutter)
        }
      }
      .paneStatusBar(systemImage: location?.kind.systemImage ?? "globe", status: status) {
        Text(location?.kind == .thisDevice ? "Your home folder" : "Only ciphertext: chunks, change logs, member lists")
        Text("\(entries.count) items").foregroundStyle(.kitSecondary)
      }
    } inspector: {
      if let location {
        InspectorHeader(location.name, meta: [location.kind.title, location.detail], systemImage: location.kind.systemImage, hue: .indigo) {}
        if let remote {
          KitSection("Remote", meta: [remote.enabled ? "On" : "Off", "checked only while a v57 app is open"], systemImage: location.kind.systemImage, hue: .indigo) {
            if !remote.endpoint.isEmpty { InspectorRow("Endpoint") { Text(remote.endpoint).kitFont(.mono).lineLimit(1).truncationMode(.middle) } }
            if !remote.bucket.isEmpty { InspectorRow("Bucket", value: remote.bucket) }
            if let host = app.vault.host(id: remote.hostID) { InspectorRow("Host", value: host.displayName) }
            if !remote.accessKeyID.isEmpty { InspectorRow("Access key") { Text(remote.accessKeyID).kitFont(.mono) } }
            InspectorRow("Secret") { KitSecretValue(label: "Secret") { remote.secret } }
          }
          let folders = app.folders.folders.filter { $0.record.remoteID == remote.id }
          KitSection("Folders", meta: "\(folders.count) sync through it", systemImage: "folder", hue: .teal) {
            ForEach(folders) { folder in
              LinkRow(title: folder.name, subtitle: folder.record.remotePath ?? "", systemImage: "lock.rectangle.stack") { app.selection = .folder(folder.id) }
            }
          }
        }
      }
    }
    .kitToolbar(location?.name ?? "Location", meta: [location?.kind.title ?? "", location?.detail ?? ""], systemImage: location?.kind.systemImage ?? "globe", hue: .indigo) {
      ToolGroup { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } } }
    }
    .task(id: path) { await load() }
  }

  private func load() async {
    guard let fileSystem = app.remotes.fileSystem(for: locationID) else { return }
    status = .working
    do {
      entries = try await fileSystem.list(path).filter { !$0.name.hasPrefix(".") }.sorted { a, b in
        a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
      }
      status = .done
    } catch {
      entries = []
      status = .failed(error.localizedDescription)
    }
  }
}
