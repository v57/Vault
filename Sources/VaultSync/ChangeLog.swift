import CryptoKit
import Foundation
import VaultFiles
import VaultKit

/// One change to one file, as a device's change log records it: the file's new contents (chunk ids, size, SHA-256)
/// or its deletion, when (`clock`), and which versions it replaces (`parents`: the heads the writing device had
/// synced, empty for a new file).
///
/// The parents make the history a graph per path. Its heads (changes no other change names as a parent) are what
/// the file is now: one head is a plain state, several are edits made at once on different devices, which every
/// device resolves the same way (see `FolderSync`).
public struct FileChange: Codable, Sendable, Hashable {
  /// The folder it belongs to, so a signed change can't be replayed into another folder.
  public var folder: String
  public var path: String
  public var clock: HybridClock
  public var parents: [HybridClock]
  public var deleted: Bool
  public var size: Int64
  /// SHA-256 of the contents, hex; empty for a deletion.
  public var hash: String
  /// Ids of the content-addressed chunks (`chunks/<id>`), in order.
  public var chunks: [String]
  /// For a conflict copy: the path it is the losing side of.
  public var conflictOf: String?
}

/// A change signed by its author's identity key (Ed25519 over `"v57-change-1"` and the change's JSON as stored).
struct SignedChange: Codable, Sendable, Hashable {
  var body: Data
  var author: Data
  var signature: Data

  static let prefix = Data("v57-change-1".utf8)

  static func sign(_ change: FileChange, by identity: PersonalIdentity) throws -> SignedChange {
    let body = try SyncCoding.encoder.encode(change)
    return SignedChange(
      body: body, author: identity.publicIdentity.signingKey, signature: try identity.signature(for: prefix + body))
  }

  /// The change, when the signature is the author's and it belongs to `folderID`.
  func verified(folderID: String) -> FileChange? {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: author),
      key.isValidSignature(signature, for: Self.prefix + body),
      let change = try? JSONDecoder().decode(FileChange.self, from: body), change.folder == folderID
    else { return nil }
    return change
  }
}

/// A change as a device knows it: where it was read (the writing device's log and sequence number) and its signed
/// form (which snapshots carry along).
struct KnownChange: Codable, Sendable, Hashable {
  var change: FileChange
  var signed: SignedChange
  var device: String
  var sequence: Int

  var clock: HybridClock { change.clock }
}

/// What one log file holds: the changes a device sent in one go.
struct LogSegment: Codable {
  var changes: [SignedChange]
}

/// A compacted state: the heads of every path as of `covered` (each device's log read up to that sequence
/// number), signed by the writer who made it.
struct SnapshotBody: Codable {
  struct Entry: Codable {
    var signed: SignedChange
    var device: String
    var sequence: Int
  }

  var folder: String
  var created: Date
  var covered: [String: Int]
  var changes: [Entry]
}

struct SignedSnapshot: Codable {
  var body: Data
  var author: Data
  var signature: Data

  static let prefix = Data("v57-snapshot-1".utf8)
}

/// The remote folder's layout:
///
/// ```
/// <folder>/members           signed member list
/// <folder>/chunks/<id>       content-addressed encrypted chunks, written once
/// <folder>/log/<device>/<n>  each device's change log, one file per send, numbered 1, 2, 3… (10 digits)
/// <folder>/snapshots/<clock> compacted state
/// ```
struct RemoteLayout: Sendable {
  let root: String

  var chunks: String { RemotePath.join(root, "chunks") }
  var logs: String { RemotePath.join(root, "log") }
  var snapshots: String { RemotePath.join(root, "snapshots") }

  func chunk(_ id: String) -> String { RemotePath.join(chunks, id) }
  func log(_ device: String) -> String { RemotePath.join(logs, device) }
  func segment(_ device: String, _ sequence: Int) -> String {
    RemotePath.join(log(device), String(format: "%010d", sequence))
  }
  func snapshot(_ name: String) -> String { RemotePath.join(snapshots, name) }
}

/// The keys of one epoch, derived from its folder key: contents (chunks, logs, snapshots) and chunk ids.
struct EpochKeys: Sendable {
  let folderKey: FolderKey
  let content: SymmetricKey
  let chunkIDKey: SymmetricKey

  init(_ key: FolderKey) {
    folderKey = key
    content = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key.key, info: Data("dev.v57.sync.content".utf8), outputByteCount: 32)
    chunkIDKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key.key, info: Data("dev.v57.sync.chunk-id".utf8), outputByteCount: 32)
  }

  /// A chunk's id: a keyed hash of its plaintext, so equal chunks dedupe and the remote learns nothing from ids.
  func chunkID(_ data: Data) -> String {
    hex(Data(HMAC<SHA256>.authenticationCode(for: data, using: chunkIDKey)))
  }
}

/// A member's keys for every epoch they hold.
struct SyncKeys: Sendable {
  let keyring: FolderKeyring
  let byID: [String: EpochKeys]
  let current: EpochKeys

  init(_ keyring: FolderKeyring) {
    self.keyring = keyring
    var byID: [String: EpochKeys] = [:]
    for key in keyring.keys.values { byID[key.id] = EpochKeys(key) }
    self.byID = byID
    current = byID[keyring.current.id]!
  }

  /// Seals with the current epoch's key.
  func seal(_ data: Data, context: Data) throws -> Data {
    try EncryptedFile.seal(data, key: current.content, keyID: current.folderKey.id, context: context)
  }

  /// Opens with the epoch key the header names.
  func open(_ data: Data, context: Data) throws -> (Data, EpochKeys) {
    let header = try EncryptedFile.Header(parsing: data)
    guard let keys = byID[header.keyID] else { throw FolderSyncError.missingKey(header.keyID) }
    return (try EncryptedFile.open(data, key: keys.content, context: context), keys)
  }

  /// Seals this device's own sync state: derived from the folder's first key, which every member holds and which
  /// never changes.
  static func stateKey(_ keyring: FolderKeyring) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: keyring.first.key, info: Data("dev.v57.sync.local-state".utf8), outputByteCount: 32)
  }
}

enum SyncCoding {
  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }

  static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
