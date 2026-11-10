import Foundation

/// An SSH host: Shell's saved connections, which Database tunnels through.
public struct VaultHost: VaultRecord, Hashable {
  public static let kind = "host"

  public enum Auth: String, Sendable, CaseIterable {
    /// This device's Secure Enclave key (`VaultIdentity`).
    case deviceKey
    /// A password, saved with `VaultSecrets` when `savePassword` is on.
    case password
    /// A key imported into one app (Database), named by `keyID`.
    case importedKey
  }

  /// How builds started on this Mac over SSH sign their products (Code's remote Build and Test). An SSH session
  /// can't use the login keychain, which stays locked there while it's unlocked on the Mac's screen.
  public enum BuildSigning: String, Sendable, CaseIterable {
    /// No signing: the build checks the code compiles and tests run, but makes no app to copy and run elsewhere.
    case none
    /// Unlocks the login keychain first with the user's password (`VaultSecrets.password(for:)` of the host).
    case loginKeychain
    /// Runs the build in the desktop session of the user logged in on the Mac (a launchd job), whose login keychain
    /// is unlocked: no password, and the build outlives the SSH connection.
    case desktopSession
  }

  public var id: String
  public var name: String
  public var hostname: String
  /// Other addresses of the same machine, tried in order when `hostname` doesn't answer (added by the user; the
  /// ways to one of the user's own devices come on top: `Vault.addresses(of:)`).
  public var fallbacks: [String]
  public var port: Int
  public var user: String
  public var auth: Auth
  public var keyID: String?
  public var savePassword: Bool
  /// A host to jump through first (`ProxyJump`).
  public var jumpHostID: String?
  /// Sidebar order.
  public var order: Int
  /// Where it came from: "shell", "ssh-config" (imported from ~/.ssh/config), "dev-vm", "hub", "device".
  public var source: String?
  /// A device on one of the user's Hubs (`VaultHub`), reached at its Hub Network address: `hostname` is the
  /// overlay address, `hostKey` the SSH host key the device signed. Nil for a host the user added.
  public var hub: HubRoute?
  /// A Mac that published itself (`VaultStore.publishDeviceHost`): SSH straight to it, at the address it gave, with
  /// the host key it read from its own `/etc/ssh`. Nil for other hosts.
  public var device: DeviceRoute?
  /// How builds started there over SSH sign; nil until the user picks (builds don't sign).
  public var buildSigning: BuildSigning?

  /// How a host on a Hub is reached and trusted, kept current from the Hub's device directory.
  public struct HubRoute: Sendable, Hashable {
    /// The `VaultHub` record.
    public var hubID: String
    /// The Hub's device id.
    public var deviceID: String
    /// The name the Hub gives the device; `name` follows it until the user renames the host.
    public var deviceName: String
    /// "macos", "linux", "ios"…
    public var platform: String
    /// The OpenSSH host key line ("ssh-ed25519 AAAA…"), when the device signed one.
    public var hostKey: String?
    /// When the Hub last saw the device, to the hour (finer would make every app's records churn).
    public var lastSeen: Date?

    public init(
      hubID: String, deviceID: String, deviceName: String, platform: String = "", hostKey: String? = nil,
      lastSeen: Date? = nil
    ) {
      self.hubID = hubID
      self.deviceID = deviceID
      self.deviceName = deviceName
      self.platform = platform
      self.hostKey = hostKey
      self.lastSeen = lastSeen
    }

    /// "SHA256:…" of `hostKey`.
    public var hostKeyFingerprint: String? { hostKey.flatMap { VaultIdentity.fingerprint(keyLine: $0) } }

    public var hostKeyIsPinnable: Bool { hostKey.map(VaultHost.isPinnable) ?? false }
  }

  /// How a Mac that published itself is reached, kept current by that Mac.
  public struct DeviceRoute: Sendable, Hashable {
    /// The vault device (`VaultDevice.id`) the host is: the key to its per-device fields, such as `path.<device>`.
    public var deviceID: String
    /// The address the Mac published ("Studio.local"): `hostname` follows it until the user changes the hostname
    /// (to a Tailscale name, say).
    public var address: String
    /// The OpenSSH host key line the Mac read from its own `/etc/ssh`.
    public var hostKey: String?
    /// The devices whose keys the Mac's `authorized_keys` lists, as the Mac last saw it: what the others show.
    public var allowed: Set<String>

    public init(deviceID: String, address: String, hostKey: String? = nil, allowed: Set<String> = []) {
      self.deviceID = deviceID
      self.address = address
      self.hostKey = hostKey
      self.allowed = allowed
    }

    /// "SHA256:…" of `hostKey`.
    public var hostKeyFingerprint: String? { hostKey.flatMap { VaultIdentity.fingerprint(keyLine: $0) } }

    public var hostKeyIsPinnable: Bool { hostKey.map(VaultHost.isPinnable) ?? false }
  }

  /// Whether every v57 app negotiates this host key's type, so trusting it ahead of time matches what they see.
  /// Their libssh2 is built on mbedTLS, without Ed25519: a pinned Ed25519 key would look like a changed key next
  /// to the ECDSA one the server offers them.
  public static func isPinnable(_ keyLine: String) -> Bool {
    guard let type = keyLine.split(separator: " ").first else { return false }
    return type.hasPrefix("ecdsa-sha2-") || type == "ssh-rsa"
  }

  public init(
    id: String = UUID().uuidString, name: String = "", hostname: String, fallbacks: [String] = [], port: Int = 22,
    user: String = "",
    auth: Auth = .deviceKey, keyID: String? = nil, savePassword: Bool = true, jumpHostID: String? = nil,
    order: Int = 0, source: String? = nil, hub: HubRoute? = nil, device: DeviceRoute? = nil,
    buildSigning: BuildSigning? = nil
  ) {
    self.id = id
    self.name = name
    self.hostname = hostname
    self.fallbacks = fallbacks
    self.port = port
    self.user = user
    self.auth = auth
    self.keyID = keyID
    self.savePassword = savePassword
    self.jumpHostID = jumpHostID
    self.order = order
    self.source = source
    self.hub = hub
    self.device = device
    self.buildSigning = buildSigning
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    hostname = read.string("hostname", default: "")
    fallbacks = read.string("fallbacks", default: "").split(separator: "\n").map(String.init)
    port = read.int("port", default: 22)
    user = read.string("user", default: "")
    auth = read.string("auth").flatMap(Auth.init) ?? .deviceKey
    keyID = read.string("keyID")
    savePassword = read.bool("savePassword", default: true)
    jumpHostID = read.string("jumpHostID")
    order = read.int("order", default: 0)
    source = read.string("source")
    buildSigning = read.string("buildSigning").flatMap {
      // "signingKeychain", the mode desktopSession replaced
      BuildSigning(rawValue: $0 == "signingKeychain" ? "desktopSession" : $0)
    }
    if let hubID = read.string("hub.id"), let deviceID = read.string("hub.device") {
      hub = HubRoute(
        hubID: hubID, deviceID: deviceID, deviceName: read.string("hub.deviceName", default: ""),
        platform: read.string("hub.platform", default: ""), hostKey: read.string("hub.hostKey"),
        lastSeen: read.date("hub.lastSeen"))
    }
    if let deviceID = read.string("device.id") {
      let allowed = read.string("device.allowed", default: "").split(separator: ",").map(String.init)
      device = DeviceRoute(
        deviceID: deviceID, address: read.string("device.address", default: ""), hostKey: read.string("device.hostKey"),
        allowed: Set(allowed))
    }
  }

  public var values: [String: JSONValue] {
    [
      "name": .string(name), "hostname": .string(hostname), "port": .init(port), "user": .string(user),
      "fallbacks": fallbacks.isEmpty ? .null : .string(fallbacks.joined(separator: "\n")),
      "auth": .string(auth.rawValue), "keyID": .init(keyID), "savePassword": .bool(savePassword),
      "jumpHostID": .init(jumpHostID), "order": .init(order), "source": .init(source),
      "buildSigning": .init(buildSigning?.rawValue),
      "hub.id": .init(hub?.hubID), "hub.device": .init(hub?.deviceID), "hub.deviceName": .init(hub?.deviceName),
      "hub.platform": .init(hub?.platform), "hub.hostKey": .init(hub?.hostKey), // Whole hours, written as an integer: that's how the store reads it back, so an unchanged value isn't a change.
      "hub.lastSeen": hub?.lastSeen.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null,
      // Only the Mac writes its route, so the allowed devices can be one field.
      "device.id": .init(device?.deviceID), "device.address": .init(device?.address),
      "device.hostKey": .init(device?.hostKey), "device.allowed": .init(device.map { $0.allowed.sorted().joined(separator: ",") }),
    ]
  }

  /// The way to the machine that a pin on this host belongs to (`VaultStore.knownFingerprint(for:)`), nil when the
  /// address alone says it: a device on a Hub (another Hub can use the same overlay address), a Mac that published
  /// itself, or a `.local` name, which means another machine on another network.
  public var pinRoute: String? {
    if let hub { return "hub|\(hub.hubID)|\(hub.deviceID)" }
    if let device { return "device|\(device.deviceID)" }
    if hostname.lowercased().hasSuffix(".local") { return "host|\(id)" }
    return nil
  }

  /// Whether the host is a device on one of the user's Hubs, reached through Hub Network.
  public var isViaHub: Bool { hub != nil }

  /// Whether the host is a Mac of the user's that published itself, reached over SSH without a Hub.
  public var isDevice: Bool { device != nil }

  /// Name if given, otherwise user@host.
  public var displayName: String {
    if !name.isEmpty { return name }
    return user.isEmpty ? hostname : "\(user)@\(hostname)"
  }

  public var password: String? { VaultSecrets.password(for: id) }

  /// Whether `host` (a database's server address) is this host: the same name or address.
  public func serves(_ host: String) -> Bool {
    let host = host.lowercased()
    return host == hostname.lowercased() || (!name.isEmpty && host == name.lowercased())
  }
}

/// An accepted SSH host key, shared so a server is trusted once for every app (like `known_hosts`). A pin belongs to
/// its host and port, and to its route when the host has one (`VaultHost.pinRoute`): what one Hub says about a device
/// counts for that Hub's device and nothing else.
public struct VaultKnownHost: VaultRecord, Hashable {
  public static let kind = "knownHost"

  public var id: String
  public var host: String
  public var port: Int
  /// "SHA256:…".
  public var fingerprint: String
  public var keyType: String?
  public var accepted: Date?
  /// `VaultHost.pinRoute`; empty for a pin on a host and port alone. Nil on a pin from before routes, which is still
  /// read for a host at that address when it has no pin of its own.
  public var route: String?

  public init(
    id: String, host: String, port: Int, fingerprint: String, keyType: String? = nil, accepted: Date? = .now,
    route: String? = nil
  ) {
    self.id = id
    self.host = host
    self.port = port
    self.fingerprint = fingerprint
    self.keyType = keyType
    self.accepted = accepted
    self.route = route
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    host = read.string("host", default: "")
    port = read.int("port", default: 22)
    fingerprint = read.string("fingerprint", default: "")
    keyType = read.string("keyType")
    accepted = read.date("accepted")
    route = read.string("route")
  }

  public var values: [String: JSONValue] {
    [
      "host": .string(host), "port": .init(port), "fingerprint": .string(fingerprint), "keyType": .init(keyType),
      "accepted": .init(accepted), "route": .init(route),
    ]
  }
}

extension VaultStore {
  /// The accepted key for a saved host: its own pin, else a pin from before routes at its address.
  public func knownHost(for host: VaultHost) throws -> VaultKnownHost? {
    if let pin = try record(VaultKnownHost.self, id: knownHostID(for: host)) { return pin }
    guard host.pinRoute != nil else { return nil }
    let old = try record(VaultKnownHost.self, id: knownHostID(host: host.hostname, port: host.port))
    return old?.route == nil ? old : nil
  }

  /// The accepted key fingerprint for a saved host, if any app accepted one or a verified source gave one.
  public func knownFingerprint(for host: VaultHost) throws -> String? {
    try knownHost(for: host)?.fingerprint
  }

  /// Trusts a saved host's key for every app, on the host's route.
  public func trust(fingerprint: String, for host: VaultHost, keyType: String? = nil) throws {
    try save(
      VaultKnownHost(
        id: knownHostID(for: host), host: host.hostname.lowercased(), port: host.port, fingerprint: fingerprint,
        keyType: keyType, route: host.pinRoute ?? ""))
  }

  /// The accepted key fingerprint for an address that's no saved host (a Git remote, a connection being set up).
  /// Pins on routes don't count: they say nothing about whoever else answers at that address.
  public func knownFingerprint(host: String, port: Int) throws -> String? {
    try record(VaultKnownHost.self, id: knownHostID(host: host, port: port))?.fingerprint
  }

  /// Trusts the key of an address that's no saved host, for every app.
  public func trust(fingerprint: String, host: String, port: Int, keyType: String? = nil) throws {
    try save(
      VaultKnownHost(
        id: knownHostID(host: host, port: port), host: host.lowercased(), port: port, fingerprint: fingerprint,
        keyType: keyType, route: ""))
  }

  func knownHostID(host: String, port: Int) throws -> String {
    try derivedID("knownHost|\(host.lowercased()):\(port)")
  }

  /// A pin's place: the same address on two routes is two pins.
  func knownHostID(for host: VaultHost) throws -> String {
    guard let route = host.pinRoute else { return try knownHostID(host: host.hostname, port: host.port) }
    return try derivedID("knownHost|\(route)|\(host.hostname.lowercased()):\(host.port)")
  }

  /// Drops the pin of `fingerprint` on a host's route, and one from before routes at its address, unless the user has
  /// since accepted another key there. The next connection asks again, as a first one.
  public func untrust(fingerprint: String, for host: VaultHost) throws {
    let pin = try knownHostID(for: host)
    if try record(VaultKnownHost.self, id: pin)?.fingerprint == fingerprint { try delete(id: pin) }
    let id = try knownHostID(host: host.hostname, port: host.port)
    if let old = try record(VaultKnownHost.self, id: id), old.route == nil, old.fingerprint == fingerprint {
      try delete(id: id)
    }
  }
}

/// A device's public SSH key, published so the other devices can add it to servers.
public struct VaultDeviceKey: VaultRecord, Hashable {
  public static let kind = "deviceKey"

  /// The device id.
  public var id: String
  public var deviceName: String
  /// The name the user gave the device (`VaultStore.renameDevice`), nil while it goes by its system's; the device
  /// itself then publishes it as `deviceName` too.
  public var customName: String?
  /// The `authorized_keys` line.
  public var publicKey: String
  public var platform: String
  /// When the key, the name or the platform was last published.
  public var updated: Date?
  /// When the device last ran a v57 app with sync on (`VaultStore.markDeviceSeen`), to within a few hours; nil until a
  /// build that notes it ran there. Not in `values`: only `markDeviceSeen` writes it, so publishing the key (here or
  /// from an older build) never clears it.
  public var lastSeen: Date?
  /// For an app's own key (`isAppKey`): its bundle id, and the device it runs on. Get and Player hold no device key
  /// (security audit M4, V3), so they sign in to the user's machines with a key of their own, which the user allows on
  /// each Mac (Settings ▸ Remote) and which sshd takes with `restrict` (no forwarding, no terminal).
  public var app: String?
  public var device: String?

  public init(
    id: String, deviceName: String, customName: String? = nil, publicKey: String, platform: String,
    updated: Date? = .now, app: String? = nil, device: String? = nil
  ) {
    self.id = id
    self.deviceName = deviceName
    self.customName = customName
    self.publicKey = publicKey
    self.platform = platform
    self.updated = updated
    self.app = app
    self.device = device
  }

  public var isAppKey: Bool { app != nil }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    deviceName = read.string("deviceName", default: "")
    customName = read.string("customName").flatMap { $0.isEmpty ? nil : $0 }
    publicKey = read.string("publicKey", default: "")
    platform = read.string("platform", default: "")
    updated = read.date("updated")
    lastSeen = read.date("lastSeen")
    app = read.string("app").flatMap { $0.isEmpty ? nil : $0 }
    device = read.string("device").flatMap { $0.isEmpty ? nil : $0 }
  }

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "deviceName": .string(deviceName), "customName": .init(customName), "publicKey": .string(publicKey),
      "platform": .string(platform), "updated": .init(updated),
    ]
    if let app { values["app"] = .string(app) }
    if let device { values["device"] = .string(device) }
    return values
  }

  public var fingerprint: String? { VaultIdentity.fingerprint(keyLine: publicKey) }

  /// When the device was last seen: when it last ran a v57 app, else (a build that doesn't note it) when it published
  /// its key.
  public var seen: Date? { lastSeen ?? updated }

  /// How long a device's `lastSeen` stands before it's written again (on a new day it's written anyway).
  public static let seenInterval: TimeInterval = 4 * 3600
}

extension VaultStore {
  /// Publishes this device's SSH public key (made on first use) so the other devices see it. Writes only
  /// when the name or key changed, so it can run at every launch.
  @MainActor
  public func publishDeviceKey() throws {
    guard try !isRevoked(device: deviceID) else { return }
    if VaultKeychain.readsRecordsOnly { return try publishAppKey() }
    let key = try VaultIdentity.key()
    let name = VaultDevice.name
    let line = VaultIdentity.publicKeyLine(key, comment: name)
    #if os(macOS)
      let platform = "macOS"
    #else
      let platform = "iOS"
    #endif
    let existing = try record(VaultDeviceKey.self, id: deviceID)
    if let existing, existing.publicKey == line, existing.deviceName == name { return }
    try save(
      VaultDeviceKey(
        id: deviceID, deviceName: name, customName: existing?.customName, publicKey: line, platform: platform))
  }

  /// Notes that this device runs a v57 app (`VaultDeviceKey.lastSeen`), for the other devices' "seen today". Writes
  /// only that field of its published key, and only when the last note is from another day or `seenInterval` old, so
  /// every app can call it on each sync. Nothing before the device has published its key, and nothing from an app
  /// without the device key (`VaultKeychain.readsRecordsOnly`). Returns whether it wrote.
  @discardableResult
  public func markDeviceSeen(now: Date = .now, calendar: Calendar = .current) throws -> Bool {
    guard !VaultKeychain.readsRecordsOnly, let key = try record(VaultDeviceKey.self, id: deviceID) else { return false }
    if let seen = key.lastSeen, calendar.isDate(seen, inSameDayAs: now), now.timeIntervalSince(seen) < VaultDeviceKey.seenInterval,
      seen <= now
    {
      return false
    }
    return try save(id: deviceID, kind: VaultDeviceKey.kind, changes: ["lastSeen": .init(now)])
  }

  /// An app without the device key (`VaultKeychain.readsRecordsOnly`) publishes its own (`VaultDeviceKey.isAppKey`), as
  /// `<device id>.<bundle id>`.
  @MainActor
  func publishAppKey(bundle: String = Bundle.main.bundleIdentifier ?? "app", appName: String = VaultStore.appName) throws {
    let key = try VaultIdentity.key()
    let name = "\(appName) on \(VaultDevice.name)"
    let line = VaultIdentity.publicKeyLine(key, comment: name)
    let id = "\(deviceID).\(bundle)"
    let existing = try record(VaultDeviceKey.self, id: id)
    if let existing, existing.publicKey == line, existing.deviceName == name { return }
    #if os(macOS)
      let platform = "macOS"
    #else
      let platform = "iOS"
    #endif
    try save(VaultDeviceKey(id: id, deviceName: name, publicKey: line, platform: platform, app: bundle, device: deviceID))
  }

  static var appName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "An app"
  }

  /// Names a device, this one or another (nil or blank: back to the system's name). Every app on that device then
  /// goes by it (`VaultDevice.name`): its key's comment, the Hub, `authorized_keys` lines Vault wrote, the host other
  /// devices see. The device republishes its key with the name when it loads the vault (`Vault.reload`).
  public func renameDevice(_ id: String, to name: String?) throws {
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    let custom = name?.isEmpty == false ? name : nil
    guard var key = try record(VaultDeviceKey.self, id: id) else { throw VaultDeviceError.unknownDevice }
    guard key.customName != custom else { return }
    key.customName = custom
    if let custom { key.deviceName = custom }
    try save(key)
  }

  /// Takes another device out of this vault: its key, the host it published and the trust that gave its key, and
  /// its fields in projects, groups, folders and Hubs. A project only on it goes (and a group that leaves empty),
  /// unless `folderIsHere` finds its folder on this device and no project has that folder here: a reinstalled Mac is
  /// a new device with the same folders. A device still running a v57 app publishes itself again, and this does nothing
  /// about what it holds: for a lost or stolen one, `revokeDevice`.
  public func removeDevice(_ id: String, folderIsHere: (String) -> Bool = { _ in false }) throws {
    guard id != deviceID else { throw VaultDeviceError.thisDevice }
    let projects = try records(VaultProject.self)
    let tree = try projectTree()
    var here = Set(projects.compactMap { $0.paths[deviceID] })
    var emptied: [String] = []
    for var project in projects where project.paths[id] != nil || project.statuses[id] != nil {
      if let path = project.paths[id], project.paths[deviceID] == nil, !here.contains(path), folderIsHere(path) {
        project.paths[deviceID] = path
        here.insert(path)
      }
      project.paths[id] = nil
      project.statuses[id] = nil
      if project.paths.isEmpty {
        if let group = tree.parent(of: project.id) { emptied.append(group) }
        try delete(id: project.id)
      } else {
        try save(project)
      }
    }
    for var group in try records(VaultProjectGroup.self) where group.paths[id] != nil {
      group.paths[id] = nil
      try save(group)
    }
    try removeEmptyProjectGroups(emptied)
    for var folder in try records(VaultFolder.self)
    where folder.paths[id] != nil || folder.bookmarks[id] != nil || folder.modes[id] != nil || folder.storages[id] != nil {
      folder.paths[id] = nil
      folder.bookmarks[id] = nil
      folder.modes[id] = nil
      folder.storages[id] = nil
      try save(folder)
    }
    for var hub in try records(VaultHubServer.self)
    where hub.connects.contains(id) || hub.syncs.contains(id) || hub.members[id] != nil {
      hub.connects.remove(id)
      hub.syncs.remove(id)
      hub.members[id] = nil
      try save(hub)
    }
    for host in try records(VaultHost.self) where host.device?.deviceID == id {
      try untrustDeviceKey(of: host)
      try delete(id: host.id)
    }
    try delete(id: id)
  }
}

public enum VaultDeviceError: LocalizedError {
  case unknownDevice
  case thisDevice

  public var errorDescription: String? {
    switch self {
    case .unknownDevice: "This device hasn't published its key yet."
    case .thisDevice: "A device can't remove itself."
    }
  }
}
