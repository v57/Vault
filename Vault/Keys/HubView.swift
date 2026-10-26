import ComponentKit
import SwiftUI
import VaultHub
import VaultKit

/// Your own Hubs: whether this device connects, its safety code, the devices each Hub knows (with presence and SSH),
/// and the devices waiting to join, approved by comparing the safety code. The selected device in the inspector.
struct HubView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var pushed: String?

  var body: some View {
    @Bindable var app = app
    let hubs = app.hubs.hubs
    ListAndInspector(name: "hub") {
      KitList(selection: Binding(get: { app.selectedHubDevice }, set: { id in
        app.selectedHubDevice = id
        if idiom == .phone { pushed = id }
      })) {
        if hubs.isEmpty {
          introSection
        }
        ForEach(hubs) { hub in
          HubSection(hub: hub)
        }
        if let error = app.hubs.error {
          Banner("This \(ThisDevice.word) can’t connect.", message: error, systemImage: "exclamationmark.triangle", hue: .red)
        }
      }
      .padding(.top, KitMetrics.gutter)
    } inspector: {
      if let (hub, device) = selected {
        HubDeviceInspector(hub: hub, device: device)
      } else {
        EmptyState(systemImage: "point.3.connected.trianglepath.dotted", title: "No Device Selected", message: "Pick a device to see what it offers.")
      }
    }
    .kitToolbar("Hub", meta: toolbarMeta(hubs), systemImage: "point.3.connected.trianglepath.dotted", hue: .purple) {
      if idiom == .phone {
        Button("Add Hub", systemImage: "plus") { app.sheet = .addHub }.buttonStyle(.kitRound)
      } else {
        ToolGroup { Button("Add Hub", systemImage: "plus") { app.sheet = .addHub } }
      }
    }
    .onAppear { if idiom == .phone, LaunchOptions.pushes { pushed = app.selectedHubDevice } }
    .navigationDestination(item: $pushed) { id in
      if let (hub, device) = find(id) {
        PushedDetail(
          title: device.name, meta: [HubPlatform.name(device.platform), device.isOnline ? "Online" : "Offline"],
          systemImage: HubPlatform.systemImage(device.platform), hue: .purple
        ) {
          HubDeviceInspector(hub: hub, device: device)
        } trailing: {
          EmptyView()
        } actions: {
          EmptyView()
        }
      }
    }
  }

  private var selected: (HubItem, VaultHubDevice)? { app.selectedHubDevice.flatMap(find) }

  private func find(_ id: String) -> (HubItem, VaultHubDevice)? {
    for hub in app.hubs.hubs {
      if let device = hub.devices.first(where: { $0.id == id }) { return (hub, device) }
    }
    return nil
  }

  private func toolbarMeta(_ hubs: [HubItem]) -> [String] {
    guard !hubs.isEmpty else { return ["off", "bring your own"] }
    let devices = hubs.flatMap(\.members)
    return ["\(hubs.count) \(hubs.count == 1 ? "Hub" : "Hubs")", "\(devices.count) devices", "\(devices.filter(\.isOnline).count) online"]
  }

  private var introSection: some View {
    KitSection("Hub", meta: ["off", "your own server"], systemImage: "point.3.connected.trianglepath.dotted", hue: .purple) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Connect to a Hub you run (on a Mac, a home server or a VPS) to see all your devices, Linux, Windows and Android included, and reach them over SSH from Shell, Database and Code by name.")
          .kitFont(.callout)
        Text("Hub introduces devices and carries envelopes. It never sees your vault: logins, notes and keys stay end-to-end encrypted.")
          .kitFont(.caption)
        Button("Add Hub…") { app.sheet = .addHub }.buttonStyle(.kitPrimary).controlSize(.small)
      }
      .padding(8)
    }
  }
}

/// One Hub: this device's switch and status, the devices waiting, then every device.
private struct HubSection: View {
  let hub: HubItem
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var confirmsRemove = false

  var body: some View {
    let live = hub.members
    KitSection(
      hub.name, meta: [HubStatusText.title(hub.status), "\(live.count) devices", hub.record.isPlayground ? "playground" : ""].filter { !$0.isEmpty },
      systemImage: "point.3.connected.trianglepath.dotted", hue: hub.status == .connected ? .purple : .gray
    ) {
      InspectorRow("Connect from this \(ThisDevice.word)", copyText: nil) {
        Toggle("Connect", isOn: Binding(get: { hub.status != .off }, set: { app.hubs.setConnects(hub.id, $0) }))
          .toggleStyle(.kitSwitch).kitLabelsHidden()
      }
      InspectorRow("Address", copyText: hub.record.url) { Text(hub.record.url).kitFont(.mono).lineLimit(1).truncationMode(.middle) }
      if hub.status != .off {
        InspectorRow("Status") {
          HStack(spacing: 6) {
            StatusDot(hue: HubStatusText.hue(hub.status))
            Text(HubStatusText.line(hub)).lineLimit(2)
          }
        }
      }
      if hub.status == .revoked {
        Banner(
          "This \(ThisDevice.word) was revoked on \(hub.name).",
          message: "An owner removed it for good, so it can't connect again. Remove stops this \(ThisDevice.word) trying; the Hub stays for your other devices.",
          systemImage: "xmark.shield", hue: .red
        ) {
          Button("Remove") { app.hubs.leave(hub.id) }.buttonStyle(.kit)
        }
      } else if hub.status == .wrongHub {
        Banner(
          "Another server answers at \(hub.record.url).",
          message: "Its key isn't the one this Hub had, so nothing is sent to it. If the Hub was reinstalled, remove it here and add it again.",
          systemImage: "exclamationmark.shield", hue: .red
        ) {
          Button("Remove") { app.hubs.leave(hub.id) }.buttonStyle(.kit)
        }
      }
      if hub.status != .off, hub.status != .revoked, hub.status != .wrongHub {
        InspectorRow("Sync vault through it", copyText: nil) {
          Toggle("Sync vault", isOn: Binding(get: { hub.syncsRecords }, set: { app.hubs.setSyncs(hub.id, $0) }))
            .toggleStyle(.kitSwitch).kitLabelsHidden()
        }
        if hub.syncsRecords {
          InspectorRow("Records", value: hub.recordSyncLine.isEmpty ? "Waiting for the connection" : hub.recordSyncLine, copyable: false)
        } else {
          Text("For devices without iCloud: your records go to the Hub's vault service sealed with your vault keys, and a device with both carries changes between iCloud and the Hub.")
            .kitFont(.caption).padding(.horizontal, 8)
        }
      }
      if let identity = app.hubs.identity, hub.status == .needsApproval || hub.status == .connecting {
        VStack(alignment: .leading, spacing: 6) {
          Text("Approve this \(ThisDevice.word) on your Hub (the Hub app, another device’s Vault, or `hub device approve`), comparing this code:")
            .kitFont(.caption)
          KitSafetyCode(groups: identity.safetyCode.split(separator: " ").map(String.init), columns: 2)
            .fixedSize()
        }
        .padding(8)
      }
      if hub.record.isPlayground {
        Banner(
          "A public playground, not a place for real data.",
          message: "Anyone can use hub.v57.dev, with no guarantees. Your vault stays encrypted, but device names and addresses are visible to it.",
          systemImage: "exclamationmark.triangle", hue: .orange)
      }
      if !hub.pending.isEmpty {
        ForEach(hub.pending) { waiting in
          PendingRow(hub: hub, waiting: waiting)
        }
      }
      ForEach(hub.waitingElsewhere) { device in
        SidebarRow(device.name, subtitle: "\(HubPlatform.name(device.platform)) · waiting for an owner") {
          RowTile(systemImage: HubPlatform.systemImage(device.platform))
        } trailing: {
          Chip("Waiting", hue: .orange).controlSize(.small)
        }
      }
      ForEach(hub.members) { device in
        SidebarRow(value: device.id, device.name, subtitle: subtitle(device)) {
          RowTile(systemImage: HubPlatform.systemImage(device.platform))
        } trailing: {
          if device.id == app.hubs.identity?.id {
            Text("This \(ThisDevice.word)").kitFont(.caption)
          } else {
            HStack(spacing: 4) {
              StatusDot(hue: device.isOnline ? .green : .gray)
              Text(device.isOnline ? "Online" : "Offline")
            }
            .kitFont(.caption)
          }
        }
      }
      if let error = hub.error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text).padding(.horizontal, 8) }
    } accessory: {
      // Neutral here; the confirmation says what removing does.
      Button("Remove…") { confirmsRemove = true }.buttonStyle(.kit).controlSize(.small)
    }
    .kitConfirmation(
      "Remove \(hub.name)?", isPresented: $confirmsRemove,
      message: "Every device stops connecting to it, and the hosts it added go from every app. The Hub itself keeps running.",
      systemImage: "point.3.connected.trianglepath.dotted", confirm: "Remove"
    ) {
      app.hubs.remove(hub.id)
    }
  }

  private func subtitle(_ device: VaultHubDevice) -> String {
    var parts = [HubPlatform.name(device.platform)]
    if let parent = device.parent { parts.append("on \(parent)") }
    if idiom != .phone, let address = device.address { parts.append(address) }
    if device.ssh != nil { parts.append("SSH") }
    if !device.isOnline, let seen = device.lastSeen {
      let day = RelativeTime.day(seen)
      parts.append("seen \(day == "Today" || day == "Yesterday" ? day.lowercased() : day)")
    }
    return parts.joined(separator: " · ")
  }
}

/// A device asking to join: its name and the safety code to compare with its screen, Approve and Deny.
private struct PendingRow: View {
  let hub: HubItem
  let waiting: HubPendingDevice
  @Environment(AppModel.self) private var app
  @State private var confirmsApprove = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        RowTile(systemImage: HubPlatform.systemImage(waiting.platform))
        VStack(alignment: .leading, spacing: 1) {
          Text(waiting.name.isEmpty ? "A new device" : waiting.name).kitFont(.body).lineLimit(1)
          Text("\(HubPlatform.name(waiting.platform)) · wants to join\(waiting.firstSeen.map { " · \(RelativeTime.short($0))" } ?? "")")
            .kitFont(.caption).lineLimit(1)
        }
        Spacer(minLength: 8)
        Chip("Waiting", hue: .orange).controlSize(.small)
      }
      KitSafetyCode(groups: waiting.safetyCode.split(separator: " ").map(String.init), columns: 2)
        .fixedSize()
      if !waiting.codeChecks {
        Text("The Hub sent a different code than this device’s key gives. Don’t approve it unless the code on its screen matches the one above.")
          .kitFont(.caption).foregroundStyle(Hue.red.text)
      }
      HStack {
        Button("Deny") { Task { await app.hubs.deny(waiting.id, on: hub.id) } }.buttonStyle(.kit).controlSize(.small)
        Button("Approve…") { confirmsApprove = true }.buttonStyle(.kitPrimary).controlSize(.small)
      }
    }
    .padding(8)
    .kitDialog(
      "Approve \(waiting.name.isEmpty ? "this device" : waiting.name)?", isPresented: $confirmsApprove,
      message: "\(HubPlatform.name(waiting.platform)) · joins your devices on \(hub.name). Only if its screen shows this code:",
      systemImage: "checkmark.shield", hue: .green, confirm: "Approve"
    ) {
      KitSafetyCode(groups: waiting.safetyCode.split(separator: " ").map(String.init), columns: 2)
    } action: {
      Task { await app.hubs.approve(waiting.id, on: hub.id) }
    }
  }
}

/// The selected device: what it is, where it's reached, what it has, Revoke.
struct HubDeviceInspector: View {
  let hub: HubItem
  let device: VaultHubDevice
  @Environment(AppModel.self) private var app
  @Environment(\.pushedDetail) private var pushed
  @State private var confirmsRevoke = false

  var body: some View {
    let isThisDevice = device.id == app.hubs.identity?.id
    if !pushed {
      InspectorHeader(device.name, meta: [HubPlatform.name(device.platform), device.isOnline ? "Online" : "Offline", "on \(hub.name)"], systemImage: HubPlatform.systemImage(device.platform)) {}
    }
    KitSection("Device", meta: [device.isApproved ? "approved" : "not approved", isThisDevice ? "this \(ThisDevice.word)" : ""].filter { !$0.isEmpty }, systemImage: HubPlatform.systemImage(device.platform), hue: .purple) {
      InspectorRow("System", value: [device.os, device.arch].compactMap { $0 }.joined(separator: " · ").ifEmpty(HubPlatform.name(device.platform)), copyable: false)
      if let parent = device.parent { InspectorRow("Runs on", value: parent, copyable: false) }
      InspectorRow("Hub", value: device.isOnline ? "Online" : device.lastSeen.map { "Seen \(RelativeTime.day($0))" } ?? "Offline", copyable: false)
      if let network = device.isNetworkOnline { InspectorRow("Hub Network", value: network ? "Online" : "Offline", copyable: false) }
      InspectorRow("Device id", copyText: device.id) { Text(ShortKey.fingerprint(device.id)).kitFont(.mono) }
    }
    if let ssh = device.ssh {
      let host = app.vault.hubHosts.first { $0.hub?.deviceID == device.id && $0.hub?.hubID == hub.id }
      KitSection("SSH via Hub", meta: [device.address ?? "no address yet", "port \(ssh.port)"], systemImage: "server.rack", hue: .teal) {
        if let address = device.address { InspectorRow("Address", copyText: address) { Text(address).kitFont(.mono) } }
        if let user = ssh.user { InspectorRow("User", value: user) }
        if let key = ssh.hostKey {
          InspectorRow("Host key", copyText: key) { Text(ShortKey.fingerprint(VaultIdentity.fingerprint(keyLine: key))).kitFont(.mono) }
          InspectorRow("Signed by", value: "the device’s own key", copyable: false)
        } else {
          InspectorRow("Host key", value: "not signed: each app asks the first time", copyable: false)
        }
        if let host {
          LinkRow(title: host.displayName, subtitle: "SSH host in Shell, Database and Code", systemImage: "server.rack") {
            app.selectedHost = host.id
            app.selection = .hosts
          }
        }
      }
    }
    if !device.tools.isEmpty || !device.services.isEmpty {
      KitSection("Offers", meta: [Self.count(device.tools.count, "tool"), Self.count(device.services.count, "service")], systemImage: "hammer", hue: .gray) {
        ForEach(device.tools.sorted(by: { $0.key < $1.key }), id: \.key) { name, value in
          InspectorRow(name.capitalized, value: value, copyable: false)
        }
        ForEach(device.services, id: \.self) { service in
          InspectorRow("Service", value: service, copyable: false)
        }
      }
    }
    if hub.isOwner && !isThisDevice {
      Button(role: .destructive) { confirmsRevoke = true } label: {
        Text("Revoke \(device.name)…").frame(maxWidth: .infinity)
      }
      .buttonStyle(.kit)
        .kitConfirmation(
          "Revoke \(device.name)?", isPresented: $confirmsRevoke,
          message: "It can’t connect to \(hub.name) again, its services’ keys stop working, Hub Network drops it, and its host goes from every app. For a lost or sold device.",
          systemImage: "xmark.shield", confirm: "Revoke"
        ) {
          Task { await app.hubs.revoke(device.id, on: hub.id) }
        }
    }
  }

  /// "1 tool", "2 tools".
  private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

/// Adding a Hub: its address and a name. Nothing connects before Connect.
struct AddHubSheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss
  @State private var url = ""
  @State private var name = ""
  @State private var error: String?

  var body: some View {
    let playground = VaultHubServer(url: HubDirectory.normalized(url) ?? url).isPlayground
    KitSheet(
      title: "Add Hub", meta: "A Hub you run: on a Mac, a home server or a VPS. This \(ThisDevice.word) connects to it while a v57 app is open.",
      systemImage: "point.3.connected.trianglepath.dotted", hue: .purple, width: 560
    ) {
      VStack(spacing: 12) {
        FieldRow {
          LabeledField("Address") { TextField("wss://hub.example.com", text: $url).kitField(mono: true) }
        }
        FieldRow {
          LabeledField("Name") { TextField("Home Hub", text: $name).kitField() }
        }
      }
      if playground {
        Banner(
          "hub.v57.dev is a public playground.",
          message: "For trying Hub out, with no accounts, guarantees or retention. Your vault stays encrypted, but don’t rely on it.",
          systemImage: "exclamationmark.triangle", hue: .orange)
      } else {
        Banner(
          "Hub never sees your vault.",
          message: "It learns this \(ThisDevice.word)’s name, keys and when it’s online, to introduce your devices. An owner approves this \(ThisDevice.word) with its safety code.",
          systemImage: "shield", hue: .blue)
      }
      if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Connect") { add() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(url.isEmpty)
    }
  }

  private func add() {
    do {
      try app.hubs.add(url: url, name: name)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// How the screens name a Hub's status.
enum HubStatusText {
  static func title(_ status: HubItem.Status) -> String {
    switch status {
    case .off: "off here"
    case .connecting: "connecting"
    case .connected: "connected"
    case .needsApproval: "waiting for approval"
    case .wrongHub: "different server"
    case .revoked: "revoked"
    case .offline: "offline"
    }
  }

  static func line(_ hub: HubItem) -> String {
    switch hub.status {
    case .off: "This device doesn’t connect"
    case .connecting: "Connecting…"
    case .connected: hub.isOwner ? "Connected as an owner" : "Connected"
    case .needsApproval: "Connected, waiting for an owner to approve this device"
    case .wrongHub: "A different server answers at this address than the Hub you added. Not connected."
    case .revoked: "This \(ThisDevice.word) was revoked on the Hub. Not connected."
    case .offline: "Can’t reach the Hub; trying again"
    }
  }

  static func hue(_ status: HubItem.Status) -> Hue {
    switch status {
    case .connected: .green
    case .connecting, .needsApproval: .orange
    case .wrongHub, .revoked: .red
    case .off, .offline: .gray
    }
  }
}

/// A Hub platform's name and glyph.
enum HubPlatform {
  static func name(_ platform: String) -> String {
    switch platform {
    case "macos": "macOS"
    case "ios": "iOS"
    case "ipados": "iPadOS"
    case "visionos": "visionOS"
    case "linux": "Linux"
    case "windows": "Windows"
    case "android": "Android"
    default: "Device"
    }
  }

  static func systemImage(_ platform: String) -> String {
    switch platform {
    case "macos": "desktopcomputer"
    case "ios": "iphone"
    case "ipados", "android": "ipad"
    case "visionos": "visionpro"
    case "windows": "pc"
    case "linux": "server.rack"
    default: "questionmark.square.dashed"
    }
  }
}

extension String {
  fileprivate func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
