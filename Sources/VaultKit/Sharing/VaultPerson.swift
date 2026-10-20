import CryptoKit
import Foundation

/// Someone the user shares folders with: their public keys, whether the user compared the safety code with
/// them, and their role in each shared folder (`role.<folderID>`, one field per folder so two devices changing
/// different folders merge).
public struct VaultPerson: VaultRecord, Hashable {
  public static let kind = "person"
  public static let dynamicPrefixes = ["role."]

  public enum Status: String, Sendable, CaseIterable {
    /// Invited; their keys haven't arrived yet.
    case invited
    /// Their keys are here, but the safety code hasn't been compared.
    case waiting
    /// The safety code matched.
    case verified
  }

  public enum Role: String, Sendable, CaseIterable {
    case readWrite
    case readOnly
  }

  public var id: String
  public var name: String
  /// Ed25519 public key, base64.
  public var signingKey: String?
  /// X25519 public key, base64.
  public var agreementKey: String?
  public var status: Status
  /// When the safety code matched.
  public var verified: Date?
  /// Role by folder id.
  public var roles: [String: Role]
  public var created: Date?

  public init(
    id: String = UUID().uuidString, name: String, identity: PublicIdentity? = nil, status: Status? = nil,
    verified: Date? = nil, roles: [String: Role] = [:], created: Date? = .now
  ) {
    self.id = id
    self.name = name
    signingKey = identity?.signingKey.base64EncodedString()
    agreementKey = identity?.agreementKey.base64EncodedString()
    self.status = status ?? (identity == nil ? .invited : .waiting)
    self.verified = verified?.wholeSeconds
    self.roles = roles
    self.created = created?.wholeSeconds
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    signingKey = read.string("signingKey")
    agreementKey = read.string("agreementKey")
    status = read.string("status").flatMap(Status.init) ?? .invited
    verified = read.date("verified")
    roles = read.strings(prefixed: "role").compactMapValues(Role.init)
    created = read.date("created")
  }

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "name": .string(name), "signingKey": .init(signingKey), "agreementKey": .init(agreementKey),
      "status": .string(status.rawValue), "verified": .init(verified), "created": .init(created),
    ]
    values.set(roles.mapValues(\.rawValue), prefixed: "role")
    return values
  }

  /// Their keys, nil until they arrive.
  public var identity: PublicIdentity? {
    get {
      guard let signing = signingKey.flatMap({ Data(base64Encoded: $0) }),
        let agreement = agreementKey.flatMap({ Data(base64Encoded: $0) })
      else { return nil }
      return try? PublicIdentity(signingKey: signing, agreementKey: agreement)
    }
    set {
      signingKey = newValue?.signingKey.base64EncodedString()
      agreementKey = newValue?.agreementKey.base64EncodedString()
    }
  }

  public func role(in folderID: String) -> Role? { roles[folderID] }
}

extension VaultStore {
  /// The person with this signing key, if any.
  public func person(signingKey: Data) throws -> VaultPerson? {
    let key = signingKey.base64EncodedString()
    return try records(VaultPerson.self).first { $0.signingKey == key }
  }

  /// Adds someone whose keys arrived (from an invite or a reply): the person who already has these keys, else
  /// the invited person `personID` (keys set, back to `waiting`: a new key means comparing the safety code
  /// again), else a new person.
  @discardableResult
  public func addPerson(_ identity: PublicIdentity, name: String, personID id: String? = nil) throws -> VaultPerson {
    if let existing = try person(signingKey: identity.signingKey) {
      var person = existing
      if person.name.isEmpty { person.name = name }
      try save(person)
      return person
    }
    var person = try id.flatMap { try record(VaultPerson.self, id: $0) } ?? VaultPerson(name: name)
    if person.name.isEmpty { person.name = name }
    person.identity = identity
    person.status = .waiting
    person.verified = nil
    try save(person)
    return person
  }

  /// Notes that the safety code matched.
  public func markVerified(personID: String, now: Date = .now) throws {
    guard var person = try record(VaultPerson.self, id: personID), person.identity != nil else { return }
    person.status = .verified
    person.verified = now.wholeSeconds
    try save(person)
  }
}

/// An invitation to share: the inviter's public keys and name, optionally a folder and role, signed by the
/// inviter. It travels as a link or QR code (`url`, `v57vault://invite?…`).
///
/// The signature shows the invite wasn't changed after it was made, not who made it: someone who swaps the
/// whole invite can sign their own. Comparing the safety code (`SafetyCode`) rules that out.
public struct VaultInvite: Sendable, Hashable {
  public var identity: PublicIdentity
  public var name: String
  public var folderID: String?
  public var folderName: String?
  public var role: VaultPerson.Role?
  public var created: Date
  public var signature: Data

  public static let scheme = "v57vault"

  /// A new invite signed with the user's identity.
  public static func make(
    from identity: PersonalIdentity, name: String, folderID: String? = nil, folderName: String? = nil,
    role: VaultPerson.Role? = nil, created: Date = .now
  ) throws -> VaultInvite {
    var invite = VaultInvite(
      identity: identity.publicIdentity, name: name, folderID: folderID, folderName: folderName, role: role,
      created: Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded(.down)), signature: Data())
    invite.signature = try identity.signature(for: invite.signedBytes)
    return invite
  }

  init(
    identity: PublicIdentity, name: String, folderID: String?, folderName: String?, role: VaultPerson.Role?,
    created: Date, signature: Data
  ) {
    self.identity = identity
    self.name = name
    self.folderID = folderID
    self.folderName = folderName
    self.role = role
    self.created = created
    self.signature = signature
  }

  /// Whether the signature matches the invite's contents.
  public var isSignatureValid: Bool { identity.isValidSignature(signature, for: signedBytes) }

  var signedBytes: Data {
    SSHWire.string("v57vault-invite-1") + SSHWire.string(identity.text) + SSHWire.string(name)
      + SSHWire.string(folderID ?? "") + SSHWire.string(folderName ?? "") + SSHWire.string(role?.rawValue ?? "")
      + SSHWire.string(String(Int64(created.timeIntervalSince1970)))
  }

  /// `v57vault://invite?id=…&name=…&folder=…&folderName=…&role=…&t=…&sig=…`.
  public var url: String {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = "invite"
    var items = [
      URLQueryItem(name: "id", value: String(identity.text.dropFirst(PublicIdentity.prefix.count))),
      URLQueryItem(name: "name", value: name),
    ]
    if let folderID { items.append(URLQueryItem(name: "folder", value: folderID)) }
    if let folderName { items.append(URLQueryItem(name: "folderName", value: folderName)) }
    if let role { items.append(URLQueryItem(name: "role", value: role.rawValue)) }
    items.append(URLQueryItem(name: "t", value: String(Int64(created.timeIntervalSince1970))))
    items.append(URLQueryItem(name: "sig", value: signature.base64URL))
    components.queryItems = items
    // `+` is legal in a query but read as a space by some decoders; spell it out.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return components.string ?? ""
  }

  /// Reads an invite link; nil when it isn't one or its signature doesn't match.
  public init?(url text: String) {
    guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      components.scheme == Self.scheme, components.host == "invite"
    else { return nil }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
    guard let id = query["id"], let identity = PublicIdentity(PublicIdentity.prefix + id),
      let name = query["name"], let time = query["t"].flatMap(Int64.init),
      let signature = query["sig"].flatMap({ Data(base64URL: $0) })
    else { return nil }
    var role: VaultPerson.Role?
    if let roleText = query["role"] {
      guard let parsed = VaultPerson.Role(rawValue: roleText) else { return nil }
      role = parsed
    }
    self.init(
      identity: identity, name: name, folderID: query["folder"], folderName: query["folderName"], role: role,
      created: Date(timeIntervalSince1970: TimeInterval(time)), signature: signature)
    guard isSignatureValid else { return nil }
  }
}
