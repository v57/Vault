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
    id: String = UUID().uuidString, name: String = "", hostname: String, port: Int = 22, user: String = "",
    auth: Auth = .deviceKey, keyID: String? = nil, savePassword: Bool = true, jumpHostID: String? = nil,
    order: Int = 0, source: String? = nil, hub: HubRoute? = nil, device: DeviceRoute? = nil,
    buildSigning: BuildSigning? = nil
  ) {
    self.id = id
    self.name = name
    self.hostname = hostname
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

/// An accepted SSH host key, shared so a server is trusted once for every app (like `known_hosts`).
public struct VaultKnownHost: VaultRecord, Hashable {
  public static let kind = "knownHost"

  public var id: String
  public var host: String
  public var port: Int
  /// "SHA256:…".
  public var fingerprint: String
  public var keyType: String?
  public var accepted: Date?

  public init(id: String, host: String, port: Int, fingerprint: String, keyType: String? = nil, accepted: Date? = .now) {
    self.id = id
    self.host = host
    self.port = port
    self.fingerprint = fingerprint
    self.keyType = keyType
    self.accepted = accepted
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    host = read.string("host", default: "")
    port = read.int("port", default: 22)
    fingerprint = read.string("fingerprint", default: "")
    keyType = read.string("keyType")
    accepted = read.date("accepted")
  }

  public var values: [String: JSONValue] {
    [
      "host": .string(host), "port": .init(port), "fingerprint": .string(fingerprint), "keyType": .init(keyType),
      "accepted": .init(accepted),
    ]
  }
}

extension VaultStore {
  /// The accepted key fingerprint for a server, if any app accepted one.
  public func knownFingerprint(host: String, port: Int) throws -> String? {
    try record(VaultKnownHost.self, id: knownHostID(host: host, port: port))?.fingerprint
  }

  /// Trusts a server's key for every app.
  public func trust(fingerprint: String, host: String, port: Int, keyType: String? = nil) throws {
    try save(
      VaultKnownHost(
        id: knownHostID(host: host, port: port), host: host.lowercased(), port: port, fingerprint: fingerprint,
        keyType: keyType))
  }

  func knownHostID(host: String, port: Int) throws -> String {
    try derivedID("knownHost|\(host.lowercased()):\(port)")
  }
}

/// A device's public SSH key, published so the other devices can add it to servers.
public struct VaultDeviceKey: VaultRecord, Hashable {
  public static let kind = "deviceKey"

  /// The device id.
  public var id: String
  public var deviceName: String
  /// The `authorized_keys` line.
  public var publicKey: String
  public var platform: String
  public var updated: Date?

  public init(id: String, deviceName: String, publicKey: String, platform: String, updated: Date? = .now) {
    self.id = id
    self.deviceName = deviceName
    self.publicKey = publicKey
    self.platform = platform
    self.updated = updated
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    deviceName = read.string("deviceName", default: "")
    publicKey = read.string("publicKey", default: "")
    platform = read.string("platform", default: "")
    updated = read.date("updated")
  }

  public var values: [String: JSONValue] {
    ["deviceName": .string(deviceName), "publicKey": .string(publicKey), "platform": .string(platform), "updated": .init(updated)]
  }

  public var fingerprint: String? { VaultIdentity.fingerprint(keyLine: publicKey) }
}

extension VaultStore {
  /// Publishes this device's SSH public key (made on first use) so the other devices see it. Writes only
  /// when the name or key changed, so it can run at every launch.
  @MainActor
  public func publishDeviceKey() throws {
    let key = try VaultIdentity.key()
    let name = VaultDevice.name
    let line = VaultIdentity.publicKeyLine(key, comment: name)
    #if os(macOS)
      let platform = "macOS"
    #else
      let platform = "iOS"
    #endif
    if let existing = try record(VaultDeviceKey.self, id: deviceID),
      existing.publicKey == line, existing.deviceName == name
    {
      return
    }
    try save(VaultDeviceKey(id: deviceID, deviceName: name, publicKey: line, platform: platform))
  }
}
