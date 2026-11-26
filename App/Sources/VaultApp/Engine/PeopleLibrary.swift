import ComponentKit
import Foundation
import VaultKit
import VaultSync

/// Someone the user shares with, as the screens show them.
struct PersonItem: Identifiable, Hashable {
  var record: VaultPerson
  var id: String { record.id }
  var name: String { record.name }
  var identity: PublicIdentity? { record.identity }
  var status: VaultPerson.Status { record.status }
}

/// Sharing with people: identities, invites, safety codes, members of folders.
@MainActor
protocol SharingService: AnyObject {
  var people: [PersonItem] { get }
  /// The user's identity, if they've made one (made only when they start sharing).
  var identity: PublicIdentity? { get }
  /// Whether a folder's key can reach a new member: it travels through the folder's remote in the signed member
  /// list, so the folder must sync through one, and only its owner signs that list.
  func deliversKey(to folderID: String) -> Bool
  func safetyCode(with person: PersonItem) -> [String]?
  func inviteLink(folderID: String?, folderName: String?, role: VaultPerson.Role?) throws -> String
  func verify(_ personID: String)
  func add(_ personID: String, to folderID: String, role: VaultPerson.Role) async throws
  func remove(_ personID: String)
  /// The first name of whoever an item (a login) is shared with, if anyone.
  func sharedWith(_ itemID: String) -> String?
  /// Opens an invite link (`v57vault://invite?…`).
  func open(_ url: URL)
  /// Adds the person an invite came from (keys arrived; the safety code still to compare), and the folder it names,
  /// which waits for a remote and a place on this device.
  func accept(_ invite: VaultInvite)
}

/// People from the vault's records, the identity from iCloud Keychain (memory in demo runs), safety codes and
/// invites from VaultKit. A folder's key reaches a member through the folder sync engine (the signed member list on
/// the folder's remote).
@MainActor
final class PeopleLibrary: SharingService {
  let vault: Vault
  private let folderSync: (any FolderSyncEngine)?
  private let sharedItems: [String: String]

  init(vault: Vault, folderSync: (any FolderSyncEngine)?, sharedItems: [String: String] = [:]) {
    self.vault = vault
    self.folderSync = folderSync
    self.sharedItems = sharedItems
  }

  var people: [PersonItem] { vault.people.map(PersonItem.init(record:)) }

  var identity: PublicIdentity? { (try? VaultPersonalIdentity.existing())?.publicIdentity }

  func safetyCode(with person: PersonItem) -> [String]? {
    guard let mine = identity, let theirs = person.identity else { return nil }
    return SafetyCode.compute(mine, theirs)
  }

  func inviteLink(folderID: String?, folderName: String?, role: VaultPerson.Role?) throws -> String {
    let identity = try VaultPersonalIdentity.current()
    return try VaultInvite.make(from: identity, name: KitDevice.name, folderID: folderID, folderName: folderName, role: role).url
  }

  func verify(_ personID: String) {
    vault.perform { try $0.markVerified(personID: personID) }
  }

  func deliversKey(to folderID: String) -> Bool { folderSync?.deliversKeys(for: folderID) ?? false }

  func add(_ personID: String, to folderID: String, role: VaultPerson.Role) async throws {
    guard let folderSync, folderSync.deliversKeys(for: folderID) else {
      throw SyncSetupError(
        String(localized: "Sync this folder through a remote first: its key reaches new members in the member list there."))
    }
    guard var person = vault.people.first(where: { $0.id == personID }) else { return }
    guard let identity = person.identity else { throw SyncSetupError(String(localized: "Their key hasn’t arrived yet.")) }
    try await folderSync.addMember(identity, name: person.name, role: role, to: folderID)
    person.roles[folderID] = role
    vault.save(person)
  }

  func remove(_ personID: String) {
    guard let person = vault.people.first(where: { $0.id == personID }) else { return }
    // Out of every folder's member list first (a new key for each), then out of the vault.
    if let folderSync, let identity = person.identity {
      let folders = person.roles.keys.filter { folderSync.deliversKeys(for: $0) }
      Task {
        for folder in folders { try? await folderSync.removeMember(identity, from: folder) }
      }
    }
    vault.delete(person)
  }

  func sharedWith(_ itemID: String) -> String? { sharedItems[itemID] }

  func open(_ url: URL) {
    guard let invite = VaultInvite(url: url.absoluteString), invite.isSignatureValid else { return }
    accept(invite)
  }

  func accept(_ invite: VaultInvite) {
    vault.perform { try $0.addPerson(invite.identity, name: invite.name) }
    // A folder the invite shares: it shows in Folders, waiting for its remote and a place here.
    if var folder = VaultFolder.shared(by: invite), !vault.folders.contains(where: { $0.id == folder.id }) {
      folder.order = vault.folders.count
      vault.save(folder)
    }
  }
}
