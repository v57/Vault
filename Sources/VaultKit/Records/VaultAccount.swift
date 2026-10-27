import Foundation

/// An account: the vault of one organization the user works for (a client, an employer), next to Personal.
///
/// Each account keeps its records apart (passwords, projects, hosts, configs, settings): its own store file
/// (`<id>.sqlite` next to Personal's `Vault.sqlite`), CloudKit zone (`Vault-<id>`) and Hub mailbox, so deleting it
/// removes exactly what it holds. Every account seals with the same vault keys as Personal, and the device's identity
/// (its SSH key) is the same in all of them. The records describing the accounts live in Personal; `Vaults` opens
/// each account's vault. Personal itself has no record: it is `VaultAccount.personal`.
public struct VaultAccount: VaultRecord, Hashable {
  public static let kind = "account"

  public enum Role: String, Sendable, Hashable {
    /// The user made it.
    case owner
    /// Someone shared it with the user.
    case member
  }

  public var id: String
  public var name: String
  /// Its tile's color in the account picker: a ComponentKit accent name.
  public var color: String
  public var role: Role

  public init(id: String = VaultAccount.newID(), name: String, color: String = "blue", role: Role = .owner) {
    self.id = id
    self.name = name
    self.color = color
    self.role = role
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    color = read.string("color", default: "blue")
    role = read.string("role").flatMap(Role.init(rawValue:)) ?? .owner
  }

  public var values: [String: JSONValue] {
    ["name": .string(name), "color": .string(color), "role": .string(role.rawValue)]
  }

  /// Personal: today's vault (`Vault.sqlite`, the `Vault` zone, the `hub-vault` mailbox), which always exists.
  public static let personal = VaultAccount(id: "personal", name: "Personal", color: "gray", role: .owner)

  public var isPersonal: Bool { id == Self.personal.id }

  /// Its CloudKit zone.
  public var zoneName: String { isPersonal ? SyncZones.personalZone : SyncZones.zoneName(forAccount: id) }

  /// A new account's id: lowercase hex, safe in file and zone names.
  public static func newID() -> String {
    (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }

  /// Whether `id` can name an account's files and zone (made by `newID`, or another device's build of it).
  static func isValidID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && id != personal.id
      && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
  }
}

/// An Apple developer team an account works with. A project keeps its own `DEVELOPMENT_TEAM`; the account that holds
/// that team is the one whose keys sign and upload it (`Vaults.account(forTeam:)`).
public struct VaultAppleTeam: VaultRecord, Hashable {
  public static let kind = "appleTeam"

  public var id: String
  /// The ten-character team id (`DEVELOPMENT_TEAM`).
  public var teamID: String
  public var name: String

  public init(id: String = UUID().uuidString, teamID: String, name: String) {
    self.id = id
    self.teamID = teamID
    self.name = name
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    teamID = read.string("teamID", default: "")
    name = read.string("name", default: "")
  }

  public var values: [String: JSONValue] {
    ["teamID": .string(teamID), "name": .string(name)]
  }
}
