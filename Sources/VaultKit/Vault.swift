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
  /// Why the store couldn't open or save, for the UI.
  public var error: String?

  /// The store, nil when it couldn't open.
  @ObservationIgnored public let store: VaultStore?
  @ObservationIgnored public private(set) var sync: CloudSync?
  @ObservationIgnored private var observer: VaultChangeObserver?
  @ObservationIgnored private var loadedRevision: Int64 = -1
  @ObservationIgnored var dumpObserver: VaultChangeObserver?
  @ObservationIgnored var commandObserver: VaultChangeObserver?

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
    } catch {
      self.error = error.localizedDescription
    }
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

  public func host(id: String?) -> VaultHost? {
    id.flatMap { id in hosts.first { $0.id == id } }
  }
}
