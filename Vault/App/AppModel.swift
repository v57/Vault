import ComponentKit
import Foundation
import Observation
import SwiftUI
import VaultKit

/// What the sidebar opens.
nonisolated enum SidebarItem: Hashable, Sendable {
  case logins, cards, notes, hosts, databases, projects
  case folder(String)
  case location(String)
  case devices, recoveryKey

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
    case "recovery-key": self = .recoveryKey
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
  case scanInvite

  var id: Self { self }
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

  var selection: SidebarItem? = .logins
  var sheet: AppSheet?
  /// Which login, host… each list has selected.
  var selectedLogin: String?
  var selectedHost: String?
  var selectedDatabase: String?
  var selectedProject: String?
  var selectedPerson: String?
  /// When iCloud last synced, as this app saw it.
  var lastSync: Date?

  init(vault: Vault, isDemo: Bool, folders: FolderLibrary, remotes: any RemoteService, sharing: any SharingService,
       recovery: any RecoveryService) {
    self.vault = vault
    self.isDemo = isDemo
    self.folders = folders
    self.remotes = remotes
    self.sharing = sharing
    self.recovery = recovery
  }

  /// The model for this launch: the demo vault with `--demo`, the shared store otherwise.
  static func launch() -> AppModel {
    let model: AppModel
    if LaunchOptions.flag("--demo") {
      model = DemoVault.make()
    } else {
      let vault = Vault.shared
      // iCloud sync is on: turning iCloud on for the Mac was the consent. Remotes and Hub start off.
      if UserDefaults.standard.object(forKey: "iCloudSync") as? Bool ?? true { vault.startSync() }
      model = AppModel(
        vault: vault, isDemo: false, folders: FolderLibrary(vault: vault, sync: NoFolderSync()),
        remotes: RemoteLibrary(vault: vault), sharing: PeopleLibrary(vault: vault), recovery: UnavailableRecovery())
      model.lastSync = vault.sync?.isRunning == true ? .now : nil
    }
    model.applyLaunchOptions()
    return model
  }

  /// `--select <item>`, `--login <title>`, `--host <name>`, `--person <name>`, `--sheet <name>` (DEBUG and screenshots).
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
    default: break
    }
    if selectedLogin == nil { selectedLogin = vault.logins.first { $0.favorite }?.id ?? vault.logins.first?.id }
    if selectedHost == nil { selectedHost = vault.hosts.first?.id }
    if selectedDatabase == nil { selectedDatabase = vault.databases.first?.id }
    if selectedPerson == nil { selectedPerson = sharing.people.first?.id }
  }

  /// Folder and location arguments name them; the selection holds their ids.
  private func resolve(_ item: SidebarItem) -> SidebarItem {
    switch item {
    case .folder(let name): .folder(folders.folders.first { $0.name == name }?.id ?? name)
    case .location(let name): .location(remotes.locations.first { $0.name == name }?.id ?? name)
    default: item
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
  nonisolated(unsafe) static var arguments = ProcessInfo.processInfo.arguments

  static func flag(_ name: String) -> Bool { arguments.contains(name) }

  /// `--dark` or `--light` (design checks); nil follows the system.
  static var colorScheme: ColorScheme? { flag("--dark") ? .dark : flag("--light") ? .light : nil }

  static func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
}
