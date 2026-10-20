import ComponentKit
import SwiftUI
import VaultKit

/// The database connections Database and Shell share, as a table; the inspector shows the server, the tunnel and
/// the password.
struct DatabasesView: View {
  @Environment(AppModel.self) private var app
  @State private var search = ""
  @State private var selection: Set<String> = []

  var body: some View {
    let vault = app.vault
    let query = search.lowercased()
    let databases = vault.databases.filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.host.lowercased().contains(query) }
    ListAndInspector(name: "databases") {
      KitGrid(databases, columns: [
        KitGridColumn("Name", width: 180) { database in
          HStack(spacing: 8) {
            Image(systemName: "cylinder").font(.system(size: 12)).foregroundStyle(Hue.indigo.fill)
            Text(database.name).lineLimit(1)
            if database.isProduction { Chip.production.controlSize(.small) }
          }
        },
        KitGridColumn("Engine", width: 100) { DatabaseEngine.name($0.engine) },
        KitGridColumn("Server", width: 190, mono: true) { $0.filePath.isEmpty ? "\($0.host):\($0.port)" : $0.filePath },
        KitGridColumn("Through", width: 110) { vault.host(id: $0.sshHostID)?.displayName ?? "—" },
        KitGridColumn("User", width: 90) { $0.user },
      ], selection: $selection)
      .padding(KitMetrics.gutter)
      .kitStatusBar(systemImage: "icloud", status: .done) {
        Text("\(vault.databases.count) connections")
        Text("shared with Database and Shell").foregroundStyle(.kitSecondary)
      }
    } inspector: {
      if let database = vault.databases.first(where: { $0.id == app.selectedDatabase }) {
        InspectorHeader(database.name, meta: [DatabaseEngine.name(database.engine), "Database"], systemImage: "cylinder", hue: .indigo) {
          if database.isProduction { Chip.production.controlSize(.small) }
          if database.isReadOnly { Chip.readOnly.controlSize(.small) }
        }
        KitSection("Server", meta: [database.useTLS ? "TLS" : "no TLS", database.database], systemImage: "cylinder", hue: .indigo) {
          if database.filePath.isEmpty {
            InspectorRow("Host") { Text(database.host).kitFont(.mono) }
            InspectorRow("Port", value: "\(database.port)")
          } else {
            InspectorRow("File") { Text(database.filePath).kitFont(.mono).lineLimit(1).truncationMode(.middle) }
          }
          InspectorRow("User", value: database.user)
          InspectorRow("Password") { KitSecretValue { VaultSecrets.password(for: database.id) } }
        }
        if let host = vault.host(id: database.sshHostID) {
          KitSection("Tunnel", meta: "through SSH", systemImage: "server.rack") {
            LinkRow(title: host.displayName, subtitle: "\(host.user)@\(host.hostname)", systemImage: "server.rack") {
              app.selectedHost = host.id
              app.selection = .hosts
            }
          }
        }
        ChangesSection(id: database.id, fields: [("Host", "host"), ("User", "user"), ("Database", "database")])
      } else {
        EmptyState(systemImage: "cylinder", title: "No Connection Selected", message: "Pick a connection to see its server.")
      }
    }
    .kitToolbar("Databases", meta: ["\(vault.databases.count) connections", "shared with Database"], systemImage: "cylinder", hue: .indigo) {
      ToolbarSearch(text: $search, prompt: "Name, server")
    }
    .onAppear { selection = app.selectedDatabase.map { [$0] } ?? [] }
    .onChange(of: selection) { _, ids in if let id = ids.first { app.selectedDatabase = id } }
  }
}

/// The projects Git, Code and Dev share, with their folder on each device.
struct ProjectsView: View {
  @Environment(AppModel.self) private var app
  @State private var search = ""

  var body: some View {
    @Bindable var app = app
    let vault = app.vault
    let query = search.lowercased()
    let projects = vault.projects.filter { query.isEmpty || $0.name.lowercased().contains(query) }
    ListAndInspector(name: "projects") {
      KitList(selection: $app.selectedProject) {
        KitSection("Projects", meta: ["\(projects.count) projects", "\(vault.localProjects.count) on this device"], systemImage: "folder", hue: .brown) {
          ForEach(projects) { project in
            SidebarRow(value: project.id, project.name, subtitle: project.localPath.map(Self.tilde) ?? "Not on this device") {
              if let icon = project.icon.flatMap(Image.init(data:)) {
                Avatar(name: project.name, image: icon, kind: .thing, size: KitMetrics.rowTile(.pad) - 4)
              } else {
                LetterTile(name: project.name, size: KitMetrics.rowTile(.pad) - 4)
              }
            } trailing: {
              Text(project.kinds.contains(.xcode) ? "Xcode" : project.kinds.contains(.swiftPackage) ? "Swift package" : "")
                .kitFont(.caption)
            }
          }
        }
      }
      .padding(.top, KitMetrics.gutter)
    } inspector: {
      if let project = vault.projects.first(where: { $0.id == app.selectedProject }) {
        InspectorHeader(project.name, meta: ["Project", project.remoteURL.flatMap { URL(string: $0)?.host } ?? "local"], systemImage: "folder", hue: .brown) {}
        KitSection("Folders", meta: "\(project.paths.count) devices", systemImage: "folder", hue: .brown) {
          ForEach(project.paths.sorted(by: { $0.key < $1.key }), id: \.key) { device, path in
            InspectorRow(app.deviceName(device)) { Text(Self.tilde(path)).kitFont(.mono).lineLimit(1).truncationMode(.middle) }
          }
        }
        if let remote = project.remoteURL {
          KitSection("Remote", meta: "origin", systemImage: "arrow.triangle.branch") {
            InspectorRow("URL") { Text(remote).kitFont(.mono).lineLimit(1).truncationMode(.middle) }
          }
        }
      } else {
        EmptyState(systemImage: "folder", title: "No Project Selected", message: "Projects come from Git, Code and Dev.")
      }
    }
    .kitToolbar("Projects", meta: ["\(vault.projects.count) projects", "from Git, Code and Dev"], systemImage: "folder", hue: .brown) {
      ToolbarSearch(text: $search, prompt: "Search projects")
    }
    .onAppear { if app.selectedProject == nil { app.selectedProject = vault.projects.first?.id } }
  }

  static func tilde(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}

/// Payment cards: the number and code are secrets, shown on request.
struct CardsView: View {
  @Environment(AppModel.self) private var app
  @State private var selected: String?

  var body: some View {
    let cards = app.vault.cards
    ListAndInspector(name: "cards") {
      KitList(selection: $selected) {
        KitSection("Cards", meta: "\(cards.count) cards", systemImage: "creditcard", hue: .orange) {
          ForEach(cards) { card in
            SidebarRow(value: card.id, card.title, subtitle: "\(card.brand) •••• \(card.last4)", systemImage: "creditcard") {
              Text(card.expiry).kitFont(.caption)
            }
          }
          if cards.isEmpty { Text("No cards yet.").kitFont(.caption).padding(8) }
        }
      }
      .padding(.top, KitMetrics.gutter)
    } inspector: {
      if let card = cards.first(where: { $0.id == (selected ?? cards.first?.id) }) {
        InspectorHeader(card.title, meta: [card.brand, "•••• \(card.last4)"], systemImage: "creditcard", hue: .orange) {}
        KitSection("Card", meta: ["iCloud Keychain", "v57 apps only"], systemImage: "creditcard", hue: .orange) {
          InspectorRow("Holder", value: card.holder)
          InspectorRow("Number") { KitSecretValue(label: "Number") { card.number } }
          InspectorRow("Expires", value: card.expiry)
          InspectorRow("Security code") { KitSecretValue(label: "Security Code") { card.securityCode } }
        }
      } else {
        EmptyState(systemImage: "creditcard", title: "No Cards", message: "Cards fill in Safari and apps through AutoFill.") {
          Button("New Card…") { app.sheet = .newItem(.card) }.buttonStyle(.kitPrimary)
        }
      }
    }
    .kitToolbar("Cards", meta: ["\(cards.count) cards"], systemImage: "creditcard", hue: .orange) {
      ToolGroup { Button("New Card", systemImage: "plus") { app.sheet = .newItem(.card) } }
    }
  }
}

/// The notes Markdown and Shell keep in the vault, encrypted ones marked.
struct NotesView: View {
  @Environment(AppModel.self) private var app
  @State private var selected: String?

  var body: some View {
    let notes = app.notes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    ListAndInspector(name: "notes") {
      KitList(selection: $selected) {
        KitSection("Notes", meta: ["\(notes.count) notes", "\(notes.filter(\.encrypted).count) encrypted"], systemImage: "doc.text", hue: .yellow) {
          ForEach(notes) { note in
            SidebarRow(value: note.id, note.name, subtitle: note.folder.isEmpty ? "Notes" : note.folder, systemImage: "doc.text") {
              if note.encrypted { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.kitTertiary) }
            }
          }
        }
      }
      .padding(.top, KitMetrics.gutter)
    } inspector: {
      if let note = notes.first(where: { $0.id == (selected ?? notes.first?.id) }) {
        InspectorHeader(note.name, meta: [note.folder.isEmpty ? "Notes" : note.folder, note.encrypted ? "encrypted" : "plain"], systemImage: "doc.text", hue: .yellow) {}
        KitSection("Text", meta: "\(note.text.split(whereSeparator: \.isWhitespace).count) words", systemImage: "text.alignleft", hue: .yellow) {
          Text(note.text).kitFont(.callout).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        EmptyState(systemImage: "doc.text", title: "No Notes", message: "Notes come from Markdown and Shell.")
      }
    }
    .kitToolbar("Notes", meta: ["\(notes.count) notes", "from Markdown and Shell"], systemImage: "doc.text", hue: .yellow) {}
  }
}
