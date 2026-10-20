import CryptoKit
import Foundation

/// The recovery key as devices keep it: its public key only, never the secret. One record (`recordID`); there is
/// a recovery key when it exists.
public struct VaultRecoveryKey: VaultRecord, Hashable {
  public static let kind = "recoveryKey"
  public static let recordID = "recovery-key"

  public var id: String
  /// The X25519 public key derived from the secret (32 bytes).
  public var publicKey: Data
  public var created: Date?

  public init(publicKey: Data, created: Date? = .now) {
    id = Self.recordID
    self.publicKey = publicKey
    self.created = created?.wholeSeconds
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    publicKey = read.data("publicKey") ?? Data()
    created = read.date("created")
  }

  public var values: [String: JSONValue] {
    [
      "publicKey": .string(publicKey.base64EncodedString()), "check": .string(check), "created": .init(created),
    ]
  }

  /// "3A9F-C27D", printed on the kit: tells which kit is the current one.
  public var check: String { RecoverySecret.check(for: publicKey) }

  /// The key that seals the blob records, derived from the public key: a device that has the public key (from
  /// this record) or the secret (a recovering device, without the vault keys) opens them.
  var recordKey: (id: String, key: SymmetricKey) {
    let hash = SHA256.hash(data: Data("dev.v57.vault.recovery.records".utf8) + publicKey)
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: publicKey), salt: Data("dev.v57.vault.recovery".utf8),
      info: Data("records".utf8), outputByteCount: 32)
    return ("recovery-" + hash.prefix(8).map { String(format: "%02x", $0) }.joined(), key)
  }
}

/// One key sealed to the recovery key (HPKE, X25519): a vault key, the personal identity or a folder key. Any
/// device makes them from the public key alone; only the secret opens them.
///
/// They sync like every record (that is the copy in CloudKit), sealed with a key derived from the recovery
/// public key rather than the vault key, so a device that lost the vault keys still reads them. A folder's
/// remote keeps its folder keys' blobs too (`VaultRecovery.writeBlobs`), as files in `<folder>/recovery/`.
public struct VaultRecoveryBlob: VaultRecord, Hashable {
  public static let kind = "recoveryBlob"

  public enum Content: String, Sendable, CaseIterable {
    case vaultKey
    case identity
    case folderKey
  }

  public var id: String
  /// The recovery key's `check`: which kit opens it.
  public var recoveryKey: String
  /// Nil for a kind of key this build doesn't know.
  public var content: Content?
  /// The vault key's id, the identity's (its agreement key's fingerprint), or the folder key's.
  public var keyID: String
  /// The `VaultFolder` a folder key belongs to.
  public var folderID: String?
  /// The HPKE box: a version byte, the encapsulated key and the ciphertext.
  public var sealed: Data
  public var created: Date?

  init(
    publicKey: Data, content: Content, keyID: String, folderID: String?, sealed: Data, created: Date? = .now
  ) {
    id = Self.id(publicKey: publicKey, content: content, keyID: keyID, folderID: folderID)
    recoveryKey = RecoverySecret.check(for: publicKey)
    self.content = content
    self.keyID = keyID
    self.folderID = folderID
    self.sealed = sealed
    self.created = created?.wholeSeconds
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    recoveryKey = read.string("recoveryKey", default: "")
    contentName = read.string("content", default: "")
    content = Content(rawValue: contentName)
    keyID = read.string("keyID", default: "")
    folderID = read.string("folderID")
    sealed = read.data("sealed") ?? Data()
    created = read.date("created")
  }

  /// The content as written, kept for kinds this build doesn't know.
  private var contentName = ""

  public var values: [String: JSONValue] {
    [
      "recoveryKey": .string(recoveryKey), "content": .string(content?.rawValue ?? contentName),
      "keyID": .string(keyID), "folderID": .init(folderID), "sealed": .string(sealed.base64EncodedString()),
      "created": .init(created),
    ]
  }

  /// The same key wrapped twice (two devices at once) gets the same id, so the copies merge into one.
  static func id(publicKey: Data, content: Content, keyID: String, folderID: String?) -> String {
    let input = [content.rawValue, folderID ?? "", keyID].joined(separator: "\u{0}")
    let hash = SHA256.hash(data: Data("dev.v57.vault.recovery.blob".utf8) + publicKey + Data(input.utf8))
    return "recovery-" + hash.prefix(12).map { String(format: "%02x", $0) }.joined()
  }

  /// What the box is bound to: opening it as another key fails.
  var context: Data {
    Data(["dev.v57.vault.recovery", content?.rawValue ?? contentName, folderID ?? "", keyID].joined(separator: "|").utf8)
  }

  // MARK: Sealing

  static let version: UInt8 = 1
  /// DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-256-GCM (RFC 9180).
  static let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
  static let info = Data("dev.v57.vault.recovery-blob".utf8)

  /// `plaintext` sealed to the recovery public key.
  static func seal(
    _ plaintext: Data, publicKey: Data, content: Content, keyID: String, folderID: String?
  ) throws -> VaultRecoveryBlob {
    var blob = VaultRecoveryBlob(
      publicKey: publicKey, content: content, keyID: keyID, folderID: folderID, sealed: Data())
    let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
    var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info)
    let ciphertext = try sender.seal(plaintext, authenticating: blob.context)
    blob.sealed = Data([version]) + sender.encapsulatedKey + ciphertext
    return blob
  }

  /// The key inside, opened with the secret's private key.
  func open(with secret: RecoverySecret) throws -> Data {
    let bytes = [UInt8](sealed)
    guard bytes.count > 1 + 32, bytes[0] == Self.version else { throw RecoveryKeyError.damaged }
    do {
      var recipient = try HPKE.Recipient(
        privateKey: secret.agreementKey, ciphersuite: Self.suite, info: Self.info,
        encapsulatedKey: Data(bytes[1..<33]))
      return try recipient.open(Data(bytes[33...]), authenticating: context)
    } catch {
      throw RecoveryKeyError.damaged
    }
  }

  // MARK: Files on a remote

  /// The blob as a file in a folder's `recovery/` folder on its remote: JSON with the same fields.
  var fileData: Data {
    get throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(
        File(
          v: 1, recoveryKey: recoveryKey, content: content?.rawValue ?? contentName, keyID: keyID,
          folderID: folderID, sealed: sealed))
    }
  }

  init(id: String, fileData: Data) throws {
    guard let file = try? JSONDecoder().decode(File.self, from: fileData), file.v == 1 else {
      throw RecoveryKeyError.damaged
    }
    self.id = id
    recoveryKey = file.recoveryKey
    contentName = file.content
    content = Content(rawValue: file.content)
    keyID = file.keyID
    folderID = file.folderID
    sealed = file.sealed
    created = nil
  }

  private struct File: Codable {
    var v: Int
    var recoveryKey: String
    var content: String
    var keyID: String
    var folderID: String?
    var sealed: Data
  }
}
