import CryptoKit
import Foundation

/// A passkey: a P-256 key a website (the relying party) knows the public half of. The private key is a
/// `VaultSecrets` item (`passkey.<id>`), so it syncs through iCloud Keychain like the passwords; the record keeps
/// what AutoFill needs to offer it (the site, the account, the credential id).
///
/// A passkey belongs to a login (`login`): the one for the same site and username when it was made, else a new
/// one, so the logins list shows every account once, with its password, code and passkey.
public struct VaultPasskey: VaultRecord, Hashable {
  public static let kind = "passkey"

  public var id: String
  /// The relying party id the site registered it for ("github.com").
  public var relyingParty: String
  public var userName: String
  /// The site's id for the account.
  public var userHandle: Data
  /// The id the site looks the passkey up by.
  public var credentialID: Data
  /// The login it belongs to.
  public var login: String?
  public var created: Date?

  public init(
    id: String = UUID().uuidString, relyingParty: String, userName: String, userHandle: Data, credentialID: Data,
    login: String? = nil, created: Date? = .now
  ) {
    self.id = id
    self.relyingParty = relyingParty
    self.userName = userName
    self.userHandle = userHandle
    self.credentialID = credentialID
    self.login = login
    self.created = created?.wholeSeconds
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    relyingParty = read.string("relyingParty", default: "")
    userName = read.string("userName", default: "")
    userHandle = read.data("userHandle") ?? Data()
    credentialID = read.data("credentialID") ?? Data()
    login = read.string("login")
    created = read.date("created")
  }

  public var values: [String: JSONValue] {
    [
      "relyingParty": .string(relyingParty), "userName": .string(userName),
      "userHandle": .string(userHandle.base64EncodedString()), "credentialID": .string(credentialID.base64EncodedString()),
      "login": .init(login), "created": .init(created),
    ]
  }

  /// The private key, nil when its keychain item hasn't arrived on this device yet.
  public var privateKey: P256.Signing.PrivateKey? {
    VaultSecrets.secret(Self.keySecret(id)).flatMap { try? P256.Signing.PrivateKey(rawRepresentation: $0) }
  }

  /// Signs in to the site: the authenticator data and the signature over it and the client data's hash.
  public func assertion(clientDataHash: Data, userVerified: Bool) throws -> (authenticatorData: Data, signature: Data) {
    guard let key = privateKey else { throw VaultStore.PasskeyError.missingKey }
    return try WebAuthn.assertion(relyingParty: relyingParty, clientDataHash: clientDataHash, key: key, userVerified: userVerified)
  }

  /// The `VaultSecrets` name of a passkey's private key.
  public static func keySecret(_ id: String) -> String { "passkey.\(id)" }
}

extension VaultStore {
  public enum PasskeyError: LocalizedError {
    case missingKey

    public var errorDescription: String? {
      switch self {
      case .missingKey: "This passkey’s key hasn’t synced to this device yet."
      }
    }
  }

  /// A new passkey and what the site gets back for it.
  public struct PasskeyRegistration: Sendable {
    public var passkey: VaultPasskey
    /// The CBOR attestation object ("none" attestation, the new public key inside).
    public var attestationObject: Data
  }

  /// Makes a passkey for a site's account: a new P-256 key (kept in `VaultSecrets`), linked to the login for the
  /// same site and username, or a new login. A passkey the account already had at that site is replaced, as
  /// WebAuthn asks.
  public func createPasskey(
    relyingParty: String, userName: String, userHandle: Data, userVerified: Bool, now: Date = .now
  ) throws -> PasskeyRegistration {
    let relyingParty = relyingParty.lowercased()
    for old in try records(VaultPasskey.self) where old.relyingParty == relyingParty && old.userHandle == userHandle {
      try deletePasskey(id: old.id)
    }
    let login = try loginForPasskey(relyingParty: relyingParty, userName: userName, now: now)
    let key = P256.Signing.PrivateKey()
    var credentialID = Data(count: 16)
    for index in credentialID.indices { credentialID[index] = UInt8.random(in: 0...255) }
    let passkey = VaultPasskey(
      relyingParty: relyingParty, userName: userName, userHandle: userHandle, credentialID: credentialID, login: login,
      created: now)
    try VaultSecrets.setSecret(key.rawRepresentation, named: VaultPasskey.keySecret(passkey.id))
    try save(passkey)
    let authenticatorData = WebAuthn.authenticatorData(
      relyingParty: relyingParty, userVerified: userVerified, credential: (credentialID, key.publicKey))
    return PasskeyRegistration(passkey: passkey, attestationObject: WebAuthn.attestationObject(authenticatorData: authenticatorData))
  }

  /// The login a new passkey joins: the same username at the site (its exact domain first), else a new login.
  private func loginForPasskey(relyingParty: String, userName: String, now: Date) throws -> String {
    let user = userName.lowercased()
    let fitting = try records(VaultLogin.self).compactMap { login -> (VaultLogin, VaultAutoFill.Match)? in
      guard login.username.lowercased() == user, let domain = login.domain,
        let match = VaultAutoFill.match(domain: domain, host: relyingParty)
      else { return nil }
      return (login, match)
    }
    if let best = fitting.max(by: { $0.1 < $1.1 }) { return best.0.id }
    let login = VaultLogin(website: relyingParty, username: userName, created: now)
    try save(login)
    return login.id
  }

  /// The passkeys for a relying party, limited to `allowed` credential ids unless that's empty.
  public func passkeys(relyingParty: String, allowed: [Data] = []) throws -> [VaultPasskey] {
    let relyingParty = relyingParty.lowercased()
    return try records(VaultPasskey.self).filter {
      $0.relyingParty == relyingParty && (allowed.isEmpty || allowed.contains($0.credentialID))
    }
  }

  /// Deletes a passkey and its private key.
  public func deletePasskey(id: String) throws {
    try delete(id: id)
    try VaultSecrets.setSecret(nil, named: VaultPasskey.keySecret(id))
  }
}
