import CryptoKit
import Foundation

/// The authenticator side of WebAuthn, as a passkey provider answers it: the authenticator data, the attestation
/// object a new passkey hands the site, and the signature that signs in. ES256 keys (P-256), "none" attestation,
/// and a sign count of 0 (a synced passkey has no counter the site could check).
public enum WebAuthn {
  /// The COSE algorithm Vault's passkeys use: ECDSA over P-256 with SHA-256.
  public static let es256 = -7

  /// The authenticator data's flags.
  public struct Flags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The user was present (they picked the passkey).
    public static let userPresent = Flags(rawValue: 0x01)
    /// The user was verified (Touch ID, Face ID or the device passcode).
    public static let userVerified = Flags(rawValue: 0x04)
    /// The passkey may be backed up (it syncs).
    public static let backupEligible = Flags(rawValue: 0x08)
    /// The passkey is backed up (it's in iCloud Keychain).
    public static let backedUp = Flags(rawValue: 0x10)
    /// Attested credential data follows (registration only).
    public static let attestedCredential = Flags(rawValue: 0x40)
  }

  /// "none" attestation names no authenticator model.
  static let aaguid = Data(count: 16)

  /// The authenticator data: the relying party's hash, the flags, a zero sign count, and for a new passkey its id
  /// and public key.
  public static func authenticatorData(
    relyingParty: String, userVerified: Bool, credential: (id: Data, publicKey: P256.Signing.PublicKey)? = nil
  ) -> Data {
    var flags: Flags = [.userPresent, .backupEligible, .backedUp]
    if userVerified { flags.insert(.userVerified) }
    if credential != nil { flags.insert(.attestedCredential) }
    var data = Data(SHA256.hash(data: Data(relyingParty.utf8)))
    data.append(flags.rawValue)
    data.append(contentsOf: [0, 0, 0, 0])
    if let credential {
      data.append(aaguid)
      data.append(UInt8(credential.id.count >> 8))
      data.append(UInt8(credential.id.count & 0xff))
      data.append(credential.id)
      data.append(coseKey(credential.publicKey))
    }
    return data
  }

  /// A public key as COSE_Key: EC2, ES256, P-256, x and y.
  public static func coseKey(_ key: P256.Signing.PublicKey) -> Data {
    let raw = key.rawRepresentation
    return CBOR.map([
      (.int(1), .int(2)), (.int(3), .int(es256)), (.int(-1), .int(1)),
      (.int(-2), .bytes(raw.prefix(32))), (.int(-3), .bytes(raw.suffix(32))),
    ]).encoded
  }

  /// The attestation object a registration returns: "none" attestation over the authenticator data.
  public static func attestationObject(authenticatorData: Data) -> Data {
    CBOR.map([(.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(authenticatorData))])
      .encoded
  }

  /// Signs in: the authenticator data and its signature (DER) over it and the client data's hash.
  public static func assertion(
    relyingParty: String, clientDataHash: Data, key: P256.Signing.PrivateKey, userVerified: Bool
  ) throws -> (authenticatorData: Data, signature: Data) {
    let authenticatorData = authenticatorData(relyingParty: relyingParty, userVerified: userVerified)
    let signature = try key.signature(for: authenticatorData + clientDataHash)
    return (authenticatorData, signature.derRepresentation)
  }
}

/// The bit of CBOR WebAuthn needs: integers, byte and text strings, maps (keys in the order given, which callers
/// keep canonical).
enum CBOR {
  case int(Int)
  case bytes(Data)
  case text(String)
  indirect case map([(CBOR, CBOR)])

  var encoded: Data {
    var data = Data()
    encode(into: &data)
    return data
  }

  private func encode(into data: inout Data) {
    switch self {
    case .int(let value):
      if value >= 0 { Self.head(0, UInt64(value), into: &data) } else { Self.head(1, UInt64(-1 - value), into: &data) }
    case .bytes(let bytes):
      Self.head(2, UInt64(bytes.count), into: &data)
      data.append(bytes)
    case .text(let text):
      Self.head(3, UInt64(text.utf8.count), into: &data)
      data.append(contentsOf: text.utf8)
    case .map(let pairs):
      Self.head(5, UInt64(pairs.count), into: &data)
      for (key, value) in pairs {
        key.encode(into: &data)
        value.encode(into: &data)
      }
    }
  }

  private static func head(_ major: UInt8, _ value: UInt64, into data: inout Data) {
    let type = major << 5
    switch value {
    case ..<24: data.append(type | UInt8(value))
    case ..<0x100: data.append(contentsOf: [type | 24, UInt8(value)])
    case ..<0x1_0000: data.append(contentsOf: [type | 25, UInt8(value >> 8), UInt8(value & 0xff)])
    case ..<0x1_0000_0000: data.append(type | 26); data.append(contentsOf: (0..<4).reversed().map { UInt8(value >> ($0 * 8) & 0xff) })
    default: data.append(type | 27); data.append(contentsOf: (0..<8).reversed().map { UInt8(value >> ($0 * 8) & 0xff) })
    }
  }
}
