import ComponentKit
import SwiftUI
import VaultKit

/// Sync a Folder: a folder on this device kept in step through a remote, for the user's other devices and the people
/// they share it with. Also how a folder already in the vault starts syncing: an encrypted folder made here gets a
/// remote, a folder someone shared gets the remote it's on and a place here, and a folder from another device of the
/// user's gets a place here.
struct SyncFolderSheet: View {
  /// nil for a new folder; else the vault's folder this sets up.
  let folderID: String?
  @Environment(AppModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.kitIdiom) private var idiom
  @State private var name = ""
  @State private var location: URL?
  @State private var remoteID: String?
  @State private var readOnly = true
  @State private var status: WorkStatus = .idle
  @State private var error: String?

  private var existing: FolderItem? { folderID.flatMap(app.folders.folder) }
  /// Where the folder is kept on this device, if it has a place here already.
  private var hasPlace: Bool { existing?.localURL != nil }
  private var hasRemote: Bool { existing?.record.remoteID != nil }
  private var isShared: Bool { existing?.record.isShared == true }

  var body: some View {
    let remotes = app.vault.remotes
    let title = existing.map { String(localized: "Sync “\($0.name)”") } ?? String(localized: "Sync a Folder")
    KitSheet(
      title: "\(title)",
      meta: isShared
        ? "Shared with you. Pick the remote it’s on and where to keep it; you receive every change."
        : "Your other devices and the people you share it with get a copy that follows yours. The remote only holds ciphertext.",
      systemImage: "arrow.triangle.2.circlepath", hue: .blue, width: 620
    ) {
      if existing == nil {
        LabeledField("Name") { TextField("mods", text: $name).kitField() }
      }
      if !hasPlace {
        LabeledField(existing == nil ? "Folder" : "Keep it in") {
          HStack {
            Text(ProjectsView.tilde(place.path)).kitFont(.mono).lineLimit(1).truncationMode(.middle)
            Spacer()
            #if os(macOS)
              Button("Choose…") { Task { await choose() } }.buttonStyle(.kit).controlSize(.small)
            #endif
          }
          .padding(8)
          .kitSurface(.field)
        }
        if idiom.isTouch {
          Text("In Files: On My \(ThisDevice.word) › Vault › Synced. The files stay plain there, so other apps open them.").kitFont(.caption)
        } else if existing == nil {
          Text("The files stay where they are, as they are. Vault sends what changes.").kitFont(.caption)
        }
      }
      if !hasRemote {
        VStack(alignment: .leading, spacing: 6) {
          Text("Through").kitFont(.headline).padding(.leading, 4)
          if remotes.isEmpty {
            HStack {
              Text("No remotes yet: an S3 bucket works, like a Hub’s storage, R2 or MinIO.").kitFont(.caption)
              Spacer()
              Button("Add Remote…") { app.sheet = .addRemote }.buttonStyle(.kit).controlSize(.small)
            }
          } else {
            KitSegmented(
              selection: Binding(get: { remoteID ?? remotes.first?.id ?? "" }, set: { remoteID = $0 }),
              options: remotes.prefix(5).map { ("\($0.name)", $0.id) })
            if let remote = chosenRemote {
              Text("\(LocationKind(remote.kind).title) · \(remote.displayName)\(remote.path.isEmpty ? "" : " / \(remote.path)")")
                .kitFont(.caption).lineLimit(1)
            }
          }
        }
      }
      if isShared, !hasPlace {
        Toggle("Only receive: edits here stay here", isOn: $readOnly).toggleStyle(.kitCheckbox)
      }
      if isShared, !hasRemote {
        Banner(
          "Add the same remote the owner uses.",
          message: "Same endpoint, bucket and folder, with keys that can read it. Vault opens the folder only once the owner adds you.",
          systemImage: "person.2", hue: .blue)
      } else if !isShared {
        Banner(
          "The remote only ever holds ciphertext.",
          message: "Chunks, change logs and a member list signed by you. Vault reaches it while it’s open: on open, on Sync Now and every few minutes.",
          systemImage: "shield", hue: .blue)
      }
      if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
    } footer: {
      SheetStatus(statusLine, systemImage: "arrow.triangle.2.circlepath", status: status)
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Sync") { start() }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(!canStart || status == .working)
    }
    .onAppear {
      if remoteID == nil { remoteID = existing?.record.remoteID ?? app.vault.remotes.first?.id }
    }
  }

  private var chosenRemote: VaultRemote? { app.vault.remote(id: remoteID ?? app.vault.remotes.first?.id) }

  private var canStart: Bool {
    (existing != nil || !name.trimmingCharacters(in: .whitespaces).isEmpty) && (hasRemote || chosenRemote != nil)
  }

  private var statusLine: String {
    switch status {
    case .working: String(localized: "Reaching \(chosenRemote?.name ?? "the remote")…")
    case .failed: String(localized: "Didn’t start")
    default: chosenRemote.map { String(localized: "Through \($0.name)") } ?? String(localized: "Choose a remote")
    }
  }

  /// The folder chosen, else Vault's own place for it: the app group's Folders on the Mac, Documents › Synced on
  /// iPhone and iPad.
  private var place: URL {
    if let location { return location }
    let folderName = existing?.name ?? (name.isEmpty ? String(localized: "Folder") : name)
    #if os(macOS)
      return app.folders.decryptedRoot.deletingLastPathComponent().appendingPathComponent("Folders").appendingPathComponent(folderName, isDirectory: true)
    #else
      return URL.documentsDirectory.appendingPathComponent("Synced").appendingPathComponent(folderName, isDirectory: true)
    #endif
  }

  #if os(macOS)
    private func choose() async {
      guard let url = await KitDesktop.chooseFolders(prompt: String(localized: "Sync"), canCreateDirectories: true).first else { return }
      location = url
      if name.isEmpty { name = url.lastPathComponent }
    }
  #endif

  private func start() {
    let remote = hasRemote ? nil : chosenRemote?.id
    status = .working
    error = nil
    Task {
      do {
        if let existing {
          try await app.folders.connect(
            existing.id, remoteID: remote, at: hasPlace ? nil : place, mode: isShared && !hasPlace ? (readOnly ? .readOnly : .readWrite) : nil)
          app.open(.folder(existing.id))
        } else if let remote {
          let record = try await app.folders.createSynced(name: name.trimmingCharacters(in: .whitespaces), at: place, remoteID: remote)
          app.open(.folder(record.id))
        }
        status = .done
        dismiss()
      } catch {
        status = .failed(error.localizedDescription)
        self.error = error.localizedDescription
      }
    }
  }
}

/// A folder in the vault that doesn't sync here yet: shared with the user and waiting for its remote, or synced by
/// another of their devices and not kept on this one. Says what's missing and opens Sync a Folder.
struct FolderSetupView: View {
  let folder: FolderItem
  @Environment(AppModel.self) private var app

  var body: some View {
    let record = folder.record
    let owner = record.ownerSigningKey.flatMap { key in app.sharing.people.first { $0.record.signingKey == key }?.name }
    EmptyState(
      systemImage: record.isShared ? "person.2" : "arrow.triangle.2.circlepath",
      title: record.isShared ? "\(owner ?? String(localized: "Someone")) Shared “\(folder.name)”" : "“\(folder.name)” Isn’t on This \(ThisDevice.word)",
      message: record.isShared
        ? "Pick the remote it’s on and where to keep it. You get a copy that follows theirs once they add you, after you compare the safety code."
        : "Your other devices sync it through \(record.remoteID.flatMap(app.vault.remote(id:))?.name ?? String(localized: "a remote")). Pick where to keep it here.")
    {
      Button("Set Up Sync…") { app.sheet = .syncFolder(folder.id) }.buttonStyle(.kitPrimary)
    }
    .kitPane(.content)
    .kitToolbar(folder.name, meta: [record.isShared ? String(localized: "Shared with you") : String(localized: "Synced folder"), String(localized: "not here yet")], systemImage: "folder", hue: .blue) {
      EmptyView()
    }
  }
}
