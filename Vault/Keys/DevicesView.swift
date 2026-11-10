import ComponentKit
import SwiftUI
import VaultHub
import VaultKit
import VaultUI

/// Board 07: this device's key (it never leaves the Secure Enclave), your other devices (their vault keys arrive
/// through iCloud Keychain), your identity for sharing, and the people you share with; the selected person's
/// safety code in the inspector.
struct DevicesView: View {
  @Environment(AppModel.self) private var app
  @State private var search = ""
  @State private var identityError: String?
  @State private var pushed: String?
  /// The device being renamed (this one too).
  @State private var renaming: VaultDeviceKey?
  /// The device being taken out through Lost Device.
  @State private var lost: VaultDeviceKey?
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    @Bindable var app = app
    let people = app.sharing.people
    ListAndInspector(name: "devices") {
      KitList(selection: Binding(get: { app.selectedPerson }, set: { id in
        app.selectedPerson = id
        if idiom == .phone { pushed = id }
      })) {
        if let device = app.thisDevice {
          KitSection(
            idiom == .phone ? "This \(ThisDevice.word)" : "\(device.deviceName)",
            meta: idiom == .phone ? [ThisDevice.system, "Secure Enclave"] : [String(localized: "This \(ThisDevice.word)"), ThisDevice.system, "Secure Enclave"],
            systemImage: DeviceGlyph.systemImage(device)
          ) {
            InspectorRow("Name", copyText: device.deviceName) {
              HStack {
                Text(device.deviceName).lineLimit(1)
                Spacer()
                if !app.isDemo { Button("Rename…") { renaming = device }.buttonStyle(.kit).controlSize(.small) }
              }
            }
            InspectorRow("SSH key", copyText: device.publicKey) {
              Text(idiom == .phone ? ShortKey.fingerprint(device.fingerprint) : "ecdsa-sha2-nistp256 \(ShortKey.fingerprint(device.fingerprint))")
                .kitFont(.mono).lineLimit(1)
            }
            InspectorRow("Never leaves", value: idiom == .phone ? String(localized: "this \(ThisDevice.word)") : String(localized: "this \(ThisDevice.word)’s Secure Enclave"), copyable: false)
            if idiom != .phone { InspectorRow("Used by", value: "Shell, Database, Vault", copyable: false) }
            if !app.isDemo {
              InspectorRow(
                "Signs",
                value: VaultIdentity.asksForPresence
                  ? "After you confirm it’s you; a yes lasts 15 minutes in each app"
                  : "With nothing asked: this key was made before keys could ask",
                copyable: false)
            }
          }
        }
        KitSection(
          "Your other devices", meta: [String(localized: "\(app.otherDevices.count) devices"), idiom == .phone ? String(localized: "keys through iCloud Keychain") : String(localized: "vault keys arrive through iCloud Keychain")],
          systemImage: "laptopcomputer", hue: .gray
        ) {
          ForEach(app.otherDevices) { device in
            let seen = device.seen.map { RelativeTime.seen($0) } ?? ""
            SidebarRow(
              "\(device.deviceName)",
              subtitle: idiom == .phone
                ? "\(seen)"
                : "\(device.platform == "iOS" ? "iPadOS" : "macOS") · key \(ShortKey.fingerprint(device.fingerprint)) · \(seen)"
            ) {
              RowTile(systemImage: DeviceGlyph.systemImage(device))
            } trailing: {
              Chip("Up to date", hue: .green).controlSize(.small)
            }
            .kitContextMenu(if: !app.isDemo) {
              Button("Rename…") { renaming = device }
              Button("Lost Device…") { lost = device }
                .kitMenuPreview(VaultLostDeviceSheet.menuPreview(device.deviceName))
            }
          }
          ForEach(app.deviceVault.revokedDevices) { device in
            SidebarRow("\(device.name)", subtitle: "Taken out through Lost Device") {
              RowTile(systemImage: "exclamationmark.shield")
            } trailing: {
              Chip("Not trusted", hue: .red).controlSize(.small)
            }
            .kitContextMenu(if: !app.isDemo) {
              Button("Trust Again") { Vaults.shared.trustAgain(device) }
                .kitMenuPreview("Lets \(device.name) back in, the next time a v57 app runs on it.")
            }
          }
          ForEach(app.hubs.hubs.filter { $0.status == .connected }) { hub in
            HubDevicesRow(hub: hub)
          }
          LinkRow(title: String(localized: "A device without iCloud Keychain"), subtitle: String(localized: "Linux, Windows or Android: it scans an invite from this \(ThisDevice.word)"), systemImage: "qrcode") {
            app.sheet = .addDevice
          }
        } accessory: {
          // On iPhone Add Device is in the bottom bar.
          if idiom != .phone { Button("Add Device…") { app.sheet = .addDevice }.buttonStyle(.kit).controlSize(.small) }
        }
        #if os(macOS)
          // Writes the real ~/.ssh, so never in the demo; devices are Personal's.
          if !app.isDemo, app.vault.isPersonal { ThisMacSSHSection() }
        #endif
        if idiom != .phone { identitySection }
        KitSection(
          "People", meta: [String(localized: "\(people.filter { $0.status == .verified }.count) verified"), String(localized: "\(people.filter { $0.status != .verified }.count) waiting")],
          systemImage: "person.2", hue: .blue
        ) {
          ForEach(people) { person in
            SidebarRow(value: person.id, person.name, subtitle: personLine(person)) {
              Avatar(name: person.name, letters: LetterTile.initials(person.name), size: KitMetrics.rowTile(.pad) - 2)
            } trailing: {
              Chip(person.status == .verified ? "Verified" : "Waiting", hue: person.status == .verified ? .green : .orange).controlSize(.small)
            }
          }
          if people.isEmpty { Text("No one yet. Invite someone to share a folder or logins.").kitFont(.caption).padding(8) }
        } accessory: {
          if idiom == .phone {
            Button("Invite", systemImage: "plus") { app.sheet = .invite }.buttonStyle(.kitIcon)
          } else {
            Button("Invite…") { app.sheet = .invite }.buttonStyle(.kit).controlSize(.small)
          }
        }
        if idiom == .phone { identitySection }
      }
      .padding(.top, KitMetrics.gutter)
    } inspector: {
      if let person = people.first(where: { $0.id == app.selectedPerson }) {
        PersonInspector(person: person)
      } else {
        EmptyState(systemImage: "person.2", title: "No One Selected", message: "Pick someone to compare your safety code.")
      }
    }
    .kitToolbar("Devices & People", meta: [String(localized: "\(app.devices.count) devices"), String(localized: "\(people.count) people"), idiom == .phone ? "" : String(localized: "keys in iCloud Keychain")], systemImage: "checkmark.shield", hue: .green) {
      if idiom == .phone {
        Button("Invite", systemImage: "person.badge.plus") { app.sheet = .invite }.buttonStyle(.kitRound)
      } else {
        ToolGroup {
          Button("Add Device", systemImage: "qrcode") { app.sheet = .addDevice }
          Button("Invite", systemImage: "person.badge.plus") { app.sheet = .invite }
        }
        ToolbarSearch(text: $search, prompt: "Search")
      }
    }
    .phoneBottomBar(prompt: "Search", search: $search) {
      Button("Add Device", systemImage: "qrcode") { app.sheet = .addDevice }
    }
    .kitSheet(item: $renaming) { device in VaultDeviceNameSheet(vault: app.deviceVault, device: device) }
    .kitSheet(item: $lost) { device in
      VaultLostDeviceSheet(device: device, actions: LostDeviceActions.make(for: device, app: app))
    }
    .onAppear { if idiom == .phone, LaunchOptions.pushes { pushed = app.selectedPerson } }
    .navigationDestination(item: $pushed) { id in
      if let person = people.first(where: { $0.id == id }) {
        PushedDetail(title: person.name, meta: [person.status == .verified ? String(localized: "Verified") : String(localized: "Waiting"), PersonItem.sharesLine(person)]) {
          Avatar(name: person.name, letters: LetterTile.initials(person.name), size: 30)
        } content: {
          PersonInspector(person: person)
        } trailing: {
          EmptyView()
        } actions: {
          Button("Share…", systemImage: "person.badge.plus") { if let folder = app.folders.folders.first { app.sheet = .share(folder.id) } }
        }
      }
    }
  }

  @ViewBuilder
  private var identitySection: some View {
    if let identity = app.sharing.identity {
      KitSection("Your identity", meta: ["X25519 + Ed25519", String(localized: "on all your Apple devices")], systemImage: "person", hue: .purple) {
        InspectorRow("Signing", copyText: identity.text) { Text(identity.fingerprint).kitFont(.mono) }
        InspectorRow("Key wrapping", value: identity.agreementFingerprint, copyable: false)
        InspectorRow("Kept in", value: "iCloud Keychain, apart from the device keys", copyable: false)
      } accessory: {
        if idiom != .phone { Button("Show QR Code") { app.sheet = .invite }.buttonStyle(.kit).controlSize(.small) }
      }
    } else {
      KitSection("Your identity", meta: String(localized: "made when you first share"), systemImage: "person", hue: .purple) {
        Text("Sharing uses a key pair of its own, kept in iCloud Keychain apart from your devices’ SSH keys.")
          .kitFont(.caption).padding(8)
        if let identityError { Text(identityError).kitFont(.caption).foregroundStyle(Hue.red.text).padding(.horizontal, 8) }
      } accessory: {
        Button("Set Up Sharing") {
          do { _ = try VaultPersonalIdentity.current() } catch { identityError = error.localizedDescription }
          app.vault.reload(force: true)
        }
        .buttonStyle(.kit).controlSize(.small)
      }
    }
  }

  private func personLine(_ person: PersonItem) -> String {
    let folders = app.folders.folders.filter { person.record.roles[$0.id] != nil }.map(\.name)
    if person.status == .verified {
      let verified = String(localized: "verified \(person.record.verified.map { RelativeTime.day($0) } ?? "")")
      return (folders.first ?? "") + " · " + verified
    }
    return String(localized: "Invited \(person.record.created.map { RelativeTime.day($0) } ?? "") · waiting for the safety code")
  }
}

/// The selected person: the safety code you compare, what you share with them, their keys, Share and Remove.
private struct PersonInspector: View {
  let person: PersonItem
  @Environment(AppModel.self) private var app
  @Environment(\.pushedDetail) private var pushed
  @State private var confirmsRemove = false

  var body: some View {
    let first = person.name.split(separator: " ").first.map(String.init) ?? person.name
    let shared = app.folders.folders.filter { person.record.roles[$0.id] != nil }
    let otherShares = person.record.roles.filter { key, _ in !shared.contains { $0.id == key } }
    if !pushed {
      RichHeader(Text(person.name), size: .title) {
        Avatar(name: person.name, letters: LetterTile.initials(person.name), size: 30)
      } meta: {
        MetaLine(person.status == .verified ? String(localized: "Verified \(person.record.verified.map { RelativeTime.day($0) } ?? "")") : String(localized: "Not verified yet"), PersonItem.sharesLine(person))
      } accessory: {
        EmptyView()
      }
      .padding(.horizontal, 6)
    }
    if let code = app.sharing.safetyCode(with: person) {
      KitSection(
        "Safety code", meta: person.status == .verified ? [String(localized: "matched on \(person.record.verified.map { RelativeTime.day($0) } ?? "")"), String(localized: "in person")] : [String(localized: "compare it with \(first)")],
        systemImage: "checkmark.shield", hue: person.status == .verified ? .green : .orange
      ) {
        VStack(alignment: .leading, spacing: 8) {
          KitSafetyCode(groups: code)
          Text("The same code shows on \(first)’s devices. A different one would mean a swapped key.").kitFont(.caption)
          if person.status != .verified {
            Button("It Matches") { app.sharing.verify(person.id) }.buttonStyle(.kitPrimary).controlSize(.small)
          }
        }
        .padding(8)
      }
    }
    KitSection("Shared with \(first)", meta: [String(localized: "\(shared.count) folder"), otherShares.isEmpty ? "" : String(localized: "\(otherShares.count) login collection")], systemImage: "folder", hue: .teal) {
      ForEach(shared) { folder in
        InspectorRow(
          "\(folder.name)",
          value: person.record.roles[folder.id] == .readOnly
            ? String(localized: "Read-only") : String(localized: "Read-write"),
          copyable: false)
      }
      ForEach(otherShares.sorted(by: { $0.key < $1.key }), id: \.key) { _, role in
        InspectorRow("Design logins", value: role == .readOnly ? String(localized: "Read-only") : String(localized: "Read-write"), copyable: false)
      }
    }
    if let identity = person.identity {
      KitSection("Keys", meta: String(localized: "added by QR code"), systemImage: "key", hue: .gray) {
        InspectorRow("Signing", copyText: identity.text) { Text(identity.fingerprint).kitFont(.mono) }
        InspectorRow("Key wrapping", value: identity.agreementFingerprint, copyable: false)
      }
    }
    if pushed {
      Button("Remove \(first)…", role: .destructive) { confirmsRemove = true }.buttonStyle(.kit).frame(maxWidth: .infinity)
    } else {
      ActionBar {
        Button("Share…") { if let folder = app.folders.folders.first { app.sheet = .share(folder.id) } }
        Button("Remove…", role: .destructive) { confirmsRemove = true }
      }
    }
    Text("Removing \(first) rotates the keys of what you share, so \(first) can’t read anything new. What \(first) already downloaded stays theirs.")
      .kitFont(.caption)
      .padding(.horizontal, 10)
      .kitConfirmation(
        "Remove \(person.name)?", isPresented: $confirmsRemove,
        message: "Folders shared with \(first) get new keys. What they already downloaded stays theirs.", systemImage: "person.badge.minus",
        confirm: "Remove"
      ) {
        app.sharing.remove(person.id)
      }
  }
}

/// The recovery key in the sidebar: what it is and its state; Settings creates it.
struct RecoveryKeyScreen: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    ScrollView {
      RecoveryKeyPane().padding(24).frame(maxWidth: 640)
    }
    .frame(maxWidth: .infinity)
    .kitPane(.content)
    .kitToolbar("Recovery Key", meta: [app.recovery.isOn ? String(localized: "On") : String(localized: "Off"), String(localized: "optional, never nagged")], systemImage: "key", hue: .orange) {}
  }
}

/// A Hub's devices beside the iCloud ones: how many, that other platforms join too, who waits to join; opens the Hub.
private struct HubDevicesRow: View {
  let hub: HubItem
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let waiting = hub.pending.count + hub.waitingElsewhere.count
    let firstWaiting = hub.pending.first?.name ?? hub.waitingElsewhere.first?.name
    Button {
      app.selection = .hub
    } label: {
      SidebarRow(
        "On \(hub.name)",
        subtitle: "\(subtitle(waiting: waiting, firstWaiting: firstWaiting))"
      ) {
        RowTile(systemImage: "point.3.connected.trianglepath.dotted")
      } trailing: {
        HStack(spacing: 6) {
          if waiting > 0 { Chip(idiom == .phone ? "Waiting" : "\(waiting) waiting", hue: .orange).controlSize(.small) }
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.kitTertiary)
        }
      }
    }
    .buttonStyle(.plain)
  }

  /// "3 devices, Linux, Windows and Android too · Pixel waits to join", localized here since it's joined.
  private func subtitle(waiting: Int, firstWaiting: String?) -> String {
    let count = hub.members.count
    let waits: String? =
      if idiom != .phone {
        firstWaiting.map { String(localized: "\($0) waits to join") }
      } else if waiting == 0 {
        nil
      } else if waiting == 1 {
        String(localized: "1 waits to join")
      } else {
        String(localized: "\(waiting) wait to join")
      }
    return [
      idiom == .phone
        ? String(localized: "\(count) devices") : String(localized: "\(count) devices, Linux, Windows and Android too"),
      waits,
    ].compactMap { $0 }.joined(separator: " · ")
  }
}

#if os(macOS)
  /// SSH from your devices: whether this Mac lets them in, and a way to Settings ▸ Remote, where every v57 app sets
  /// it (VaultUI's `VaultRemoteSettings`: the devices that can sign in, Remote Login, password login, other keys).
  private struct ThisMacSSHSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
      let host = app.vault.thisDeviceHost
      KitSection(
        "SSH from your devices", meta: host.map { [$0.hostname, $0.user] } ?? [String(localized: "off")], systemImage: "terminal",
        hue: .teal
      ) {
        LinkRow(
          title: String(localized: "Remote Settings"),
          subtitle: String(localized: "Let your iPhone and iPad in, pick which can sign in, and the other keys"), systemImage: "network"
        ) {
          UserDefaults.standard.set("Remote", forKey: "settings.pane")
          openSettings()
        }
      }
    }
  }
#endif

extension PersonItem {
  /// "shares 2 things", "shares 1 thing".
  static func sharesLine(_ person: PersonItem) -> String {
    let count = person.record.roles.count
    return count == 1 ? String(localized: "shares 1 thing") : String(localized: "shares \(count) things")
  }
}

extension View {
  /// The kit's context menu, only while it has items (none in the demo).
  @ViewBuilder fileprivate func kitContextMenu<Menu: View>(
    if hasItems: Bool, @ViewBuilder content: @escaping () -> Menu
  ) -> some View {
    if hasItems { kitContextMenu(content: content) } else { self }
  }
}
