import CryptoKit
import Foundation
import VaultFiles
import VaultKit

/// The signed member list at a synced folder's root (`<folder>/members`): who is in the folder, what each may do,
/// and the folder key wrapped to each of them (`KeyWrap`).
///
/// Only the owner signs it (Ed25519, the key in `VaultFolder.ownerSigningKey`), and every change raises `version`,
/// so a device that remembers the highest version it saw refuses an older copy put back on the remote.
///
/// Keys come in epochs. Removing someone rotates: a new folder key becomes the current epoch, wrapped to everyone
/// who stays, and what is written afterwards uses it. Older epochs stay wrapped to the remaining members (and to
/// members added later) so they read everything written before. The removed person keeps what they already had.
///
/// Encryption can't make anyone read-only (a reader holds the key), so roles are enforced by signatures: devices
/// ignore change-log entries from members without write access. A writer who is removed or made read-only becomes a
/// former writer, and the entries they wrote until then (`writesUntil`, per device) still count.
///
/// The file is JSON: `{"format":1,"list":<base64 of the list's JSON>,"signature":<base64>}`; the signature covers
/// `"v57-members-1"` followed by the list's bytes exactly as stored.
public struct FolderMembers: Sendable, Equatable {
  public typealias Role = VaultPerson.Role

  public struct Member: Sendable, Equatable {
    public var identity: PublicIdentity
    public var name: String
    public var role: Role
    /// The folder key of each epoch, sealed to this member.
    var wrappedKeys: [Int: Data]
  }

  /// Someone who could write once. Their entries up to `writesUntil[device]` (a change-log sequence number) count.
  public struct FormerWriter: Sendable, Equatable {
    public var signingKey: Data
    public var name: String
    public var writesUntil: [String: Int]
  }

  public let folderID: String
  public private(set) var version: Int
  /// The current key epoch: new chunks and logs are sealed with its key.
  public private(set) var epoch: Int
  public let owner: PublicIdentity
  public private(set) var members: [Member]
  /// The folder key id of each epoch (what encrypted files name in their headers).
  public private(set) var keyIDs: [Int: String]
  public private(set) var formerWriters: [FormerWriter]
  /// The signed bytes and their signature, as in the file.
  public private(set) var listData: Data
  public private(set) var signature: Data

  static let fileName = "members"
  static let signingPrefix = Data("v57-members-1".utf8)

  // MARK: Making and reading

  /// A new list for a folder: the owner as its only member (read-write), holding `key` as epoch 0. For a folder of
  /// the user's own, pass the folder's existing key (`VaultFolder.wrappedKey`), so the key the vault keeps opens it.
  public static func create(
    folderID: String, owner: PersonalIdentity, ownerName: String, key: FolderKey = FolderKey()
  ) throws -> FolderMembers {
    let ownerPublic = owner.publicIdentity
    var list = FolderMembers(
      folderID: folderID, version: 0, epoch: 0, owner: ownerPublic, members: [], keyIDs: [0: key.id],
      formerWriters: [], listData: Data(), signature: Data())
    list.members = [
      Member(
        identity: ownerPublic, name: ownerName, role: .readWrite,
        wrappedKeys: [0: try list.wrap(key, epoch: 0, to: ownerPublic)])
    ]
    try list.sign(by: owner, bump: false)
    return list
  }

  /// Reads a `members` file and checks it: signed by `ownerSigningKey`, for `folderID`, and not older than
  /// `minimumVersion` (the highest version this device saw).
  public init(verifying data: Data, folderID: String, ownerSigningKey: Data, minimumVersion: Int = 0) throws {
    guard let file = try? JSONDecoder().decode(FileForm.self, from: data), file.format == 1,
      let listData = Data(base64Encoded: file.list), let signature = Data(base64Encoded: file.signature)
    else { throw FolderSyncError.damaged("member list") }
    guard let ownerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: ownerSigningKey),
      ownerKey.isValidSignature(signature, for: Self.signingPrefix + listData)
    else { throw FolderSyncError.notSignedByOwner }
    guard let list = try? JSONDecoder().decode(ListForm.self, from: listData),
      let owner = PublicIdentity(list.owner)
    else { throw FolderSyncError.damaged("member list") }
    guard owner.signingKey == ownerSigningKey else { throw FolderSyncError.notSignedByOwner }
    guard list.folder == folderID else { throw FolderSyncError.wrongFolder }
    guard list.version >= minimumVersion else {
      throw FolderSyncError.olderMemberList(found: list.version, known: minimumVersion)
    }
    var members: [Member] = []
    for member in list.members {
      guard let identity = PublicIdentity(member.id), let role = Role(rawValue: member.role) else {
        throw FolderSyncError.damaged("member list")
      }
      var keys: [Int: Data] = [:]
      for (epoch, sealed) in member.keys {
        guard let epoch = Int(epoch), let sealed = Data(base64Encoded: sealed) else {
          throw FolderSyncError.damaged("member list")
        }
        keys[epoch] = sealed
      }
      members.append(Member(identity: identity, name: member.name, role: role, wrappedKeys: keys))
    }
    var keyIDs: [Int: String] = [:]
    for (epoch, id) in list.keyIDs {
      guard let epoch = Int(epoch) else { throw FolderSyncError.damaged("member list") }
      keyIDs[epoch] = id
    }
    let former = try list.former.map { writer -> FormerWriter in
      guard let key = Data(base64Encoded: writer.signingKey) else { throw FolderSyncError.damaged("member list") }
      return FormerWriter(signingKey: key, name: writer.name, writesUntil: writer.writesUntil)
    }
    guard keyIDs[list.epoch] != nil, members.contains(where: { $0.identity == owner && $0.role == .readWrite })
    else { throw FolderSyncError.damaged("member list") }
    self.init(
      folderID: list.folder, version: list.version, epoch: list.epoch, owner: owner, members: members,
      keyIDs: keyIDs, formerWriters: former, listData: listData, signature: signature)
  }

  /// The `members` file's contents.
  public var fileData: Data {
    let file = FileForm(format: 1, list: listData.base64EncodedString(), signature: signature.base64EncodedString())
    return (try? Self.encoder.encode(file)) ?? Data()
  }

  /// Reads the folder's `members` file from the remote and checks it (see `init(verifying:…)`).
  public static func read(
    from remote: any RemoteFileSystem, folderPath: String, folderID: String, ownerSigningKey: Data,
    minimumVersion: Int = 0
  ) async throws -> FolderMembers {
    let path = RemotePath.join(folderPath, fileName)
    guard try await remote.stat(path) != nil else { throw FolderSyncError.noMemberList }
    return try FolderMembers(
      verifying: try await remote.read(path), folderID: folderID, ownerSigningKey: ownerSigningKey,
      minimumVersion: minimumVersion)
  }

  /// Writes the list as the folder's `members` file.
  public func write(to remote: any RemoteFileSystem, folderPath: String) async throws {
    try await remote.write(fileData, to: RemotePath.join(folderPath, Self.fileName))
  }

  // MARK: Reading the list

  public func member(signingKey: Data) -> Member? {
    members.first { $0.identity.signingKey == signingKey }
  }

  public func role(of signingKey: Data) -> Role? { member(signingKey: signingKey)?.role }

  /// Whether a change-log entry signed with `signingKey`, from `device`'s log at `sequence`, counts: a member
  /// with write access, or a former writer's entry from before they lost it.
  public func canWrite(signingKey: Data, device: String, sequence: Int) -> Bool {
    if role(of: signingKey) == .readWrite { return true }
    return formerWriters.contains { $0.signingKey == signingKey && sequence <= $0.writesUntil[device] ?? 0 }
  }

  /// The folder keys `identity` can open: every epoch it was given, the current one included.
  public func keyring(for identity: PersonalIdentity) throws -> FolderKeyring {
    guard let member = member(signingKey: identity.publicIdentity.signingKey) else { throw FolderSyncError.notAMember }
    var keys: [Int: FolderKey] = [:]
    for (epoch, sealed) in member.wrappedKeys {
      guard let id = keyIDs[epoch] else { continue }
      let key = try KeyWrap.open(sealed, with: identity, context: wrapContext(epoch: epoch))
      keys[epoch] = try FolderKey(id: id, keyData: key)
    }
    guard keys[epoch] != nil else { throw FolderSyncError.missingKey(keyIDs[epoch] ?? "\(epoch)") }
    return FolderKeyring(epoch: epoch, keys: keys)
  }

  // MARK: Changes (the owner's)

  /// Adds someone, with every epoch's key wrapped to them (they read the whole folder), or changes the role of a
  /// member already there.
  public mutating func add(_ identity: PublicIdentity, name: String, role: Role, owner: PersonalIdentity) throws {
    try checkOwner(owner)
    if member(signingKey: identity.signingKey) != nil {
      try setRole(role, for: identity.signingKey, owner: owner)
      return
    }
    let keyring = try keyring(for: owner)
    var wrapped: [Int: Data] = [:]
    for (epoch, key) in keyring.keys { wrapped[epoch] = try wrap(key, epoch: epoch, to: identity) }
    members.append(Member(identity: identity, name: name, role: role, wrappedKeys: wrapped))
    try sign(by: owner)
  }

  /// Changes a member's role. Making a writer read-only keeps the entries they wrote until now (`writesUntil`, the
  /// last sequence number of each of their devices' logs this device read; `FolderSync.writesUntil(signingKey:)`).
  public mutating func setRole(
    _ role: Role, for signingKey: Data, owner: PersonalIdentity, writesUntil: [String: Int] = [:]
  ) throws {
    try checkOwner(owner)
    guard let index = members.firstIndex(where: { $0.identity.signingKey == signingKey }) else {
      throw FolderSyncError.unknownMember
    }
    guard signingKey != self.owner.signingKey else { throw FolderSyncError.cannotChangeOwner }
    guard members[index].role != role else { return }
    if members[index].role == .readWrite {
      keepFormerWrites(of: members[index], writesUntil: writesUntil)
    } else {
      formerWriters.removeAll { $0.signingKey == signingKey }
    }
    members[index].role = role
    try sign(by: owner)
  }

  /// Removes a member and rotates the key: returns the new epoch's key. Entries they wrote until now still count
  /// (`writesUntil`, as for `setRole`).
  @discardableResult
  public mutating func remove(signingKey: Data, owner: PersonalIdentity, writesUntil: [String: Int] = [:]) throws
    -> FolderKey
  {
    try checkOwner(owner)
    guard signingKey != self.owner.signingKey else { throw FolderSyncError.cannotChangeOwner }
    guard let index = members.firstIndex(where: { $0.identity.signingKey == signingKey }) else {
      throw FolderSyncError.unknownMember
    }
    if members[index].role == .readWrite { keepFormerWrites(of: members[index], writesUntil: writesUntil) }
    members.remove(at: index)
    return try rotate(owner: owner)
  }

  /// Starts a new key epoch: a new folder key, wrapped to every member, used for everything written from now on.
  @discardableResult
  public mutating func rotate(owner: PersonalIdentity) throws -> FolderKey {
    try checkOwner(owner)
    let key = FolderKey()
    let next = (keyIDs.keys.max() ?? epoch) + 1
    for index in members.indices {
      members[index].wrappedKeys[next] = try wrap(key, epoch: next, to: members[index].identity)
    }
    keyIDs[next] = key.id
    epoch = next
    try sign(by: owner)
    return key
  }

  // MARK: Internals

  private init(
    folderID: String, version: Int, epoch: Int, owner: PublicIdentity, members: [Member], keyIDs: [Int: String],
    formerWriters: [FormerWriter], listData: Data, signature: Data
  ) {
    self.folderID = folderID
    self.version = version
    self.epoch = epoch
    self.owner = owner
    self.members = members
    self.keyIDs = keyIDs
    self.formerWriters = formerWriters
    self.listData = listData
    self.signature = signature
  }

  private mutating func keepFormerWrites(of member: Member, writesUntil: [String: Int]) {
    let key = member.identity.signingKey
    if let index = formerWriters.firstIndex(where: { $0.signingKey == key }) {
      formerWriters[index].writesUntil.merge(writesUntil) { max($0, $1) }
    } else if !writesUntil.isEmpty {
      formerWriters.append(FormerWriter(signingKey: key, name: member.name, writesUntil: writesUntil))
    }
  }

  private func checkOwner(_ owner: PersonalIdentity) throws {
    guard owner.publicIdentity.signingKey == self.owner.signingKey else { throw FolderSyncError.notOwner }
  }

  func wrapContext(epoch: Int) -> Data { Data("dev.v57.sync.members|\(folderID)|\(epoch)".utf8) }

  private func wrap(_ key: FolderKey, epoch: Int, to identity: PublicIdentity) throws -> Data {
    try KeyWrap.seal(key.keyData, to: identity, context: wrapContext(epoch: epoch))
  }

  private mutating func sign(by owner: PersonalIdentity, bump: Bool = true) throws {
    if bump { version += 1 }
    let list = ListForm(
      folder: folderID, version: version, epoch: epoch, owner: owner.publicIdentity.text,
      keyIDs: Dictionary(uniqueKeysWithValues: keyIDs.map { (String($0.key), $0.value) }),
      members: members.map { member in
        ListForm.MemberForm(
          id: member.identity.text, name: member.name, role: member.role.rawValue,
          keys: Dictionary(uniqueKeysWithValues: member.wrappedKeys.map { (String($0.key), $0.value.base64EncodedString()) }))
      },
      former: formerWriters.map {
        ListForm.FormerForm(signingKey: $0.signingKey.base64EncodedString(), name: $0.name, writesUntil: $0.writesUntil)
      })
    listData = try Self.encoder.encode(list)
    signature = try owner.signature(for: Self.signingPrefix + listData)
  }

  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private struct FileForm: Codable {
    var format: Int
    var list: String
    var signature: String
  }

  private struct ListForm: Codable {
    struct MemberForm: Codable {
      var id: String
      var name: String
      var role: String
      var keys: [String: String]
    }

    struct FormerForm: Codable {
      var signingKey: String
      var name: String
      var writesUntil: [String: Int]
    }

    var folder: String
    var version: Int
    var epoch: Int
    var owner: String
    var keyIDs: [String: String]
    var members: [MemberForm]
    var former: [FormerForm]
  }
}

/// The folder keys a member holds, by epoch: the current one seals what is written now, the older ones open what
/// was written before.
public struct FolderKeyring: Sendable, Equatable {
  public let epoch: Int
  public let keys: [Int: FolderKey]

  public init(epoch: Int, keys: [Int: FolderKey]) {
    self.epoch = epoch
    self.keys = keys
  }

  /// The key new chunks and logs are sealed with.
  public var current: FolderKey { keys[epoch]! }

  /// The key the folder started with (epoch 0, or the oldest this member holds).
  public var first: FolderKey { keys[keys.keys.min()!]! }

  /// The key with this id (from an encrypted file's header).
  public func key(id: String) -> FolderKey? { keys.values.first { $0.id == id } }
}
