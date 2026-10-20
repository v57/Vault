import Foundation

/// What can go wrong with a synced folder's member list or its sync.
public enum FolderSyncError: LocalizedError, Equatable {
  /// The member list isn't signed by the folder's owner (or was changed after signing).
  case notSignedByOwner
  /// The member list belongs to another folder.
  case wrongFolder
  /// The member list is older than one this device already saw: someone put an old copy back.
  case olderMemberList(found: Int, known: Int)
  /// The remote has no member list at this folder.
  case noMemberList
  /// This person isn't (or is no longer) a member of the folder.
  case notAMember
  /// Only the owner changes the member list.
  case notOwner
  /// No member with these keys.
  case unknownMember
  /// The owner can't be removed or made read-only.
  case cannotChangeOwner
  /// Data on the remote is damaged or not in the format.
  case damaged(String)
  /// A key epoch this device can't open.
  case missingKey(String)
  /// The device id can't be used as a folder name on the remote.
  case invalidDevice(String)
  /// There is already a shared folder at this path on the remote.
  case folderExists

  public var errorDescription: String? {
    switch self {
    case .notSignedByOwner: "The folder's member list isn't signed by its owner."
    case .wrongFolder: "The member list belongs to another folder."
    case .olderMemberList(let found, let known):
      "The folder's member list is older (version \(found)) than one this device saw (version \(known))."
    case .noMemberList: "There's no shared folder here."
    case .notAMember: "You aren't a member of this folder."
    case .notOwner: "Only the folder's owner can change its members."
    case .unknownMember: "That person isn't a member of this folder."
    case .cannotChangeOwner: "The owner stays a member with read-write access."
    case .damaged(let what): "Damaged data on the remote: \(what)."
    case .missingKey(let id): "This device doesn't have the folder key \(id)."
    case .invalidDevice(let id): "“\(id)” can't be used as a device name."
    case .folderExists: "There's already a synced folder at this place on the remote."
    }
  }
}
