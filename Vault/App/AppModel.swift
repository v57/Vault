import ComponentKit
import Foundation
import Observation
import SwiftUI
import VaultHub
import VaultKit

/// What the sidebar opens.
nonisolated enum SidebarItem: Hashable, Sendable {
  case logins, cards, notes, hosts, databases, projects
  case folder(String)
  case location(String)
  case devices, hub, recoveryKey
  /// Settings, pushed from the root list's bar on iPhone and iPad (the Mac has its Settings window).
  case settings

  /// The item a `--select` launch argument names: `logins`, `hosts`, `folder:<name>`, `location:<name>`…
  init?(argument: String) {
    switch argument {
    case "logins": self = .logins
    case "cards": self = .cards
    case "notes": self = .notes
    case "hosts": self = .hosts
    case "databases": self = .databases
    case "projects": self = .projects
    case "devices": self = .devices
    case "hub": self = .hub
    case "recovery-key": self = .recoveryKey
    case "settings": self = .settings
    default:
      if argument.hasPrefix("folder:") {
        self = .folder(String(argument.dropFirst(7)))
      } else if argument.hasPrefix("location:") {
        self = .location(String(argument.dropFirst(9)))
      } else {
        return nil
      }
    }
  }
}

/// A sheet over the main window.
enum AppSheet: Identifiable, Hashable {
  case newItem(NewItemKind)
  case addRemote
  case decrypt(String)
  case share(String)
  case invite
  case addDevice
  case addHub
  case scanInvite
  /// The AutoFill extension's sheet over the demo logins (`--sheet autofill`, demo runs only): the extension itself
  /// opens from Safari's suggestion and reads the shared store.
  case autoFillPreview

  var id: Self { self }

  /// A sheet the iPhone shows from the bottom, half height first (the Decrypt sheet); the rest open full height.
  var isBottomSheet: Bool {
    if case .decrypt = self { return true }
    return false
  }
}

/// What the New sheet makes.
enum NewItemKind: String, CaseIterable, Hashable, Identifiable {
  case login, card, note, host, database, remote, folder
  var id: String { rawValue }
}

/// The app: the vault (the shared store, or a demo one), the folders and the services that aren't built yet, the
/// window's selection and the sheet it shows.
@MainActor
@Observable
final class AppModel {
  let vault: Vault
  /// A demo vault in a temporary folder, with in-memory keys and secrets: screenshots and design checks, never the
  /// user's data.
  let isDemo: Bool
  let folders: FolderLibrary
  let remotes: any RemoteService
  let sharing: any SharingService
  let recovery: any RecoveryService
  /// The user's own Hubs (none until they add one).
  let hubs: any HubEngine

  /// What the sidebar opened; nothing at launch, so the main screen shows the welcome.
  var selection: SidebarItem?
  var sheet: AppSheet?
  /// Which login, host… each list has selected.
  var selectedLogin: String?
  var selectedHost: String?
  var selectedDatabase: String?
  var selectedProject: String?
  var selectedPerson: String?
  var selectedHubDevice: String?
  /// When iCloud last synced, as this app saw it.
  var lastSync: Date?

  init(vault: Vault, isDemo: Bool, folders: FolderLibrary, remotes: any RemoteService, sharing: any SharingService,
       recovery: any RecoveryService, hubs: any HubEngine) {
    self.vault = vault
    self.isDemo = isDemo
    self.folders = folders
    self.remotes = remotes
    self.sharing = sharing
    self.recovery = recovery
    self.hubs = hubs
  }

  /// The model for this launch: the demo vault with `--demo`, the shared store otherwise.
  static func launch() -> AppModel {
    FilePreviewPage.removeLeftoverCopies()
    let model: AppModel
    if LaunchOptions.flag("--demo") {
      model = DemoVault.make()
    } else {
      let vault = Vault.shared
      // iCloud sync is on: turning iCloud on for the Mac was the consent. Remotes and Hub start off: a Hub connects
      // only once the user adds it and turns it on for this device.
      if UserDefaults.standard.object(forKey: "iCloudSync") as? Bool ?? true { vault.startSync() }
      let hubs = HubDirectory(vault: vault)
      hubs.start()
      #if DEBUG
        // `--add-hub <ws address>`: adds a Hub and connects this device to it, for device tests without typing
        if let address = LaunchOptions.value("--add-hub") { _ = try? hubs.add(url: address) }
      #endif
      model = AppModel(
        vault: vault, isDemo: false, folders: FolderLibrary(vault: vault, sync: NoFolderSync()),
        remotes: RemoteLibrary(vault: vault), sharing: PeopleLibrary(vault: vault), recovery: UnavailableRecovery(),
        hubs: LiveHubs(directory: hubs))
      model.lastSync = vault.sync?.isRunning == true ? .now : nil
    }
    model.applyLaunchOptions()
    return model
  }

  /// `--select <item>`, `--login <title>`, `--host <name>`, `--person <name>`, `--sheet <name>` (new-login, add-remote, decrypt, share, scan, autofill; DEBUG and screenshots).
  func applyLaunchOptions() {
    if let item = LaunchOptions.value("--select").flatMap(SidebarItem.init(argument:)) {
      selection = resolve(item)
    }
    if let title = LaunchOptions.value("--login") {
      selectedLogin = vault.logins.first { $0.title == title }?.id
    }
    if let name = LaunchOptions.value("--host") {
      selectedHost = vault.hosts.first { $0.displayName == name }?.id
    }
    if let name = LaunchOptions.value("--person") {
      selectedPerson = sharing.people.first { $0.name == name }?.id
    }
    switch LaunchOptions.value("--sheet") {
    case "new-login": sheet = .newItem(.login)
    case "add-remote": sheet = .addRemote
    case "decrypt": if case .folder(let id) = selection { sheet = .decrypt(id) }
    case "share": if case .folder(let id) = selection { sheet = .share(id) }
    case "scan": sheet = .scanInvite
    case "add-hub": sheet = .addHub
    case "autofill": if isDemo { sheet = .autoFillPreview }
    default: break
    }
    if selectedLogin == nil { selectedLogin = vault.logins.first { $0.favorite }?.id ?? vault.logins.first?.id }
    if selectedHost == nil { selectedHost = vault.hosts.first?.id }
    if selectedDatabase == nil { selectedDatabase = vault.databases.first?.id }
    if selectedPerson == nil { selectedPerson = sharing.people.first?.id }
    if let name = LaunchOptions.value("--hub-device") {
      selectedHubDevice = hubs.hubs.flatMap(\.devices).first { $0.name == name }?.id
    }
    if selectedHubDevice == nil {
      selectedHubDevice = hubs.hubs.flatMap(\.members).first { $0.id != hubs.identity?.id }?.id
    }
  }

  /// Folder and location arguments name them; the selection holds their ids.
  private func resolve(_ item: SidebarItem) -> SidebarItem {
    switch item {
    case .folder(let name): .folder(folders.folders.first { $0.name == name }?.id ?? name)
    case .location(let name): .location(remotes.locations.first { $0.name == name }?.id ?? name)
    default: item
    }
  }

  /// The system’s background turn (iPhone and iPad): sync iCloud and check the remotes folders use, then ask for
  /// the next turn while remote checks are on.
  func refreshInBackground() async {
    syncNow()
    await folders.syncAll()
    scheduleBackgroundRefresh()
  }

  /// Asks the system for the next background turn, as often as Settings' "Check remotes" says.
  func scheduleBackgroundRefresh() {
    let minutes = UserDefaults.standard.object(forKey: "remoteCheckMinutes") as? Int ?? 5
    if folders.folders.contains(where: { $0.record.remoteID != nil }) {
      VaultBackgroundRefresh.schedule(after: TimeInterval(max(15, minutes) * 60))
    } else {
      VaultBackgroundRefresh.cancel()
    }
  }

  func syncNow() {
    vault.sync?.syncNow()
    folders.checkRemotes()
    lastSync = .now
  }

  // MARK: Counts

  var itemCount: Int {
    vault.logins.count + vault.cards.count + notes.count + vault.hosts.count + vault.databases.count
      + vault.projects.count
  }

  var notes: [VaultNote] { (try? vault.store?.records(VaultNote.self)) ?? [] }

  /// Devices that published a key: this one and the others.
  var devices: [VaultDeviceKey] { vault.deviceKeys.filter { $0.id == vault.deviceID } + otherDevices }

  var thisDevice: VaultDeviceKey? { vault.deviceKeys.first { $0.id == vault.deviceID } }

  var otherDevices: [VaultDeviceKey] { vault.deviceKeys.filter { $0.id != vault.deviceID } }

  /// The name of the device that wrote a change.
  func deviceName(_ id: String) -> String {
    vault.deviceKeys.first { $0.id == id }?.deviceName ?? (id == vault.deviceID ? KitDevice.name : "Another device")
  }

  /// "iCloud · 3 devices", the sidebar's status.
  var cloudSummary: String {
    vault.sync?.isRunning == true || isDemo ? "iCloud · \(devices.count) devices" : "On this \(KitDevice.name)"
  }

  var syncedLine: String {
    guard let lastSync else { return isDemo ? "synced 1 min ago" : "not synced yet" }
    return "synced \(RelativeTime.short(lastSync))"
  }
}

/// Short relative times the design writes ("1 min ago", "3 min ago", "just now").
enum RelativeTime {
  static func short(_ date: Date, now: Date = .now) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 45 { return "just now" }
    if seconds < 3600 { return "\(max(1, seconds / 60)) min ago" }
    if seconds < 86400 { return "\(seconds / 3600) hr ago" }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }

  /// "Oct 12", "Today", "Yesterday".
  static func day(_ date: Date, now: Date = .now) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
      return "Yesterday"
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}

/// Launch arguments (`--demo`, `--select logins`…), read once.
enum LaunchOptions {
  /// `--push` (iPhone): the screen also pushes its selected item (a login's, host's or person's page).
  static var pushes: Bool { flag("--push") }

  nonisolated(unsafe) static var arguments = ProcessInfo.processInfo.arguments

  static func flag(_ name: String) -> Bool { arguments.contains(name) }

  /// `--dark` or `--light` (design checks); nil follows the system.
  static var colorScheme: ColorScheme? { flag("--dark") ? .dark : flag("--light") ? .light : nil }

  static func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
}
