import ComponentKit
import Foundation
import VaultKit

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
  /// list, which comes with folder sync. Until then Share stops before adding.
  var deliversFolderKeys: Bool { get }
  func safetyCode(with person: PersonItem) -> [String]?
  func inviteLink(folderID: String?, folderName: String?, role: VaultPerson.Role?) throws -> String
  func verify(_ personID: String)
  func add(_ personID: String, to folderID: String, role: VaultPerson.Role) throws
  func remove(_ personID: String)
  /// The first name of whoever an item (a login) is shared with, if anyone.
  func sharedWith(_ itemID: String) -> String?
  /// Opens an invite link (`v57vault://invite?…`).
  func open(_ url: URL)
  /// Adds the person an invite came from (keys arrived; the safety code still to compare).
  func accept(_ invite: VaultInvite)
}

/// People from the vault's records, the identity from iCloud Keychain (memory in demo runs), safety codes and
/// invites from VaultKit.
@MainActor
final class PeopleLibrary: SharingService {
  let vault: Vault
  let deliversFolderKeys: Bool
  private let sharedItems: [String: String]

  init(vault: Vault, deliversFolderKeys: Bool = false, sharedItems: [String: String] = [:]) {
    self.vault = vault
    self.deliversFolderKeys = deliversFolderKeys
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

  func add(_ personID: String, to folderID: String, role: VaultPerson.Role) throws {
    guard deliversFolderKeys else { throw NotYetAvailable(what: "Sending a folder's key to a new member") }
    guard var person = vault.people.first(where: { $0.id == personID }) else { return }
    person.roles[folderID] = role
    vault.save(person)
  }

  func remove(_ personID: String) {
    guard let person = vault.people.first(where: { $0.id == personID }) else { return }
    vault.delete(person)
  }

  func sharedWith(_ itemID: String) -> String? { sharedItems[itemID] }

  func open(_ url: URL) {
    guard let invite = VaultInvite(url: url.absoluteString), invite.isSignatureValid else { return }
    accept(invite)
  }

  func accept(_ invite: VaultInvite) {
    vault.perform { try $0.addPerson(invite.identity, name: invite.name) }
  }
}
