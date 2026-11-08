import CryptoKit
import Foundation

/// Seals what a document's pages show — the text read from them, the thumbnail and the pages themselves — under a key
/// only Vault and its AutoFill extension hold (security audit M14). The records live in the store every v57 app opens, and
/// a passport's number or an IBAN is in its OCR text and its picture as much as in the secret field, so without this the
/// apps outside the secrets group read what `VaultSecrets` keeps from them.
///
/// The key comes from the personal identity (`VaultPersonalIdentity`, in the secrets group, the same on every device of
/// the user through iCloud Keychain and in the recovery kit), so each device opens what another sealed. Elsewhere there's
/// no key: the fields read as empty and a save leaves them alone.
///
/// Sealing is deterministic (AES-GCM with a nonce derived from the key, the field and the bytes, as in AES-SIV), so a
/// record saved again unchanged writes nothing: the store saves changed fields only.
public enum DocumentSeal {
  /// The key, nil where the identity can't be read. Made from the identity on first use; `makesIdentity` lets the
  /// first document of a vault make it (`VaultPersonalIdentity.current()`), as sharing would.
  static func key(makesIdentity: Bool) -> SymmetricKey? {
    // Records are read by the hundred: the keychain is asked once, and again only after a minute without a key.
    if let known = lock.withLock({ () -> SymmetricKey?? in
      if let cached { return .some(cached) }
      if let missing, Date().timeIntervalSince(missing) < 60, !makesIdentity { return .some(nil) }
      return nil
    }) { return known }
    let identity = (try? VaultPersonalIdentity.existing()) ?? (makesIdentity ? try? VaultPersonalIdentity.current() : nil)
    guard let identity else {
      lock.withLock { missing = Date() }
      return nil
    }
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: identity.rawRepresentation), salt: Data("v57 document seal".utf8),
      info: Data("v1".utf8), outputByteCount: 32)
    lock.withLock {
      cached = key
      missing = nil
    }
    return key
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var cached: SymmetricKey?
  nonisolated(unsafe) private static var missing: Date?

  /// Forgets the key (tests switching identities).
  static func reset() {
    lock.withLock {
      cached = nil
      missing = nil
    }
  }

  /// Whether this app can open sealed documents.
  public static var isAvailable: Bool { key(makesIdentity: false) != nil }

  /// `data` sealed for `field`, nil without a key.
  static func seal(_ data: Data, field: String) -> Data? {
    guard let key = key(makesIdentity: true) else { return nil }
    return seal(data, field: field, key: key)
  }

  static func seal(_ data: Data, field: String, key: SymmetricKey) -> Data? {
    var authenticated = Data(field.utf8)
    authenticated.append(0)
    authenticated.append(data)
    let mac = HMAC<SHA256>.authenticationCode(for: authenticated, using: key)
    guard let nonce = try? AES.GCM.Nonce(data: Data(mac).prefix(12)) else { return nil }
    return try? AES.GCM.seal(data, using: key, nonce: nonce, authenticating: Data(field.utf8)).combined
  }

  /// The bytes sealed for `field`, nil without a key or for bytes another key sealed.
  static func open(_ sealed: Data, field: String) -> Data? {
    guard let key = key(makesIdentity: false) else { return nil }
    return open(sealed, field: field, key: key)
  }

  static func open(_ sealed: Data, field: String, key: SymmetricKey) -> Data? {
    guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
    return try? AES.GCM.open(box, using: key, authenticating: Data(field.utf8))
  }

  // MARK: Fields

  /// Writes `plain` sealed as `sealed<Name>` and clears the plain field; leaves both alone where there's no key, so an
  /// app outside the secrets group never overwrites them. An empty value clears both.
  static func write(_ plain: Data?, as field: String, into values: inout [String: JSONValue]) {
    let sealedField = "sealed" + field.prefix(1).uppercased() + field.dropFirst()
    guard let plain, !plain.isEmpty else {
      if isAvailable {
        values[field] = .null
        values[sealedField] = .null
      }
      return
    }
    guard let sealed = seal(plain, field: field) else {
      // No key yet (the identity is on its way from another device): kept plain rather than lost, and sealed by
      // `sealDocuments()` once the key is here.
      values[field] = .string(field == "text" ? String(decoding: plain, as: UTF8.self) : plain.base64EncodedString())
      return
    }
    values[field] = .null
    values[sealedField] = .string(sealed.base64EncodedString())
  }

  /// The field's bytes: sealed (`sealed<Name>`) when this app can open them, else what an older build left in the
  /// plain field.
  static func read(_ field: String, from values: [String: JSONValue]) -> Data? {
    let sealedField = "sealed" + field.prefix(1).uppercased() + field.dropFirst()
    if let sealed = values[sealedField]?.stringValue.flatMap({ Data(base64Encoded: $0) }) {
      return open(sealed, field: field)
    }
    return nil
  }

  /// Whether a record still has a plain value of a sealed field (written before sealing, or by a device without the
  /// key yet): `VaultStore.sealDocuments()` seals those.
  static func hasPlain(_ fields: [String], in values: [String: JSONValue]) -> Bool {
    fields.contains { field in
      guard let value = values[field] else { return false }
      if let text = value.stringValue { return !text.isEmpty }
      return false
    }
  }
}

extension VaultStore {
  /// Seals the documents and pages that still keep their text, thumbnail or bytes in plain fields: ones saved before
  /// sealing, or on a device that had no key yet. Only where the key is (Vault); returns how many records it sealed.
  @discardableResult
  public func sealDocuments() throws -> Int {
    guard DocumentSeal.isAvailable else { return 0 }
    var sealed = 0
    for item in try items(kind: VaultDocument.kind) where DocumentSeal.hasPlain(["text", "thumbnail"], in: item.values) {
      if try save(VaultDocument(id: item.id, values: item.values)) { sealed += 1 }
    }
    for item in try items(kind: VaultDocumentFile.kind) where DocumentSeal.hasPlain(["data", "text"], in: item.values) {
      if try save(VaultDocumentFile(id: item.id, values: item.values)) { sealed += 1 }
    }
    return sealed
  }
}
