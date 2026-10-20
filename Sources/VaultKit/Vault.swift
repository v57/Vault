import Foundation
import Observation

/// The vault as SwiftUI sees it: the shared records, kept current as any app (or CloudKit) changes them.
///
/// One per process (`Vault.shared`). It opens the store in the app group container, reloads when the store's
/// change notification arrives, and starts iCloud sync (`CloudSync`) when the app has an iCloud account:
/// every app syncs on its own, and the one that made a change sends it.
@MainActor
@Observable
public final class Vault {
  public static let shared = Vault()

  public private(set) var projects: [VaultProject] = []
  public private(set) var projectGroups: [VaultProjectGroup] = []
  /// The projects in their groups, on every device.
  public private(set) var projectTree = VaultProjectTree(projects: [], groups: [])
  public private(set) var hosts: [VaultHost] = []
  public private(set) var databases: [VaultDatabase] = []
  public private(set) var deviceKeys: [VaultDeviceKey] = []
  /// Accepted SSH host keys, by host.
  public private(set) var knownHosts: [VaultKnownHost] = []
  /// Logins, by title.
  public private(set) var logins: [VaultLogin] = []
  public private(set) var cards: [VaultCard] = []
  /// Encrypted and synced folders.
  public private(set) var folders: [VaultFolder] = []
  /// Remotes folders sync through.
  public private(set) var remotes: [VaultRemote] = []
  /// People the user shares with, by name.
  public private(set) var people: [VaultPerson] = []
  /// Why the store couldn't open or save, for the UI.
  public var error: String?

  /// The store, nil when it couldn't open.
  @ObservationIgnored public let store: VaultStore?
  @ObservationIgnored public private(set) var sync: CloudSync?
  @ObservationIgnored private var observer: VaultChangeObserver?
  @ObservationIgnored private var loadedRevision: Int64 = -1
  @ObservationIgnored var dumpObserver: VaultChangeObserver?
  @ObservationIgnored var commandObserver: VaultChangeObserver?
  @ObservationIgnored private var iconFinder: (find: @Sendable (URL) -> URL?, thumbnail: @Sendable (URL) -> Data?)?
  /// The projects whose folders `iconFinder` has looked at in this process.
  @ObservationIgnored private var iconsLookedAt: Set<String> = []
  @ObservationIgnored private var iconTask: Task<Void, Never>?

  /// Opens the shared store (or a given one, for tests and previews).
  public init(store: VaultStore? = nil) {
    if let store {
      self.store = store
    } else {
      self.store = VaultStore.shared
      if self.store == nil { self.error = "The shared store couldn’t be opened." }
    }
    observer = VaultChangeObserver { [weak self] in
      Task { @MainActor in self?.reload() }
    }
    reload(force: true)
    #if DEBUG && os(macOS)
      listenForDumpRequests()
    #endif
  }

  /// Starts iCloud sync for this app: call it once from the App's init. Does nothing without an iCloud account
  /// or the CloudKit entitlement.
  public func startSync() {
    guard sync == nil, let store else { return }
    sync = CloudSync(store: store) { [weak self] in
      Task { @MainActor in self?.reload() }
    }
    sync?.start()
  }

  /// Keeps the icons of this device's projects current (`VaultStore.refreshProjectIcons`), in the background: looks
  /// at every project's folder now, and at each project that arrives later. Apps that can find icons call it once at
  /// launch with Code's `ProjectIcon.find` and `ProjectIcon.thumbnail`.
  public func findProjectIcons(
    with find: @escaping @Sendable (URL) -> URL?, thumbnail: @escaping @Sendable (URL) -> Data?
  ) {
    iconFinder = (find, thumbnail)
    lookForIcons()
  }

  private func lookForIcons() {
    guard let store, let finder = iconFinder, iconTask == nil else { return }
    let ids = Set(localProjects.map(\.id)).subtracting(iconsLookedAt)
    guard !ids.isEmpty else { return }
    iconsLookedAt.formUnion(ids)
    iconTask = Task.detached(priority: .utility) { [weak self] in
      try? store.refreshProjectIcons(ids: ids, find: finder.find, thumbnail: finder.thumbnail)
      await self?.iconsFound()
    }
  }

  /// Looks again for projects that arrived while the last look ran.
  private func iconsFound() {
    iconTask = nil
    lookForIcons()
  }

  /// Re-reads the records if the store changed since the last read.
  public func reload(force: Bool = false) {
    guard let store else { return }
    let revision = store.revision
    guard force || revision != loadedRevision else { return }
    loadedRevision = revision
    do {
      projects = try store.records(VaultProject.self).sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      projectGroups = try store.records(VaultProjectGroup.self)
      projectTree = VaultProjectTree(projects: projects, groups: projectGroups)
      hosts = try store.records(VaultHost.self).sorted { ($0.order, $0.displayName) < ($1.order, $1.displayName) }
      databases = try store.records(VaultDatabase.self).sorted { ($0.order, $0.name) < ($1.order, $1.name) }
      deviceKeys = try store.records(VaultDeviceKey.self).sorted { $0.deviceName < $1.deviceName }
      knownHosts = try store.records(VaultKnownHost.self).sorted { ($0.host, $0.port) < ($1.host, $1.port) }
      logins = try store.records(VaultLogin.self).sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      folders = try store.records(VaultFolder.self).sorted {
        ($0.order, $0.name.localizedLowercase) < ($1.order, $1.name.localizedLowercase)
      }
      remotes = try store.records(VaultRemote.self).sorted {
        ($0.order, $0.displayName.localizedLowercase) < ($1.order, $1.displayName.localizedLowercase)
      }
      people = try store.records(VaultPerson.self).sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      cards = try store.records(VaultCard.self).sorted {
        ($0.order, $0.title.localizedLowercase) < ($1.order, $1.title.localizedLowercase)
      }
    } catch {
      self.error = error.localizedDescription
    }
    lookForIcons()
  }

  /// Saves a record, reporting failures in `error`.
  public func save<Record: VaultRecord>(_ record: Record) {
    perform { try $0.save(record) }
  }

  public func delete<Record: VaultRecord>(_ record: Record) {
    perform { try $0.delete(id: record.id) }
  }

  /// Runs a change on the store and reloads.
  public func perform(_ change: (VaultStore) throws -> Void) {
    guard let store else { return }
    do {
      try change(store)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
    reload()
  }

  /// This device's id.
  public var deviceID: String { store?.deviceID ?? VaultDevice.id }

  /// Projects with a folder on this device.
  public var localProjects: [VaultProject] {
    projects.filter { $0.paths[deviceID] != nil }
  }

  /// The tree of the projects with a folder on this device, and the groups holding them.
  public var localProjectTree: VaultProjectTree {
    projectTree.filter { $0.paths[deviceID] != nil }
  }

  /// Folders with a path on this device.
  public var localFolders: [VaultFolder] {
    folders.filter { $0.paths[deviceID] != nil }
  }

  public func folder(id: String?) -> VaultFolder? {
    id.flatMap { id in folders.first { $0.id == id } }
  }

  public func remote(id: String?) -> VaultRemote? {
    id.flatMap { id in remotes.first { $0.id == id } }
  }

  public func host(id: String?) -> VaultHost? {
    id.flatMap { id in hosts.first { $0.id == id } }
  }
}
