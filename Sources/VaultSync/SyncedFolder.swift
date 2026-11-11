import Foundation
import VaultKit

/// A `VaultFolder` record as the engine needs it: where it is on its remote, whose key signs its member list, and the
/// record a person makes when someone shares a folder with them.
extension VaultFolder {
  /// The folder's path on its remote, under the remote's own folder: `remotePath`, or the folder's id.
  public var syncPath: String { remotePath.flatMap { $0.isEmpty ? nil : $0 } ?? id }

  /// The Ed25519 key that must sign the member list: the owner's for a folder someone shared, else `identity`'s
  /// (a folder of the user's own).
  public func ownerSigningKey(for identity: PersonalIdentity) throws -> Data {
    guard let ownerSigningKey else { return identity.publicIdentity.signingKey }
    guard let key = Data(base64Encoded: ownerSigningKey), key.count == 32 else {
      throw FolderSyncError.damaged("the owner’s key in the folder record")
    }
    return key
  }

  /// Whether `identity` owns the folder: it has no other owner, or the owner is `identity`.
  public func isOwned(by identity: PersonalIdentity) -> Bool {
    ownerSigningKey == nil || ownerSigningKey == identity.publicIdentity.signingKey.base64EncodedString()
  }

  /// The record for a folder someone shared through `invite` (their invite names it): its id and name, and the
  /// inviter as the owner whose key signs its member list. The remote and where it's kept on this device are still
  /// to choose. nil when the invite names no folder or isn't validly signed.
  public static func shared(by invite: VaultInvite) -> VaultFolder? {
    guard invite.isSignatureValid, let id = invite.folderID, !id.isEmpty, !id.contains("/") else { return nil }
    let name = invite.folderName.flatMap { $0.isEmpty ? nil : $0 } ?? "Shared folder"
    return VaultFolder(
      id: id, name: name, encrypted: false, remotePath: id,
      ownerSigningKey: invite.identity.signingKey.base64EncodedString())
  }
}

extension FolderSync.Configuration {
  /// The configuration for `folder` on this device: its remote, its path there, the owner's key, this device's
  /// mode, and its state in `stateDirectory` (one sealed file per folder; nil keeps it in memory).
  public init(
    folder: VaultFolder, remote: any RemoteFileSystem, local: any SyncLocalFolder, device: String,
    identity: PersonalIdentity, stateDirectory: URL?
  ) throws {
    self.init(
      folderID: folder.id, remote: remote, remotePath: folder.syncPath, local: local, device: device,
      identity: identity, ownerSigningKey: try folder.ownerSigningKey(for: identity), mode: folder.mode(for: device),
      stateURL: stateDirectory?.appendingPathComponent("\(folder.id).v57sync"))
  }
}
