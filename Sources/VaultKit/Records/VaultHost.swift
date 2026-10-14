import Foundation

/// An SSH host: Shell's saved connections, which Database and DatabasePro tunnel through.
public struct VaultHost: VaultRecord, Hashable {
  public static let kind = "host"

  public enum Auth: String, Sendable, CaseIterable {
    /// This device's Secure Enclave key (`VaultIdentity`).
    case deviceKey
    /// A password, saved with `VaultSecrets` when `savePassword` is on.
    case password
    /// A key imported into one app (DatabasePro), named by `keyID`.
    case importedKey
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
  /// Where it came from: "shell", "ssh-config" (imported from ~/.ssh/config), "dev-vm".
  public var source: String?

  public init(
    id: String = UUID().uuidString, name: String = "", hostname: String, port: Int = 22, user: String = "",
    auth: Auth = .deviceKey, keyID: String? = nil, savePassword: Bool = true, jumpHostID: String? = nil,
    order: Int = 0, source: String? = nil
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
  }

  public var values: [String: JSONValue] {
    [
      "name": .string(name), "hostname": .string(hostname), "port": .init(port), "user": .string(user),
      "auth": .string(auth.rawValue), "keyID": .init(keyID), "savePassword": .bool(savePassword),
      "jumpHostID": .init(jumpHostID), "order": .init(order), "source": .init(source),
    ]
  }

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

  private func knownHostID(host: String, port: Int) throws -> String {
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
