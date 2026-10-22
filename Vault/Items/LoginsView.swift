import ComponentKit
import SwiftUI
import VaultKit

/// Which logins the list shows.
enum LoginFilter: String, KitOption, CaseIterable {
  case all, favorites, withCodes, shared

  var title: String {
    switch self {
    case .all: "All"
    case .favorites: "Favorites"
    case .withCodes: "With Codes"
    case .shared: "Shared"
    }
  }
}

/// Board 01: the logins as cards (Favorites, then all), the selected one in the inspector with its sign-in, the
/// items it links (a host, a database, a folder, a project) and when each field last changed.
struct LoginsView: View {
  @Environment(AppModel.self) private var app
  @State private var filter = LoginFilter.all
  @State private var search = ""
  /// The list's own selection: a login in Favorites is "fav:<id>", so its two rows are two values.
  @State private var listSelection: String?
  /// The login pushed on iPhone.
  @State private var pushed: String?
  @Environment(\.kitIdiom) private var idiom

  private var logins: [VaultLogin] {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    return app.vault.logins.filter { login in
      let matches =
        query.isEmpty || login.title.lowercased().contains(query) || login.username.lowercased().contains(query)
        || login.website.lowercased().contains(query)
      let kept: Bool =
        switch filter {
        case .all: true
        case .favorites: login.favorite
        case .withCodes: login.hasOneTimeCode
        case .shared: app.sharing.sharedWith(login.id) != nil
        }
      return matches && kept
    }
  }

  var body: some View {
    @Bindable var app = app
    let logins = logins
    let all = app.vault.logins
    let withCodes = all.filter(\.hasOneTimeCode).count
    ListAndInspector(name: "logins") {
      VStack(spacing: 0) {
        HStack {
          if idiom == .phone {
            KitSegmented(selection: $filter, options: [LoginFilter.all, .favorites, .withCodes].map { ($0.title, $0) })
              .kitSegmentedStyle(.wide)
          } else {
            KitSegmented(selection: $filter)
            Spacer()
            // On the Mac only: at iPad widths it wraps beside the filters.
            if idiom == .mac { Text("Sorted by name").kitFont(.caption) }
          }
        }
        .padding(.horizontal, KitMetrics.gutter + 4)
        .padding(.vertical, 6)
        KitList(selection: Binding(
          get: { listSelection ?? app.selectedLogin },
          set: { value in
            listSelection = value
            app.selectedLogin = value.map { $0.hasPrefix("fav:") ? String($0.dropFirst(4)) : $0 }
            if idiom == .phone { pushed = app.selectedLogin }
          }
        )) {
          let favorites = logins.filter(\.favorite)
          if filter == .all, search.isEmpty, !favorites.isEmpty {
            KitSection("Favorites", meta: ["\(favorites.count) logins", "pinned on every device"], systemImage: "star", hue: .yellow) {
              ForEach(favorites) { LoginRow(login: $0, value: "fav:" + $0.id) }
            }
          }
          KitSection(
            filter == .all ? "All Logins" : filter.title,
            meta: ["\(logins.count) logins", "\(logins.filter(\.hasOneTimeCode).count) with \(idiom == .phone ? "codes" : "one-time codes")",
                   sharedCount(logins) > 0 && idiom != .phone ? "\(sharedCount(logins)) shared" : ""],
            systemImage: "key.horizontal"
          ) {
            ForEach(logins) { LoginRow(login: $0) }
            if logins.isEmpty {
              Text(search.isEmpty ? "No logins yet." : "No logins match “\(search)”.").kitFont(.caption).padding(8)
            }
          }
        }
      }
      .paneStatusBar(systemImage: "icloud", status: app.isDemo || app.vault.sync?.isRunning == true ? .done : .idle) {
        Text(app.isDemo || app.vault.sync?.isRunning == true ? "Synced through iCloud \(RelativeTime.short(app.lastSync ?? .now.addingTimeInterval(-60)))" : "On this device")
        Text("\(all.count) logins").foregroundStyle(.kitSecondary)
      }
    } inspector: {
      if let login = all.first(where: { $0.id == app.selectedLogin }) {
        LoginInspector(login: login)
      } else {
        EmptyState(systemImage: "key.horizontal", title: "No Login Selected", message: "Pick a login to see its sign-in.")
      }
    }
    .kitToolbar("Logins", meta: ["\(all.count) logins", "\(withCodes) with \(idiom == .phone ? "codes" : "one-time codes")"], systemImage: "key.horizontal") {
      if idiom == .phone {
        Button("New Login", systemImage: "plus") { app.sheet = .newItem(.login) }.buttonStyle(.kitRound)
      } else {
        ToolGroup {
          Button("New Login", systemImage: "plus") { app.sheet = .newItem(.login) }
          Button("Generate", systemImage: "wand.and.stars") { app.sheet = .newItem(.login) }
        }
        ToolbarSearch(text: $search, prompt: "Name, website, username")
      }
    }
    .phoneBottomBar(prompt: "Name, website, username", search: $search) {
      Button("Generate", systemImage: "wand.and.stars") { app.sheet = .newItem(.login) }
    }
    .onAppear { if idiom == .phone, LaunchOptions.pushes { pushed = app.selectedLogin } }
    .navigationDestination(item: $pushed) { id in
      if let login = app.vault.logins.first(where: { $0.id == id }) {
        LoginPage(login: login)
      }
    }
  }

  private func sharedCount(_ logins: [VaultLogin]) -> Int {
    logins.filter { app.sharing.sharedWith($0.id) != nil }.count
  }
}

/// A login in the list: its letter tile, title, "username · domain", and the links and code it has.
private struct LoginRow: View {
  let login: VaultLogin
  var value: String?
  @Environment(AppModel.self) private var app

  var body: some View {
    SidebarRow(value: value ?? login.id, login.displayName, subtitle: [login.username, login.domain ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")) {
      LetterTile(name: login.displayName, size: KitMetrics.rowTile(.pad) - 4)
    } trailing: {
      HStack(spacing: 6) {
        if let person = app.sharing.sharedWith(login.id) {
          Chip(person, hue: .purple).controlSize(.small)
        }
        if !login.links.isEmpty {
          HStack(spacing: 2) {
            Image(systemName: "link")
            Text("\(login.links.count)")
          }
          .accessibilityLabel("\(login.links.count) linked items")
        }
        if login.hasOneTimeCode {
          Image(systemName: "clock").accessibilityLabel("One-time code")
        }
      }
      .font(.system(size: 10))
      .foregroundStyle(.kitTertiary)
    }
  }
}

/// The selected login: header, sign-in, linked items, changes, actions.
struct LoginInspector: View {
  let login: VaultLogin
  @Environment(AppModel.self) private var app
  @Environment(\.pushedDetail) private var pushed
  @State private var copies = 0

  var body: some View {
    if !pushed { header }
    sections
    if !pushed {
      ActionBar {
        Button("Edit") { app.sheet = .newItem(.login) }
        Button("Copy Password") {
          if let password = login.password { KitPasteboard.copySecret(password) }
          copies += 1
        }
        .effect(.success, on: copies)
        Button("Share…") { app.selection = .devices }
        Button("More", systemImage: "ellipsis") {}.labelStyle(.iconOnly)
      }
    }
  }

  private var header: some View {
    RichHeader(Text(login.displayName), size: .title) {
      LetterTile(name: login.displayName, size: 30)
    } meta: {
      VStack(alignment: .leading, spacing: 4) {
        MetaLine("Login", login.domain ?? "")
        if login.favorite { Chip("Favorite", hue: .yellow).controlSize(.small) }
      }
    } accessory: {
      EmptyView()
    }
    .padding(.horizontal, 6)
  }

  @ViewBuilder
  private var sections: some View {
    KitSection("Sign-in", meta: ["iCloud Keychain", "v57 apps only"], systemImage: "key.horizontal") {
      InspectorRow("Username", value: login.username)
      InspectorRow("Password") { KitSecretValue { login.password } }
      if let code = login.oneTimeCode {
        InspectorRow(pushed ? "Code" : "One-time code") {
          KitOneTimeCode(period: TimeInterval(code.period)) { code.code(at: $0) }
        }
      }
      if let domain = login.domain, let url = URL(string: login.website.contains("://") ? login.website : "https://\(login.website)") {
        InspectorRow("Website") {
          Button(domain) { KitDesktop.open(url) }.buttonStyle(.plain).foregroundStyle(.kitLink)
        }
      }
    }
    let links = LinkedItems(app: app).resolve(login.links)
    if !links.isEmpty {
      KitSection("Linked", meta: ["\(links.count) items", "every v57 app sees the link"], systemImage: "link", hue: .teal) {
        ForEach(links) { link in
          if pushed, link.destination == .hosts, let host = app.vault.host(id: link.id) {
            NavigationLink { HostPage(host: host) } label: {
              LinkRow(title: link.title, subtitle: link.subtitle, systemImage: link.systemImage) {}.allowsHitTesting(false)
            }
            .buttonStyle(.plain)
          } else {
            LinkRow(title: link.title, subtitle: link.subtitle, systemImage: link.systemImage) { app.selection = link.destination }
          }
        }
      }
    }
    ChangesSection(id: login.id, fields: [
      ("Password", "passwordChanged"), ("One-time code", "otpChanged"), ("Username", "username"), ("Website", "website"),
    ], dates: ["passwordChanged": login.passwordChanged, "otpChanged": login.otpChanged].compactMapValues { $0 })
  }
}

/// A login pushed on iPhone: the inspector's cards, Edit on top, Copy Password and Share at the bottom.
struct LoginPage: View {
  let login: VaultLogin
  @Environment(AppModel.self) private var app
  @State private var copies = 0

  var body: some View {
    PushedDetail(title: login.displayName, meta: ["Login", login.domain ?? ""]) {
      LetterTile(name: login.displayName, size: 30)
    } content: {
      LoginInspector(login: login)
    } trailing: {
      Button("Edit") { app.sheet = .newItem(.login) }.buttonStyle(.kit)
    } actions: {
      Button("Copy Password", systemImage: "doc.on.doc") {
        if let password = login.password { KitPasteboard.copySecret(password) }
        copies += 1
      }
      .effect(.success, on: copies)
      Button("Share", systemImage: "square.and.arrow.up") { app.selection = .devices }.labelStyle(.iconOnly)
      BarMenu {
        Button("Copy Username", systemImage: "person") { KitPasteboard.copy(login.username) }
        if login.hasOneTimeCode {
          Button("Copy Code", systemImage: "clock") {
            if let code = login.oneTimeCode?.code() { KitPasteboard.copySecret(code) }
          }
        }
        Button("Copy Website", systemImage: "link") { KitPasteboard.copy(login.website) }.disabled(login.website.isEmpty)
      }
    }
  }
}

/// "Changes: each field keeps its latest edit": when and on which device each field last changed, from the
/// fields' clocks.
struct ChangesSection: View {
  let id: String
  let fields: [(title: String, key: String)]
  /// Fields that keep their own date (a secret's change), shown instead of the field's write time.
  var dates: [String: Date] = [:]
  @Environment(AppModel.self) private var app

  var body: some View {
    let changes = app.vault.fieldChanges(id: id)
    let rows = fields.compactMap { field in changes[field.key].map { (field.title, $0) } }
    if !rows.isEmpty {
      KitSection("Changes", meta: "each field keeps its latest edit", systemImage: "clock", hue: .gray) {
        ForEach(rows, id: \.0) { title, change in
          InspectorRow(title, value: "\(RelativeTime.day(dates[change.field] ?? change.date)) · \(app.deviceName(change.device))", copyable: false)
        }
      }
    }
  }
}

/// A linked item resolved from its id: what it is, where it lives, where it opens.
struct LinkedItem: Identifiable {
  var id: String
  var title: String
  var subtitle: String
  var systemImage: String
  var destination: SidebarItem
}

/// Resolves link ids against hosts, databases, folders and projects.
struct LinkedItems {
  let app: AppModel

  func resolve(_ ids: Set<String>) -> [LinkedItem] {
    var items: [LinkedItem] = []
    let vault = app.vault
    for host in vault.hosts where ids.contains(host.id) {
      items.append(LinkedItem(id: host.id, title: host.displayName, subtitle: "SSH host · Shell, Database", systemImage: "server.rack", destination: .hosts))
    }
    for database in vault.databases where ids.contains(database.id) {
      let through = database.sshHostID.flatMap { vault.host(id: $0)?.displayName }
      let engine = DatabaseEngine.name(database.engine)
      items.append(LinkedItem(
        id: database.id, title: database.name, subtitle: [through.map { "\(engine) through \($0)" } ?? engine, "Database"].joined(separator: " · "),
        systemImage: "cylinder", destination: .databases))
    }
    for folder in app.folders.folders where ids.contains(folder.id) {
      items.append(LinkedItem(
        id: folder.id, title: folder.name, subtitle: folder.isEncrypted ? "Encrypted folder" + (folder.sharedWith.map { " · shared with \($0)" } ?? "") : "Synced folder",
        systemImage: "lock.rectangle.stack", destination: .folder(folder.id)))
    }
    for project in vault.projects where ids.contains(project.id) {
      items.append(LinkedItem(id: project.id, title: project.name, subtitle: "Project · Git, Code, Dev", systemImage: "arrow.triangle.branch", destination: .projects))
    }
    return items
  }
}

/// Database engines as people read them.
enum DatabaseEngine {
  static func name(_ engine: String) -> String {
    switch engine {
    case VaultDatabase.Engine.postgres: "PostgreSQL"
    case VaultDatabase.Engine.mysql: "MySQL"
    case VaultDatabase.Engine.mariadb: "MariaDB"
    case VaultDatabase.Engine.sqlserver: "SQL Server"
    case VaultDatabase.Engine.sqlite: "SQLite"
    case VaultDatabase.Engine.duckdb: "DuckDB"
    case VaultDatabase.Engine.mongodb: "MongoDB"
    case VaultDatabase.Engine.redis: "Redis"
    case VaultDatabase.Engine.cassandra: "Cassandra"
    case VaultDatabase.Engine.scylla: "ScyllaDB"
    default: engine.capitalized
    }
  }
}
