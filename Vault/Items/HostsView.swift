import ComponentKit
import SwiftUI
import VaultKit

/// How a host is signed in to.
enum HostFilter: String, KitOption, CaseIterable {
  case all, deviceKey, password

  var title: String {
    switch self {
    case .all: "All"
    case .deviceKey: "Device Key"
    case .password: "Password"
    }
  }
}

/// Board 02: the SSH hosts Shell and Database share, as a table; the inspector shows the connection, every
/// device's key (each device signs with its own Secure Enclave key), the trusted host key and what links to it.
struct HostsView: View {
  @Environment(AppModel.self) private var app
  @State private var filter = HostFilter.all
  @State private var search = ""
  @State private var selection: Set<String> = []

  private var hosts: [VaultHost] {
    let query = search.lowercased()
    return app.vault.hosts.filter { host in
      (query.isEmpty || host.displayName.lowercased().contains(query) || host.hostname.lowercased().contains(query)
        || host.user.lowercased().contains(query))
        && (filter == .all || (filter == .deviceKey ? host.auth == .deviceKey : host.auth == .password))
    }
  }

  var body: some View {
    let all = app.vault.hosts
    ListAndInspector(name: "hosts") {
      VStack(spacing: 0) {
        HStack {
          KitSegmented(selection: $filter)
          Spacer()
          Text("Shared with Shell and Database").kitFont(.caption)
        }
        .padding(.horizontal, KitMetrics.gutter + 4)
        .padding(.vertical, 6)
        KitGrid(hosts, columns: columns, selection: $selection)
          .padding(.horizontal, KitMetrics.gutter)
      }
      .kitStatusBar(systemImage: "icloud", status: .done) {
        Text("\(all.count) hosts")
        Text("\(all.filter { $0.auth == .deviceKey }.count) sign in with this device’s key").foregroundStyle(.kitSecondary)
      }
    } inspector: {
      if let host = all.first(where: { $0.id == app.selectedHost }) {
        HostInspector(host: host)
      } else {
        EmptyState(systemImage: "server.rack", title: "No Host Selected", message: "Pick a host to see how it signs in.")
      }
    }
    .kitToolbar("SSH Hosts", meta: ["\(all.count) hosts", "shared with Shell and Database"], systemImage: "server.rack") {
      ToolGroup { Button("New Host", systemImage: "plus") { app.sheet = .newItem(.host) } }
      ToolbarSearch(text: $search, prompt: "Name, address, user")
    }
    .onAppear { selection = app.selectedHost.map { [$0] } ?? [] }
    .onChange(of: selection) { _, ids in if let id = ids.first { app.selectedHost = id } }
  }

  private var columns: [KitGridColumn<VaultHost>] {
    let vault = app.vault
    return [
      KitGridColumn("Name", width: 150) { host in
        HStack(spacing: 8) {
          Image(systemName: "server.rack").font(.system(size: 12)).foregroundStyle(Hue.accent.fill)
          Text(host.displayName).lineLimit(1)
        }
      },
      KitGridColumn("Address", width: 230, mono: true) { host in host.port == 22 ? host.hostname : "\(host.hostname):\(host.port)" },
      KitGridColumn("User", width: 76) { $0.user },
      KitGridColumn("Sign-in", width: 110) { host in HostAuthChip(auth: host.auth) },
      KitGridColumn("Jump", width: 80) { host in
        Text(vault.host(id: host.jumpHostID)?.displayName ?? "—")
          .foregroundStyle(host.jumpHostID == nil ? AnyShapeStyle(.kitTertiary) : AnyShapeStyle(.kitLabel))
      },
      KitGridColumn("Used by", width: 120) { host in HostUse.apps(host, in: vault).joined(separator: ", ") },
    ]
  }
}

/// How a host signs in, as a chip: this device's key green, a password gray, an imported key purple.
struct HostAuthChip: View {
  let auth: VaultHost.Auth

  var body: some View {
    switch auth {
    case .deviceKey: Chip("Device key", hue: .green).controlSize(.small)
    case .password: Chip("Password", hue: .gray).controlSize(.small)
    case .importedKey: Chip("Imported key", hue: .purple).controlSize(.small)
    }
  }
}

/// Which apps use a host: Shell lists every host, Database those its connections tunnel through, Vault those its
/// remotes reach.
enum HostUse {
  @MainActor static func apps(_ host: VaultHost, in vault: Vault) -> [String] {
    var apps: [String] = []
    if host.source != "dev-vm" { apps.append("Shell") }
    if vault.databases.contains(where: { $0.sshHostID == host.id }) { apps.append("Database") }
    if host.source == "dev-vm" { apps.append("Dev") }
    return apps.isEmpty ? ["Shell"] : apps
  }
}

/// The selected host: the connection, the device keys, the known host key and what links to it.
private struct HostInspector: View {
  let host: VaultHost
  @Environment(AppModel.self) private var app

  var body: some View {
    let vault = app.vault
    InspectorHeader(host.displayName, meta: ["SSH host", "\(host.user)@\(host.name.isEmpty ? host.hostname : host.name)"], systemImage: "server.rack") {}
    KitSection("Connection", meta: ["port \(host.port)", host.jumpHostID == nil ? "no jump host" : "through \(vault.host(id: host.jumpHostID)?.displayName ?? "a jump host")"], systemImage: "server.rack") {
      InspectorRow("Host") { Text(host.hostname).kitFont(.mono).lineLimit(1).truncationMode(.middle) }
      InspectorRow("User", value: host.user)
      InspectorRow("Port", value: "\(host.port)")
      InspectorRow("Jump host", value: vault.host(id: host.jumpHostID)?.displayName ?? "None", copyable: false)
    }
    if host.auth == .deviceKey {
      KitSection("Device keys", meta: ["each device signs with its own", "Secure Enclave"], systemImage: "checkmark.shield", hue: .green) {
        ForEach(app.devices) { device in
          DeviceKeyRow(device: device, isThisDevice: device.id == vault.deviceID)
        }
      }
    } else if host.auth == .password {
      KitSection("Password", meta: ["iCloud Keychain", host.savePassword ? "saved" : "asked each time"], systemImage: "key.horizontal", hue: .gray) {
        InspectorRow("Password") { KitSecretValue { host.password } }
      }
    }
    if let known = vault.knownHosts.first(where: { $0.host == host.hostname.lowercased() && $0.port == host.port }) {
      KitSection("Known host", meta: ["trusted \(known.accepted.map { RelativeTime.day($0) } ?? "")", "shared by every app"], systemImage: "checkmark.shield", hue: .teal) {
        InspectorRow("Key", value: known.keyType?.uppercased() ?? "—", copyable: false)
        InspectorRow("Fingerprint", copyText: known.fingerprint) { Text(ShortKey.fingerprint(known.fingerprint)).kitFont(.mono) }
      }
    }
    let databases = vault.databases.filter { $0.sshHostID == host.id }
    let logins = vault.logins.filter { $0.links.contains(host.id) }
    if !databases.isEmpty || !logins.isEmpty {
      KitSection("Linked", meta: "\(databases.count + logins.count) items", systemImage: "link", hue: .teal) {
        ForEach(databases) { database in
          LinkRow(title: database.name, subtitle: "\(DatabaseEngine.name(database.engine)) through this host", systemImage: "cylinder") {
            app.selectedDatabase = database.id
            app.selection = .databases
          }
        }
        ForEach(logins) { login in
          LinkRow(title: login.displayName, subtitle: "Login", systemImage: "key.horizontal") {
            app.selectedLogin = login.id
            app.selection = .logins
          }
        }
      }
    }
    ActionBar {
      Button("Copy SSH Command") { KitPasteboard.copy("ssh \(host.port == 22 ? "" : "-p \(host.port) ")\(host.user.isEmpty ? "" : "\(host.user)@")\(host.hostname)") }
      Button("Edit") { app.sheet = .newItem(.host) }
    }
  }
}

/// One device's public SSH key: its name (and "This Mac"), the fingerprint and when it was added, Copy.
struct DeviceKeyRow: View {
  let device: VaultDeviceKey
  let isThisDevice: Bool
  @State private var copies = 0

  var body: some View {
    HStack(spacing: 10) {
      RowTile(systemImage: DeviceGlyph.systemImage(device))
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 5) {
          Text(device.deviceName).lineLimit(1)
          if isThisDevice { Text(device.platform == "macOS" ? "This Mac" : "This iPad").kitFont(.caption) }
        }
        (Text(ShortKey.fingerprint(device.fingerprint)).font(.system(size: 11, design: .monospaced))
          + Text(device.updated.map { " · added \(RelativeTime.day($0))" } ?? ""))
          .kitFont(.caption)
          .lineLimit(1)
      }
      Spacer(minLength: 6)
      Button("Copy Public Key", systemImage: "doc.on.doc") {
        KitPasteboard.copy(device.publicKey)
        copies += 1
      }
      .buttonStyle(.kitIcon)
      .effect(.success, on: copies)
    }
    .padding(.horizontal, 8)
    .frame(minHeight: 40)
  }
}

/// A device's glyph from its platform and name.
enum DeviceGlyph {
  static func systemImage(_ device: VaultDeviceKey) -> String {
    let name = device.deviceName.lowercased()
    if device.platform == "iOS" { return name.contains("iphone") ? "iphone" : "ipad" }
    if name.contains("macbook") { return "laptopcomputer" }
    if device.platform == "windows" || device.platform == "linux" { return "pc" }
    return "desktopcomputer"
  }
}
