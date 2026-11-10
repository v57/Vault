import Foundation
import Observation

/// The vault as SwiftUI sees it: the shared records, kept current as any app (or CloudKit) changes them.
///
/// `Vault.shared` is Personal. It opens the store in the app group container, reloads when the store's
/// change notification arrives, and starts iCloud sync (`CloudSync`) when the app has an iCloud account:
/// every app syncs on its own, and the one that made a change sends it. Each account (`VaultAccount`) is a `Vault`
/// of its own, opened by `Vaults`, and synced by Personal's engine.
@MainActor
@Observable
public final class Vault {
  public static let shared = Vault()

  public private(set) var projects: [VaultProject] = []
  public private(set) var projectGroups: [VaultProjectGroup] = []
  /// The projects in their groups, on every device.
  public private(set) var projectTree = VaultProjectTree(projects: [], groups: [])
  /// The projects' run presets (Code's), by project and their order (`presets(of:)`).
  public private(set) var projectPresets: [VaultProjectPreset] = []
  public private(set) var hosts: [VaultHost] = []
  public private(set) var databases: [VaultDatabase] = []
  /// The user's devices, without those taken out through Lost Device (`VaultStore.revokeDevice`).
  public private(set) var deviceKeys: [VaultDeviceKey] = []
  /// Apps' own keys (`VaultDeviceKey.isAppKey`: Get and Player), of trusted devices; not devices themselves.
  public private(set) var appKeys: [VaultDeviceKey] = []
  /// A device's key that was published although the device was revoked: an old build, or someone still holding it.
  public private(set) var untrustedDeviceKeys: [VaultDeviceKey] = []
  /// The devices taken out through Lost Device.
  public private(set) var revokedDevices: [VaultRevokedDevice] = []
  /// Accepted SSH host keys, by host.
  public private(set) var knownHosts: [VaultKnownHost] = []
  /// Logins, by title.
  public private(set) var logins: [VaultLogin] = []
  /// Passkeys, by site (each belongs to a login).
  public private(set) var passkeys: [VaultPasskey] = []
  public private(set) var cards: [VaultCard] = []
  /// Documents (passports, policies, resumes…) without their pages, which load per document (`VaultStore.files(of:)`).
  public private(set) var documents: [VaultDocument] = []
  /// Where documents are filed, in the user's order.
  public private(set) var documentCollections: [VaultDocumentCollection] = []
  /// Whose documents they are.
  public private(set) var holders: [VaultHolder] = []
  /// The built-in kinds of document and the user's own.
  public private(set) var documentKinds = DocumentKinds()
  /// Encrypted and synced folders.
  public private(set) var folders: [VaultFolder] = []
  /// Remotes folders sync through.
  public private(set) var remotes: [VaultRemote] = []
  /// People the user shares with, by name.
  public private(set) var people: [VaultPerson] = []
  /// The Hubs the user connected to (`VaultHub` connects; the other apps see their devices as hosts).
  public private(set) var hubs: [VaultHubServer] = []
  /// The accounts beside Personal, by name (in Personal only).
  public private(set) var accounts: [VaultAccount] = []
  /// The Apple developer teams this account works with.
  public private(set) var appleTeams: [VaultAppleTeam] = []
  /// Each account's name and email (in Personal only; `Vaults.profile(for:)` reads them).
  public private(set) var profiles: [VaultProfile] = []
  /// The Git app's shared choices, in Personal; nil until one is made.
  public private(set) var gitSettings: VaultGitSettings?
  /// Which account this is (`VaultAccount.personal` for Personal).
  public let accountID: String
  public var isPersonal: Bool { accountID == VaultAccount.personal.id }
  /// Why the store couldn't open or save, for the UI.
  public var error: String?
  /// The store's revision this vault last read. Observable: a view that reads the store beyond these lists (notes,
  /// which decrypt on each read) follows every change, a save here as much as one that synced in.
  public private(set) var revision: Int64 = -1
  /// When iCloud last fetched or sent changes, as this app's engine saw it: nil until it has, and while sync is off.
  /// Only Personal's is set (its engine carries every account): read it through `personalVault`.
  public private(set) var lastSynced: Date?

  /// The store, nil when it couldn't open.
  @ObservationIgnored public let store: VaultStore?
  /// The app's sync engine: Personal's, which carries the accounts too.
  @ObservationIgnored public internal(set) var sync: CloudSync?
  /// Personal, for an account's vault that `Vaults` opened.
  @ObservationIgnored weak var personal: Vault?
  /// Called after every reload that read the store (`Vaults` follows Personal's accounts).
  @ObservationIgnored var didReload: (() -> Void)?
  @ObservationIgnored private var observer: VaultChangeObserver?
  @ObservationIgnored var dumpObserver: VaultChangeObserver?
  @ObservationIgnored var commandObserver: VaultChangeObserver?
  @ObservationIgnored private var iconFinder: (find: @Sendable (URL) -> URL?, thumbnail: @Sendable (URL) -> Data?)?
  /// The projects whose folders `iconFinder` has looked at in this process.
  @ObservationIgnored private var iconsLookedAt: Set<String> = []
  @ObservationIgnored private var iconTask: Task<Void, Never>?

  /// Opens the shared store (or a given one, for tests and previews); `accountID` says which account's store it is.
  public init(store: VaultStore? = nil, accountID: String = VaultAccount.personal.id) {
    self.accountID = accountID
    if let store {
      self.store = store
    } else {
      self.store = VaultStore.shared
      if self.store == nil { self.error = "The shared store couldn’t be opened." }
    }
    if let refusal = self.store?.writeRefusal { error = refusal.localizedDescription }
    observer = VaultChangeObserver { [weak self] in
      Task { @MainActor in self?.reload() }
    }
    reload(force: true)
    #if DEBUG && os(macOS)
      if isPersonal { listenForDumpRequests() }
    #endif
  }

  /// Starts iCloud sync for this app: call it once from the App's init. Does nothing without an iCloud account
  /// or the CloudKit entitlement, and while the user has iCloud off (`VaultICloud`), until they turn it on. Only
  /// Personal starts the engine; it carries every account.
  public func startSync() {
    guard sync == nil, isPersonal, let store else { return }
    #if canImport(Security)
      // Get, Player and Hub read the vault keys from the records group: keep their copy current.
      Task.detached(priority: .utility) { VaultKeychain.mirrorRecordKeys() }
    #endif
    sync = CloudSync(store: store) { [weak self] in
      Task { @MainActor in self?.syncChanged() }
    }
    sync?.start()
    markSeen()
  }

  /// The engine fetched or sent something: read what arrived, and note when.
  private func syncChanged() {
    reload()
    if let date = sync?.lastSynced, date != lastSynced { lastSynced = date }
    markSeen()
  }

  /// Notes that this device ran a v57 app (`VaultStore.markDeviceSeen`, a few times a day at most), for the other
  /// devices' "seen today". Personal only: devices' keys are kept there.
  private func markSeen() {
    guard isPersonal, let store, (try? store.markDeviceSeen()) == true else { return }
    reload()
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
    guard force || revision != self.revision else { return }
    self.revision = revision
    #if os(macOS)
      // A device noting that it ran (`lastSeen`) changes nothing for authorized_keys.
      let unseen: ([VaultDeviceKey]) -> [VaultDeviceKey] = { $0.map { var key = $0; key.lastSeen = nil; return key } }
      let oldDeviceKeys = unseen(deviceKeys + appKeys)
    #endif
    do {
      projects = try store.records(VaultProject.self).sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      projectGroups = try store.records(VaultProjectGroup.self)
      projectTree = VaultProjectTree(projects: projects, groups: projectGroups)
      projectPresets = try store.records(VaultProjectPreset.self).sorted {
        ($0.projectID, $0.order, $0.name) < ($1.projectID, $1.order, $1.name)
      }
      let revoked = try store.revokedDevices()
      let revokedIDs = Set(revoked.map(\.deviceID))
      hosts = try store.records(VaultHost.self)
        .filter { host in host.device.map { !revokedIDs.contains($0.deviceID) } ?? true }
        .sorted { ($0.order, $0.displayName) < ($1.order, $1.displayName) }
      databases = try store.records(VaultDatabase.self).sorted { ($0.order, $0.name) < ($1.order, $1.name) }
      revokedDevices = revoked.sorted { $0.name < $1.name }
      let devices = try store.deviceKeysByTrust()
      deviceKeys = devices.trusted.filter { !$0.isAppKey }.sorted { $0.deviceName < $1.deviceName }
      appKeys = devices.trusted.filter(\.isAppKey).sorted { $0.deviceName < $1.deviceName }
      untrustedDeviceKeys = devices.revoked.filter { !$0.isAppKey }.sorted { $0.deviceName < $1.deviceName }
      knownHosts = try store.records(VaultKnownHost.self).sorted { ($0.host, $0.port) < ($1.host, $1.port) }
      logins = try store.records(VaultLogin.self).sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      passkeys = try store.records(VaultPasskey.self).sorted { ($0.relyingParty, $0.userName) < ($1.relyingParty, $1.userName) }
      folders = try store.records(VaultFolder.self).sorted {
        ($0.order, $0.name.localizedLowercase) < ($1.order, $1.name.localizedLowercase)
      }
      remotes = try store.records(VaultRemote.self).sorted {
        ($0.order, $0.displayName.localizedLowercase) < ($1.order, $1.displayName.localizedLowercase)
      }
      people = try store.records(VaultPerson.self).sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      hubs = try store.records(VaultHubServer.self).sorted {
        ($0.order, $0.displayName.localizedLowercase) < ($1.order, $1.displayName.localizedLowercase)
      }
      cards = try store.records(VaultCard.self).sorted {
        ($0.order, $0.title.localizedLowercase) < ($1.order, $1.title.localizedLowercase)
      }
      documents = try store.records(VaultDocument.self).sorted {
        ($0.order, $0.created ?? .distantPast) < ($1.order, $1.created ?? .distantPast)
      }
      documentCollections = try store.records(VaultDocumentCollection.self).sorted {
        ($0.order, $0.name.localizedLowercase) < ($1.order, $1.name.localizedLowercase)
      }
      holders = try store.records(VaultHolder.self).sorted { ($0.order, $0.name) < ($1.order, $1.name) }
      documentKinds = DocumentKinds(custom: try store.records(VaultDocumentKind.self))
      accounts = try store.records(VaultAccount.self).sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      appleTeams = try store.records(VaultAppleTeam.self).sorted { ($0.name, $0.teamID) < ($1.name, $1.teamID) }
      profiles = try store.records(VaultProfile.self)
      gitSettings = try store.record(VaultGitSettings.self, id: VaultGitSettings.recordID)
    } catch {
      self.error = error.localizedDescription
    }
    lookForIcons()
    if let own = deviceKeys.first(where: { $0.id == store.deviceID }), own.platform != "custom" {
      let wasRenamed = VaultDevice.customName != nil
      VaultDevice.customName = own.customName
      // Renamed (here or on another device), or back to the system's name: publish the key with the name.
      let name = VaultDevice.name
      if own.customName != nil || wasRenamed, own.deviceName != name || !own.publicKey.hasSuffix(" \(name)") {
        Task { @MainActor [weak self] in self?.perform { try $0.publishDeviceKey() } }
      }
    }
    #if os(macOS)
      // At launch, and when a device's key arrives, changes or goes: keep this Mac's authorized_keys and host current.
      if unseen(deviceKeys + appKeys) != oldDeviceKeys, isPersonal, thisDeviceHost != nil {
        Task { @MainActor [weak self] in self?.refreshThisMac() }
      }
    #endif
    didReload?()
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

  /// Names a device (`VaultStore.renameDevice`); this one publishes its key first if it hasn't yet. Failures go to
  /// `error`.
  public func renameDevice(_ id: String, to name: String?) {
    perform { store in
      if id == store.deviceID, try store.record(VaultDeviceKey.self, id: id) == nil { try store.publishDeviceKey() }
      try store.renameDevice(id, to: name)
    }
  }

  /// Marks a device as revoked and takes it out of this vault (`VaultStore.revokeDevice`); use `Vaults.revokeDevice` for
  /// all of them.
  public func revokeDevice(_ key: VaultDeviceKey) {
    perform { store in
      try store.revokeDevice(key) { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
      }
    }
  }

  /// Takes a revoked device off the list, so it can publish itself again.
  public func trustAgain(_ device: VaultRevokedDevice) {
    perform { try $0.trustAgain(device: device.deviceID) }
  }

  /// Takes a device out of this vault (`VaultStore.removeDevice`); use `Vaults.removeDevice` for all of them.
  /// Failures go to `error`.
  public func removeDevice(_ id: String) {
    perform { store in
      try store.removeDevice(id) { path in
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
      }
    }
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

  /// A login's passkeys.
  public func passkeys(forLogin id: String) -> [VaultPasskey] {
    passkeys.filter { $0.login == id }
  }

  public func hub(id: String?) -> VaultHubServer? {
    id.flatMap { id in hubs.first { $0.id == id } }
  }

  /// The vault holding what belongs to the user rather than an account: devices' keys, Hubs, the hosts that reach the
  /// user's devices and the host keys they trust. Itself for Personal.
  public var personalVault: Vault { personal ?? self }

  /// The hosts that are devices on the user's Hubs, reached through Hub Network.
  public var hubHosts: [VaultHost] { hosts.filter(\.isViaHub) }

  /// The Macs that published themselves, reached over SSH without a Hub.
  public var deviceHosts: [VaultHost] { hosts.filter(\.isDevice) }

  /// One host for each of the user's other devices: via this vault's Hubs when it's on one, else the Mac it published
  /// (Settings ▸ Remote, Personal's); `addresses(of:)` gives either one the other's addresses too.
  public var otherDeviceHosts: [VaultHost] {
    var seen = Set<String>()
    return (hubHosts + personalVault.deviceHosts).filter { host in
      guard !isThisDevice(host) else { return false }
      guard let device = vaultDevice(of: host) else { return true }
      return seen.insert(device).inserted
    }
  }

  /// The store that holds the host keys trusted for a host: Personal's for a Mac that published itself, else this
  /// vault's.
  public func trustStore(for host: VaultHost) -> VaultStore? {
    host.isDevice ? personalVault.store : store
  }

  /// The host key trusted for a host, in the store that holds it.
  public func knownHost(for host: VaultHost) -> VaultKnownHost? {
    (try? trustStore(for: host)?.knownHost(for: host)) ?? nil
  }

  /// This Mac as the others reach it, when it lets them in (`VaultStore.publishDeviceHost`).
  public var thisDeviceHost: VaultHost? { deviceHosts.first { $0.device?.deviceID == deviceID } }

  /// Whether a host is this device itself: the Mac it published, or a Hub device at one of this device's addresses
  /// (the Hub app on this Mac is a device of its own on the Hub, with an id the v57 apps don't know).
  /// The addresses are read only for a host via Hub (`VaultDevice.addresses` when not given).
  public func isThisDevice(_ host: VaultHost, addresses: Set<String>? = nil) -> Bool {
    if vaultDevice(of: host) == deviceID { return true }
    return host.isViaHub && (addresses ?? VaultDevice.addresses).contains(host.hostname)
  }

  /// The vault device a host via Hub is, when that device runs a v57 app connected to the Hub: the key to its
  /// per-device fields, such as where a project is on it (`project.paths[device]`).
  public func vaultDevice(of host: VaultHost) -> String? {
    if let route = host.device { return route.deviceID }
    guard let route = host.hub, let hub = hub(id: route.hubID) else { return nil }
    if let device = hub.vaultDevice(forHubDevice: route.deviceID) { return device }
    // The same Hub under another address (the hub's own machine reaches it at 127.0.0.1, the others at its LAN
    // address): the record with the same pinned key may know the device
    guard let key = hub.hubKey else { return nil }
    return hubs.lazy.filter { $0.id != hub.id && $0.hubKey == key }.compactMap { $0.vaultDevice(forHubDevice: route.deviceID) }.first
  }
}
