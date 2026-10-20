import ComponentKit
import SwiftUI
import VaultFiles
import VaultKit

/// iPhone board 02: a folder's files as rows in one card (the kit's file cells, with size and date under the name),
/// then the encryption, remote and member cards. Decrypted, a banner and the countdown card lead; Lock is on top.
/// A folder row pushes the folder, a file row pushes its preview.
struct PhoneFolderView: View {
  let folder: FolderItem
  var path = ""
  @Environment(AppModel.self) private var app
  @State private var search = ""
  @State private var showsMore = false

  var body: some View {
    let session = app.folders.session(for: folder.id)
    let totals = app.folders.totals(folder.id)
    let entries = app.folders.entries(folder.id, path: path).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    let name = path.isEmpty ? folder.name : String(path.split(separator: "/").last ?? "")
    ScrollView {
      VStack(spacing: KitMetrics.gutter) {
        if let session, path.isEmpty {
          Banner(
            "In Files until \(session.lockDate.formatted(date: .omitted, time: .shortened))",
            message: "On My \(ThisDevice.word) › Vault › \(folder.name). Edits are sealed back as apps save.",
            systemImage: "lock.open", hue: .orange)
          KitSection(Text("Decrypted")) {
            HStack(spacing: KitMetrics.gutter) {
              Button { app.folders.extend(folder.id) } label: { Label("+30 min", systemImage: "timer").frame(maxWidth: .infinity) }
              Button { KitDesktop.reveal([session.copyURL]) } label: { Text("Open in Files").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.kit)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
          } icon: {
            LiveIcon(systemImage: "lock.open", hue: .orange, status: .working(progress: session.fractionLeft), size: 30)
          } meta: {
            MetaLine("\(session.minutesLeft) min left", "\(session.sealedEdits) edits sealed")
          } accessory: {
            EmptyView()
          }
        }
        KitSection(
          name,
          meta: [path.isEmpty ? "\(totals.items) items" : "\(entries.count) items", path.isEmpty ? Bytes.text(totals.bytes) : "",
                 folder.sharedWith.map { "shared with \($0)" } ?? (folder.isEncrypted ? "names encrypted" : "")],
          systemImage: "lock.rectangle.stack", hue: .teal
        ) {
          ForEach(entries) { entry in
            NavigationLink {
              if entry.isDirectory {
                PhoneFolderView(folder: folder, path: entry.path)
              } else {
                FilePreviewPage(folder: folder, entry: entry)
              }
            } label: {
              PhoneFileRow(folder: folder, entry: entry, session: session)
            }
            .buttonStyle(.plain)
          }
          if entries.isEmpty { Text(search.isEmpty ? "Empty." : "Nothing matches “\(search)”.").kitFont(.caption).padding(10) }
        }
        if session == nil, path.isEmpty, folder.isEncrypted {
          KitSection("Encrypted", meta: "on every device", systemImage: "lock", hue: .teal) {
            ForEach(app.devices.filter { folder.record.storages[$0.id] != nil || $0.id == app.vault.deviceID }) { device in
              InspectorRow(device.id == app.vault.deviceID ? "This \(ThisDevice.word)" : device.deviceName) {
                if folder.record.storage(for: device.id) == .encrypted {
                  Chip("Encrypted", hue: .teal).controlSize(.small)
                } else {
                  Text("Plain")
                }
              }
            }
          }
        }
        if path.isEmpty, session == nil {
          RemoteCard(folder: folder)
          MembersCard(folder: folder)
        }
      }
      .padding(.horizontal, KitMetrics.gutter + 4)
      .padding(.top, 4)
      .padding(.bottom, 24)
    }
    .background(.kitWindow)
    .kitPane(.content)
    .kitToolbar(name, title: {
      KitTitle(
        name, meta: session.map { ["Decrypted", "\($0.minutesLeft) min left"] } ?? [folder.isEncrypted ? "Encrypted" : "Plain here", folder.isEncrypted ? "v57 apps only" : "synced"],
        systemImage: session == nil ? "lock.rectangle.stack" : "lock.open", hue: session == nil ? .teal : .orange,
        status: session.map { .working(progress: $0.fractionLeft) } ?? .idle)
    }) {
      if session != nil {
        Button("Lock", systemImage: "lock") { app.folders.lock(folder.id) }.buttonStyle(.kit)
      } else {
        Button("More", systemImage: "ellipsis") { showsMore = true }
          .buttonStyle(.kitRound)
          .kitMenu(isPresented: $showsMore) {
            Button("Share…", systemImage: "person.badge.plus") { app.sheet = .share(folder.id) }
            Button("Export Decrypted…", systemImage: "square.and.arrow.down") {}
              .disabled(true)
          }
      }
    }
    .kitBottomBar(searchText: $search, prompt: "Search \(name)") {
      if session == nil, folder.isEncrypted {
        Button("Decrypt…", systemImage: "lock.open") { app.sheet = .decrypt(folder.id) }
      } else if let session {
        BarMenu("Share", systemImage: "square.and.arrow.up") {
          KitMenuShare("Share the Plain Copy…", items: [session.copyURL])
          Divider()
          KitMenuFooter("Other apps can read it", subtitle: "Until it locks at \(session.lockDate.formatted(date: .omitted, time: .shortened))", systemImage: "info.circle")
        }
        BarMenu {
          Button("Add 30 Minutes", systemImage: "timer") { app.folders.extend(folder.id) }
          Button("Open in Files", systemImage: "folder") { KitDesktop.reveal([session.copyURL]) }
          Divider()
          Button("Lock Now", systemImage: "lock") { app.folders.lock(folder.id) }
        }
      }
    }
    .navigationBarBackButtonHidden(true)
  }
}

/// A file or folder in the iPhone list: the kit's file glyph, the name, its size (or items) and date, and how it
/// stands (synced, sending, sealing, changed).
private struct PhoneFileRow: View {
  let folder: FolderItem
  let entry: FileEntry
  let session: FolderSession?
  @Environment(AppModel.self) private var app

  var body: some View {
    let kind = KitFileCell.Kind.of(entry.name, isFolder: entry.isDirectory)
    HStack(spacing: 12) {
      Image(systemName: kind.systemImage)
        .font(.system(size: 17))
        .foregroundStyle(kind == .folder ? AnyShapeStyle(Hue.teal.fill) : AnyShapeStyle(.kitSecondary))
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.name).kitFont(.body).lineLimit(1).truncationMode(.middle)
        Text([entry.isDirectory ? "\(app.folders.itemCount(folder.id, path: entry.path)) items" : Bytes.text(entry.size),
              entry.modified.map { RelativeTime.day($0).lowercased() == "today" ? "today" : RelativeTime.day($0) } ?? ""]
          .filter { !$0.isEmpty }.joined(separator: " · "))
          .kitFont(.caption)
      }
      Spacer(minLength: 8)
      status
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 54)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var status: some View {
    if let session, session.activity.phase == .sealing, session.activity.file == entry.path {
      RowProgress(value: session.activity.fraction, title: "Sealing")
    } else if let progress = app.folders.sync.activity(for: folder.id)?.sending[entry.name] {
      RowProgress(value: progress, title: "Sending")
    } else {
      Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.kitTertiary)
    }
  }
}

/// A file read from the folder's sealed chunks and shown in place: nothing plain is written to show it. Sharing
/// writes a plain copy only when Share a Plain Copy is picked, and deletes it when the page closes.
struct FilePreviewPage: View {
  let folder: FolderItem
  let entry: FileEntry
  @Environment(AppModel.self) private var app
  @State private var data: Data?
  @State private var plainCopy: URL?
  @State private var error: String?

  var body: some View {
    Group {
      if let data {
        KitFilePreview(name: entry.name, data: data)
          .padding(KitMetrics.gutter + 4)
      } else {
        EmptyState(systemImage: "doc", title: entry.name, message: error ?? "Reading the sealed chunks…", status: error == nil ? .working : .failed(error))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.kitWindow)
    .kitPane(.content)
    .kitToolbar(entry.name, title: {
      RichHeader(Text(entry.name), size: .title) {
        SizedLiveIcon(hue: .gray, status: .idle, size: .title) { Image(systemName: KitFileCell.Kind.of(entry.name).systemImage) }
      } meta: {
        MetaLine(Bytes.text(entry.size), "read from sealed chunks")
      } accessory: {
        EmptyView()
      }
    }) {}
    .kitBottomBar(searchText: nil) {
      BarMenu("Share", systemImage: "square.and.arrow.up") {
        KitMenuShare("Share a Plain Copy…") { writePlainCopy().map { [$0] } ?? [] }
        Button("Show in Folder", systemImage: "folder") {}
          .disabled(true)
        Divider()
        KitMenuFooter("The copy is plain", subtitle: "Deleted once you leave this page", systemImage: "info.circle")
      }
      .disabled(data == nil)
    }
    .navigationBarBackButtonHidden(true)
    .task { load() }
    .onDisappear { removePlainCopy() }
  }

  private func load() {
    do {
      data = try app.folders.read(folder.id, path: entry.path)
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// A plain copy in a temporary folder, only for the share sheet.
  private func writePlainCopy() -> URL? {
    if let plainCopy { return plainCopy }
    guard let data else { return nil }
    let directory = Self.shareDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent(entry.name)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard (try? data.write(to: url, options: .completeFileProtection)) != nil else { return nil }
    plainCopy = url
    return url
  }

  private func removePlainCopy() {
    if let plainCopy { try? FileManager.default.removeItem(at: plainCopy.deletingLastPathComponent()) }
    plainCopy = nil
  }

  /// Where plain copies for sharing go; what a quit left behind is removed at the next launch.
  static let shareDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultShare")

  static func removeLeftoverCopies() {
    try? FileManager.default.removeItem(at: shareDirectory)
  }
}
