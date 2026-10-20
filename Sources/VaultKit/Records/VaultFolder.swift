import Foundation

/// A folder the Vault app keeps: encrypted on disk, synced through a remote, or both. The record holds what every
/// device needs to know about it; the files themselves are `VaultFiles`' business.
///
/// Each device decides for itself where the folder lives (`path.<device>`, and `bookmark.<device>` where the
/// system needs a security-scoped bookmark), whether it sends its changes (`mode.<device>`) and whether its copy
/// is plain files or encrypted (`storage.<device>`), one field each so devices changing their own settings
/// never collide.
public struct VaultFolder: VaultRecord, Hashable {
  public static let kind = "folder"
  public static let dynamicPrefixes = ["path.", "bookmark.", "mode.", "storage."]

  public enum Mode: String, Sendable, CaseIterable {
    /// Local changes are sent and remote changes received.
    case readWrite
    /// Remote changes are received; local edits stay on the device, marked "Changed here".
    case readOnly
  }

  public enum Storage: String, Sendable, CaseIterable {
    /// Ordinary files every app can open.
    case plain
    /// Encrypted on disk; only the v57 apps open it.
    case encrypted
  }

  public var id: String
  public var name: String
  /// Made as an encrypted folder: the storage of a device that hasn't chosen.
  public var encrypted: Bool
  /// The folder key sealed with the vault key, as `VaultFiles.FolderKey.wrapped(with:)` writes it (base64).
  public var wrappedKey: String?
  /// The `VaultRemote` it syncs through, if any.
  public var remoteID: String?
  /// Where on the remote.
  public var remotePath: String?
  /// The Ed25519 key (base64) of the person who owns a shared folder and signs its member list; nil for a folder
  /// of the user's own.
  public var ownerSigningKey: String?
  public var order: Int
  public var created: Date?
  /// Folder path by device id.
  public var paths: [String: String]
  /// Security-scoped bookmark (base64) by device id, for an iPad folder picked in Files.
  public var bookmarks: [String: String]
  public var modes: [String: Mode]
  public var storages: [String: Storage]

  public init(
    id: String = UUID().uuidString, name: String, encrypted: Bool = true, wrappedKey: String? = nil,
    remoteID: String? = nil, remotePath: String? = nil, ownerSigningKey: String? = nil, order: Int = 0,
    created: Date? = .now, paths: [String: String] = [:], bookmarks: [String: String] = [:],
    modes: [String: Mode] = [:], storages: [String: Storage] = [:]
  ) {
    self.id = id
    self.name = name
    self.encrypted = encrypted
    self.wrappedKey = wrappedKey
    self.remoteID = remoteID
    self.remotePath = remotePath
    self.ownerSigningKey = ownerSigningKey
    self.order = order
    self.created = created?.wholeSeconds
    self.paths = paths
    self.bookmarks = bookmarks
    self.modes = modes
    self.storages = storages
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    encrypted = read.bool("encrypted")
    wrappedKey = read.string("wrappedKey")
    remoteID = read.string("remoteID")
    remotePath = read.string("remotePath")
    ownerSigningKey = read.string("ownerSigningKey")
    order = read.int("order", default: 0)
    created = read.date("created")
    paths = read.strings(prefixed: "path")
    bookmarks = read.strings(prefixed: "bookmark")
    modes = read.strings(prefixed: "mode").compactMapValues(Mode.init)
    storages = read.strings(prefixed: "storage").compactMapValues(Storage.init)
  }

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "name": .string(name), "encrypted": .bool(encrypted), "wrappedKey": .init(wrappedKey),
      "remoteID": .init(remoteID), "remotePath": .init(remotePath), "ownerSigningKey": .init(ownerSigningKey),
      "order": .init(order), "created": .init(created),
    ]
    values.set(paths, prefixed: "path")
    values.set(bookmarks, prefixed: "bookmark")
    values.set(modes.mapValues(\.rawValue), prefixed: "mode")
    values.set(storages.mapValues(\.rawValue), prefixed: "storage")
    return values
  }

  public func path(for device: String) -> String? { paths[device] }

  /// The device's mode; read-write unless it chose read-only.
  public func mode(for device: String) -> Mode { modes[device] ?? .readWrite }

  /// The device's storage; the folder's default (`encrypted`) unless it chose.
  public func storage(for device: String) -> Storage { storages[device] ?? (encrypted ? .encrypted : .plain) }

  public func bookmark(for device: String) -> Data? { bookmarks[device].flatMap { Data(base64Encoded: $0) } }

  public mutating func setPath(_ path: String?, for device: String) { paths[device] = path }
  public mutating func setMode(_ mode: Mode?, for device: String) { modes[device] = mode }
  public mutating func setStorage(_ storage: Storage?, for device: String) { storages[device] = storage }
  public mutating func setBookmark(_ bookmark: Data?, for device: String) {
    bookmarks[device] = bookmark?.base64EncodedString()
  }

  /// Shared by someone else (it has an owner other than the user).
  public var isShared: Bool { ownerSigningKey != nil }
}

/// Storage a folder syncs through, or the file browser opens: an S3 bucket, an SFTP server (a `VaultHost`), an SMB
/// share, iCloud, FTP. The secret (S3 secret key, SMB or FTP password) is a `VaultSecrets` password named after
/// the remote.
///
/// A remote starts off (`enabled` false): nothing contacts it until the user turns it on.
public struct VaultRemote: VaultRecord, Hashable {
  public static let kind = "remote"

  public enum Kind: String, Sendable, CaseIterable {
    case s3
    case sftp
    case smb
    case icloud
    case ftp
  }

  public var id: String
  public var name: String
  public var kind: Kind
  /// The server: an S3 endpoint URL ("https://s3.eu-central-1.amazonaws.com", an R2 or MinIO address), an SMB
  /// or FTP host. Unused for SFTP (`hostID`) and iCloud.
  public var endpoint: String
  public var bucket: String
  public var region: String
  /// The folder on the remote everything goes under.
  public var path: String
  /// The `VaultHost` an SFTP remote connects to.
  public var hostID: String?
  /// S3 access key id.
  public var accessKeyID: String
  /// SMB or FTP user.
  public var user: String
  /// Off until the user turns it on.
  public var enabled: Bool
  public var order: Int
  public var created: Date?

  public init(
    id: String = UUID().uuidString, name: String = "", kind: Kind, endpoint: String = "", bucket: String = "",
    region: String = "", path: String = "", hostID: String? = nil, accessKeyID: String = "", user: String = "",
    enabled: Bool = false, order: Int = 0, created: Date? = .now
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.endpoint = endpoint
    self.bucket = bucket
    self.region = region
    self.path = path
    self.hostID = hostID
    self.accessKeyID = accessKeyID
    self.user = user
    self.enabled = enabled
    self.order = order
    self.created = created?.wholeSeconds
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    // An app that doesn't know a newer kind keeps the field as written, and reads the remote as off.
    let kindName = read.string("kind", default: "")
    kind = Kind(rawValue: kindName) ?? .s3
    endpoint = read.string("endpoint", default: "")
    bucket = read.string("bucket", default: "")
    region = read.string("region", default: "")
    path = read.string("path", default: "")
    hostID = read.string("hostID")
    accessKeyID = read.string("accessKeyID", default: "")
    user = read.string("user", default: "")
    enabled = Kind(rawValue: kindName) != nil && read.bool("enabled")
    order = read.int("order", default: 0)
    created = read.date("created")
    unknownKind = Kind(rawValue: kindName) == nil ? kindName : nil
  }

  /// The kind as written, when this build doesn't know it (it saves it back unchanged).
  private var unknownKind: String?

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "name": .string(name), "kind": .string(unknownKind ?? kind.rawValue), "endpoint": .string(endpoint),
      "bucket": .string(bucket), "region": .string(region), "path": .string(path), "hostID": .init(hostID),
      "accessKeyID": .string(accessKeyID), "user": .string(user), "order": .init(order), "created": .init(created),
    ]
    if unknownKind == nil { values["enabled"] = .bool(enabled) }
    return values
  }

  /// Name if given, else what it points at.
  public var displayName: String {
    if !name.isEmpty { return name }
    switch kind {
    case .s3: return bucket.isEmpty ? endpoint : bucket
    case .icloud: return "iCloud"
    default: return endpoint
    }
  }

  /// The S3 secret key or the SMB/FTP password.
  public var secret: String? { VaultSecrets.password(for: id) }
}

extension VaultStore {
  /// Saves a remote's secret (S3 secret key, SMB or FTP password), or deletes it for nil.
  public func setSecret(_ secret: String?, forRemote id: String) throws {
    try VaultSecrets.setPassword(secret, for: id)
  }

  /// Deletes a remote and its secret.
  public func deleteRemote(id: String) throws {
    try delete(id: id)
    try VaultSecrets.setPassword(nil, for: id)
  }
}
