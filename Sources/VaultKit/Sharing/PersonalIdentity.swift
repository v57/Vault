import CryptoKit
import Foundation

/// A person's keys for sharing with other people: X25519 to receive keys sealed to them (`KeyWrap`), Ed25519 to
/// sign what they publish (member lists, invites, change logs).
///
/// One per person, not per device: it is a synchronizable keychain item (`VaultPersonalIdentity`), so all of
/// the user's devices share it. It is separate from the per-device Secure Enclave SSH key (`VaultIdentity`),
/// which never leaves its device.
public struct PersonalIdentity: Sendable {
  public let agreementKey: Curve25519.KeyAgreement.PrivateKey
  public let signingKey: Curve25519.Signing.PrivateKey

  /// New random keys.
  public init() {
    agreementKey = Curve25519.KeyAgreement.PrivateKey()
    signingKey = Curve25519.Signing.PrivateKey()
  }

  public init(agreementKey: Curve25519.KeyAgreement.PrivateKey, signingKey: Curve25519.Signing.PrivateKey) {
    self.agreementKey = agreementKey
    self.signingKey = signingKey
  }

  static let version: UInt8 = 1

  /// Version byte, the X25519 private key, the Ed25519 private key (65 bytes).
  public var rawRepresentation: Data {
    Data([Self.version]) + agreementKey.rawRepresentation + signingKey.rawRepresentation
  }

  public init(rawRepresentation data: Data) throws {
    let bytes = [UInt8](data)
    guard bytes.count == 65, bytes[0] == Self.version else { throw SharingError.invalidIdentity }
    do {
      agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(bytes[1..<33]))
      signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes[33..<65]))
    } catch {
      throw SharingError.invalidIdentity
    }
  }

  /// What others need: the two public keys.
  public var publicIdentity: PublicIdentity {
    PublicIdentity(
      validatedSigningKey: signingKey.publicKey.rawRepresentation,
      agreementKey: agreementKey.publicKey.rawRepresentation)
  }

  public func signature(for data: Data) throws -> Data {
    try signingKey.signature(for: data)
  }
}

/// A person's public keys, as others keep them (`VaultPerson`) and as invites carry them.
///
/// Its text form is compact enough for a QR code or a link: `v57id:` and the base64url of a version byte and
/// the two 32-byte keys.
public struct PublicIdentity: Sendable, Hashable, CustomStringConvertible {
  /// The Ed25519 public key (32 bytes).
  public let signingKey: Data
  /// The X25519 public key (32 bytes).
  public let agreementKey: Data

  public init(signingKey: Data, agreementKey: Data) throws {
    guard (try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey)) != nil,
      (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementKey)) != nil
    else { throw SharingError.invalidIdentity }
    self.signingKey = signingKey
    self.agreementKey = agreementKey
  }

  init(validatedSigningKey: Data, agreementKey: Data) {
    signingKey = validatedSigningKey
    self.agreementKey = agreementKey
  }

  public static let prefix = "v57id:"

  /// Reads the `v57id:…` text form; nil for anything else.
  public init?(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix(Self.prefix), let data = Data(base64URL: String(text.dropFirst(Self.prefix.count))) else {
      return nil
    }
    let bytes = [UInt8](data)
    guard bytes.count == 65, bytes[0] == PersonalIdentity.version,
      let identity = try? PublicIdentity(signingKey: Data(bytes[33..<65]), agreementKey: Data(bytes[1..<33]))
    else { return nil }
    self = identity
  }

  /// `v57id:<base64url>`.
  public var text: String {
    Self.prefix + (Data([PersonalIdentity.version]) + agreementKey + signingKey).base64URL
  }

  public var description: String { text }

  public var signingPublicKey: Curve25519.Signing.PublicKey {
    try! Curve25519.Signing.PublicKey(rawRepresentation: signingKey)
  }

  public var agreementPublicKey: Curve25519.KeyAgreement.PublicKey {
    try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementKey)
  }

  public func isValidSignature(_ signature: Data, for data: Data) -> Bool {
    signingPublicKey.isValidSignature(signature, for: data)
  }

  /// "Ed25519 3A9F…C27D": the start and end of the signing key's SHA-256, for showing next to a person.
  public var fingerprint: String { "Ed25519 " + Self.shortFingerprint(signingKey) }

  /// "X25519 3A9F…C27D", the same for the key-agreement key.
  public var agreementFingerprint: String { "X25519 " + Self.shortFingerprint(agreementKey) }

  /// The signing key's whole SHA-256 in groups of four hex digits.
  public var fullFingerprint: String {
    let hex = Self.hex(Data(SHA256.hash(data: signingKey)))
    return stride(from: 0, to: hex.count, by: 4).map { start in
      let from = hex.index(hex.startIndex, offsetBy: start)
      return String(hex[from..<hex.index(from, offsetBy: 4)])
    }.joined(separator: " ")
  }

  static func shortFingerprint(_ key: Data) -> String {
    let hash = Data(SHA256.hash(data: key))
    return hex(hash.prefix(2)) + "…" + hex(hash.suffix(2))
  }

  static func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
}

public enum SharingError: LocalizedError, Equatable {
  case invalidIdentity
  case invalidInvite
  case cannotOpen

  public var errorDescription: String? {
    switch self {
    case .invalidIdentity: "These identity keys are damaged."
    case .invalidInvite: "This isn’t a valid invite, or it was changed after it was made."
    case .cannotOpen: "This key wasn’t sealed for you, or it is damaged."
    }
  }
}

/// The user's own `PersonalIdentity`, made on first use and kept as a synchronizable keychain item, so every
/// device of the user has the same one.
///
/// A demo run or a test calls `useInMemoryStore()` (or `VaultSecrets.useInMemoryStore()`, which does both) so
/// the user's keychain is never touched.
public enum VaultPersonalIdentity {
  static let keychainBacking = KeychainSecretBacking(keychain: VaultKeychain(service: "dev.v57.vault.identity"))
  static let account = "personal-identity"

  private static let lock = NSLock()
  nonisolated(unsafe) private static var _backing: any VaultSecretBacking = keychainBacking

  /// Where the identity is kept: the keychain, or memory after `useInMemoryStore()`.
  public static var backing: any VaultSecretBacking {
    get { lock.withLock { _backing } }
    set { lock.withLock { _backing = newValue } }
  }

  /// Keeps the identity in memory for the rest of the process. Calling it again keeps the same identity.
  public static func useInMemoryStore() {
    lock.withLock {
      if !(_backing is MemorySecretBacking) { _backing = MemorySecretBacking() }
    }
  }

  /// The identity, made on first use. If another app of the user made one a moment earlier, that one wins.
  ///
  /// Two devices that make one at the same moment, before iCloud Keychain synced, end up with different ones
  /// until it does (iCloud Keychain then keeps one); call it only when the user starts sharing.
  public static func current() throws -> PersonalIdentity {
    let backing = backing
    if let identity = try existing(in: backing) { return identity }
    let identity = PersonalIdentity()
    if try backing.addNew(identity.rawRepresentation, named: account, label: "v57 identity (sharing keys)") {
      return identity
    }
    guard let made = try existing(in: backing) else { throw SharingError.invalidIdentity }
    return made
  }

  /// The identity if one exists, without making it.
  public static func existing() throws -> PersonalIdentity? {
    try existing(in: backing)
  }

  public static var exists: Bool { ((try? backing.read(account)) ?? nil) != nil }

  private static func existing(in backing: any VaultSecretBacking) throws -> PersonalIdentity? {
    try backing.read(account).map(PersonalIdentity.init(rawRepresentation:))
  }
}

extension Data {
  /// Base64 with `-` and `_`, no padding.
  var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(base64URL text: String) {
    guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
      return nil
    }
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { return nil }
    self = data
  }
}
