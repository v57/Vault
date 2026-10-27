import Foundation

/// A Hub (`~/Developer/Hub`) the user connected to: their own server, never one an app picked. Each device turns the
/// connection on for itself (`connects.<device>`), so adding a Hub on the Mac doesn't make the iPad connect.
///
/// Hub moves envelopes and introduces devices; it never sees vault data. The pinned `hubKey` makes a different server
/// at the same address fail to connect instead of being trusted.
public struct VaultHubServer: VaultRecord, Hashable {
  public static let kind = "hub"
  public static let dynamicPrefixes = ["connects.", "member.", "syncs."]

  public var id: String
  public var name: String
  /// The server's WebSocket address ("wss://hub.example.com", "ws://192.168.1.20:1997").
  public var url: String
  /// The Hub's public key (base64 SPKI), pinned on the first connection.
  public var hubKey: String?
  /// The devices that connect to it.
  public var connects: Set<String>
  /// The devices that sync the vault's records through it (`HubSync`, the `hub-vault` service): off until turned
  /// on, per device. Apple devices have iCloud; this is for the others, and for one device that bridges them.
  public var syncs: Set<String> = []
  /// Each vault device's id on this Hub (`member.<vault device>`), written by the device itself when it connects, so
  /// a Hub device can be matched to the vault's per-device fields (a project's `path.<device>`).
  public var members: [String: String]
  public var order: Int
  public var added: Date?

  public init(
    id: String = UUID().uuidString, name: String = "", url: String, hubKey: String? = nil, connects: Set<String> = [],
    members: [String: String] = [:], syncs: Set<String> = [], order: Int = 0, added: Date? = .now
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.hubKey = hubKey
    self.connects = connects
    self.members = members
    self.syncs = syncs
    self.order = order
    self.added = added
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    url = read.string("url", default: "")
    hubKey = read.string("hubKey")
    connects = Set(read.flags(prefixed: "connects"))
    members = read.strings(prefixed: "member")
    syncs = Set(read.flags(prefixed: "syncs"))
    order = read.int("order", default: 0)
    added = read.date("added")
  }

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "name": .string(name), "url": .string(url), "hubKey": .init(hubKey), "order": .init(order),
      "added": .init(added), "_identity": .init(identity),
    ]
    for device in connects { values["connects.\(device)"] = .bool(true) }
    values.set(members, prefixed: "member")
    for device in syncs { values["syncs.\(device)"] = .bool(true) }
    return values
  }

  /// What makes two records the same Hub: its address, normalized. The store folds records with the same identity
  /// (two devices added the Hub before either saw the other's record), merging their per-device flags.
  public var identity: String? { Self.identity(of: url) }

  /// `ws://Hub.Example.com:1997/` and `ws://hub.example.com:1997` are one Hub.
  public static func identity(of url: String) -> String? {
    var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix("/") { text.removeLast() }
    guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
    components.scheme = components.scheme?.lowercased()
    components.host = host.lowercased()
    return components.string
  }

  /// The id for a new Hub record: derived from its identity, so the same Hub added on two devices is one record.
  public static func newID(url: String, in store: VaultStore) -> String {
    identity(of: url).flatMap { try? store.derivedID("hub|" + $0) } ?? UUID().uuidString
  }

  /// The name if given, else the address's host.
  public var displayName: String {
    if !name.isEmpty { return name }
    return URL(string: url)?.host() ?? url
  }

  /// The open playground on v57.dev: for trying Hub out, with no guarantees. The apps never pick it themselves and
  /// say so when the user does.
  public var isPlayground: Bool {
    guard let host = URL(string: url)?.host()?.lowercased() else { return false }
    return host == "v57.dev" || host.hasSuffix(".v57.dev")
  }

  public func connects(on device: String) -> Bool { connects.contains(device) }

  /// The vault device that is `hubDevice` on this Hub, once it connected and said so.
  public func vaultDevice(forHubDevice hubDevice: String) -> String? {
    members.first { $0.value == hubDevice }?.key
  }
}

/// A device in a Hub's directory, as Vault sees it: the Hub's registry entry (name, platform, presence) and what the
/// device says it has (`capabilities`). `VaultHub` fills it from the Hub; VaultKit only stores what follows from it.
public struct VaultHubDevice: Sendable, Hashable, Identifiable {
  /// The Hub's device id: the first 16 bytes of the SHA-256 of the device key, in hex.
  public var id: String
  public var name: String
  /// "macos", "linux", "ios", "ipados", "windows", "android".
  public var platform: String
  public var os: String?
  public var arch: String?
  /// The device a container or VM says it runs on.
  public var parent: String?
  public var isApproved: Bool
  public var isRevoked: Bool
  /// Connected to the Hub now.
  public var isOnline: Bool
  /// Its Hub Network agent is connected (nil without one).
  public var isNetworkOnline: Bool?
  /// Its Hub Network overlay address, where SSH reaches it.
  public var address: String?
  public var lastSeen: Date?
  /// Remote Login, when the device offers it and signed its host key.
  public var ssh: SSH?
  /// Tools it reports ("xcode": "27.0", "swift": "6.3"), for picking where a build runs.
  public var tools: [String: String]
  /// The services running on it ("s3-local/Backup Disk").
  public var services: [String]

  public struct SSH: Sendable, Hashable {
    public var port: Int
    /// The OpenSSH host key line, set only when its signature by the device key checked out.
    public var hostKey: String?
    public var user: String?

    public init(port: Int = 22, hostKey: String? = nil, user: String? = nil) {
      self.port = port
      self.hostKey = hostKey
      self.user = user
    }
  }

  public init(
    id: String, name: String, platform: String, os: String? = nil, arch: String? = nil, parent: String? = nil,
    isApproved: Bool = true, isRevoked: Bool = false, isOnline: Bool = false, isNetworkOnline: Bool? = nil,
    address: String? = nil, lastSeen: Date? = nil, ssh: SSH? = nil, tools: [String: String] = [:],
    services: [String] = []
  ) {
    self.id = id
    self.name = name
    self.platform = platform
    self.os = os
    self.arch = arch
    self.parent = parent
    self.isApproved = isApproved
    self.isRevoked = isRevoked
    self.isOnline = isOnline
    self.isNetworkOnline = isNetworkOnline
    self.address = address
    self.lastSeen = lastSeen
    self.ssh = ssh
    self.tools = tools
    self.services = services
  }

  /// Whether apps can reach it over SSH: approved, not revoked, with Remote Login and a Hub Network address.
  public var isSSHTarget: Bool { isApproved && !isRevoked && ssh != nil && !(address ?? "").isEmpty }
}

/// What mirroring a Hub's directory changed.
public struct HubMirrorChanges: Sendable, Equatable {
  public var added: [String] = []
  public var updated: [String] = []
  public var removed: [String] = []

  public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
}

extension VaultStore {
  /// Keeps one `VaultHost` per SSH-capable device of a Hub ("via Hub": the overlay address, the signed host key
  /// trusted for every app when they can all negotiate its type, `HubRoute.hostKeyIsPinnable`), and removes the hosts of devices the Hub no longer lists or revoked, with their trust.
  ///
  /// Every device connected to the Hub mirrors the same directory into the same derived ids with the same values,
  /// so two of them doing it at once write nothing new. Offline devices stay: they're still listed.
  /// - Parameter thisDevice: this device's id on the Hub, which isn't a host for itself.
  @discardableResult
  public func mirrorHubDevices(_ devices: [VaultHubDevice], hubID: String, thisDevice: String? = nil) throws
    -> HubMirrorChanges
  {
    var changes = HubMirrorChanges()
    let existing = try records(VaultHost.self).filter { $0.hub?.hubID == hubID }
    var kept = Set<String>()
    for device in devices where device.isSSHTarget && device.id != thisDevice {
      guard let ssh = device.ssh, let address = device.address else { continue }
      let id = try hubHostID(hubID: hubID, deviceID: device.id)
      kept.insert(id)
      let route = VaultHost.HubRoute(
        hubID: hubID, deviceID: device.id, deviceName: device.name, platform: device.platform,
        hostKey: ssh.hostKey, lastSeen: device.lastSeen.map(Self.toTheHour))
      var host: VaultHost
      if let old = existing.first(where: { $0.id == id }) {
        host = old
        // The name follows the Hub's until the user renames the host.
        if old.name.isEmpty || old.name == old.hub?.deviceName { host.name = device.name }
        if old.hostname != address || old.port != ssh.port { try untrustHubKey(of: old) }
        if host.user.isEmpty, let user = ssh.user { host.user = user }
      } else {
        host = VaultHost(id: id, name: device.name, hostname: address, user: ssh.user ?? "", source: "hub")
      }
      host.hostname = address
      host.port = ssh.port
      host.hub = route
      let isNew = !existing.contains { $0.id == id }
      if try save(host) { isNew ? changes.added.append(id) : changes.updated.append(id) }
      if route.hostKeyIsPinnable, let fingerprint = route.hostKeyFingerprint,
        try knownFingerprint(host: address, port: ssh.port) != fingerprint
      {
        try trust(fingerprint: fingerprint, host: address, port: ssh.port, keyType: route.hostKey.flatMap(Self.keyType))
      }
    }
    for host in existing where !kept.contains(host.id) {
      try untrustHubKey(of: host)
      try delete(id: host.id)
      changes.removed.append(host.id)
    }
    return changes
  }

  /// Removes every host a Hub added (the user removed the Hub, or this device stopped connecting to it and no
  /// other does).
  public func forgetHubHosts(hubID: String) throws {
    try mirrorHubDevices([], hubID: hubID)
  }

  /// The id of the host mirroring a Hub device.
  public func hubHostID(hubID: String, deviceID: String) throws -> String {
    try derivedID("hubHost|\(hubID)|\(deviceID)")
  }

  /// Drops the trust the mirror gave a host's address, unless the user has since accepted another key there.
  private func untrustHubKey(of host: VaultHost) throws {
    guard host.hub?.hostKeyIsPinnable == true, let fingerprint = host.hub?.hostKeyFingerprint,
      try knownFingerprint(host: host.hostname, port: host.port) == fingerprint
    else { return }
    try delete(id: try knownHostID(host: host.hostname, port: host.port))
  }

  static func toTheHour(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
  }

  static func keyType(_ line: String) -> String? {
    line.split(separator: " ").first.map(String.init)
  }
}

/// A project's folder on another device, and the way there: through one of the user's Hubs, or straight to a Mac that
/// published itself.
public struct VaultProjectPlace: Sendable, Hashable, Identifiable {
  /// The vault device.
  public var device: String
  public var deviceName: String
  public var path: String
  /// The device as a host: via Hub when it's on one of the user's Hubs (and runs a v57 app connected to it), which
  /// reaches it from anywhere, else the host the device published (`VaultHost.device`).
  public var host: VaultHost?

  public var id: String { device }

  /// `ssh -t -p 22 user@address 'cd <path> && exec $SHELL -l'`: a terminal in the project's folder there.
  public var sshCommand: String? {
    guard let host else { return nil }
    let target = host.user.isEmpty ? host.hostname : "\(host.user)@\(host.hostname)"
    let script = "cd \(Self.quoted(path)) && exec \"$SHELL\" -l"
    return "ssh -t -p \(host.port) \(target) \(Self.quoted(script))"
  }

  static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension Vault {
  /// The project with a folder at `path` on this device.
  public func project(atPath path: String) -> VaultProject? {
    let path = URL(fileURLWithPath: path).standardizedFileURL.path
    return projects.first { $0.paths[deviceID].map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path }
  }

  /// Where else a project is: every other device with a folder for it, by name, with the host that reaches the
  /// device when there is one: via Hub first, else the host the device published.
  public func otherPlaces(of project: VaultProject) -> [VaultProjectPlace] {
    // The ways to the user's devices are Personal's, whichever account the project is in.
    let personal = personalVault
    let hubHosts = personal.hubHosts
    let deviceHosts = personal.deviceHosts
    return project.paths.compactMap { device, path -> VaultProjectPlace? in
      guard device != deviceID else { return nil }
      let host =
        hubHosts.first { personal.vaultDevice(of: $0) == device } ?? deviceHosts.first { $0.device?.deviceID == device }
      let name = personal.deviceKeys.first { $0.id == device }?.deviceName ?? host?.hub?.deviceName ?? "Another device"
      return VaultProjectPlace(device: device, deviceName: name, path: path, host: host)
    }
    .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
  }
}
