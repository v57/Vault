import CryptoKit
import Foundation

/// Seals a key (a folder key) to one person, so only their identity's private key opens it.
///
/// X25519 with a fresh ephemeral key, HKDF-SHA256 over the shared secret (salted with both public keys, the
/// `context` in its info), then AES-256-GCM. The result is a version byte, the ephemeral public key (32 bytes)
/// and the AES-GCM box (nonce, ciphertext, tag). The same construction as HPKE's base mode, written with the
/// primitives every platform's CryptoKit has.
public enum KeyWrap {
  static let version: UInt8 = 1

  /// `plaintext` sealed to `recipient`. `context` (a folder id) binds it to its use: opening with another
  /// context fails.
  public static func seal(_ plaintext: Data, to recipient: PublicIdentity, context: Data = Data()) throws -> Data {
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let ephemeralPublic = ephemeral.publicKey.rawRepresentation
    let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient.agreementPublicKey)
    let key = derive(secret, ephemeral: ephemeralPublic, recipient: recipient.agreementKey, context: context)
    guard let box = try AES.GCM.seal(plaintext, using: key, authenticating: context).combined else {
      throw SharingError.cannotOpen
    }
    return Data([version]) + ephemeralPublic + box
  }

  /// Opens what `seal` made for this identity.
  public static func open(_ sealed: Data, with identity: PersonalIdentity, context: Data = Data()) throws -> Data {
    let bytes = [UInt8](sealed)
    guard bytes.count > 1 + 32 + 28, bytes[0] == version else { throw SharingError.cannotOpen }
    do {
      let ephemeralPublic = Data(bytes[1..<33])
      let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic)
      let secret = try identity.agreementKey.sharedSecretFromKeyAgreement(with: ephemeral)
      let key = derive(
        secret, ephemeral: ephemeralPublic, recipient: identity.agreementKey.publicKey.rawRepresentation,
        context: context)
      return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(bytes[33...])), using: key, authenticating: context)
    } catch {
      throw SharingError.cannotOpen
    }
  }

  /// A symmetric key sealed to `recipient`.
  public static func seal(_ key: SymmetricKey, to recipient: PublicIdentity, context: Data = Data()) throws -> Data {
    try seal(key.withUnsafeBytes { Data($0) }, to: recipient, context: context)
  }

  public static func openKey(_ sealed: Data, with identity: PersonalIdentity, context: Data = Data()) throws
    -> SymmetricKey
  {
    SymmetricKey(data: try open(sealed, with: identity, context: context))
  }

  private static func derive(_ secret: SharedSecret, ephemeral: Data, recipient: Data, context: Data) -> SymmetricKey
  {
    secret.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: ephemeral + recipient, sharedInfo: Data("dev.v57.vault.key-wrap".utf8) + context,
      outputByteCount: 32)
  }
}
