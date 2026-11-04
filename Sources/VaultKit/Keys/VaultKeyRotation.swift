import CryptoKit
import Foundation

/// What `VaultStore.rotateKeys` did.
public struct VaultKeyRotation: Sendable, Equatable {
  /// The rotation, and the key that's current now.
  public var epoch: VaultKeyEpoch
  /// Records sealed again under the new key, in every store; folder keys' records among them.
  public var rewritten: Int
}

/// A new vault key, for a device that's gone.
///
/// Each store seals its rows and folder keys again and sends them, and a device that hears of the rotation does the
/// same (`catchUp`, so a kill loses nothing); from then on what arrives under a retired key is refused, so a device
/// still holding one can't write. Retired keys stay in the keychain: rows waiting to be sealed again, encrypted notes
/// (`.mdenc`, sealed again when they're next written) and the migration's backup open with them.
///
/// **What this doesn't do.** The keys sync through iCloud Keychain, so a device still in the Apple account gets the new
/// key like any other. Removing it from the account has to come first, and only the user can do that. A device that
/// kept a copy of what it could read keeps that too: passwords and other secrets have to be changed by hand. A device
/// with no iCloud Keychain (Linux, Windows, a Hub-only one) doesn't get the new key either, and needs it another way.
extension VaultStore {
  /// Rotates the vault key and seals everything here and in `others` again. Keys are shared, so `others` are the
  /// account stores beside Personal. `kitCheck` ties the new key to a recovery kit (`VaultRecovery.replace`). With a
  /// recovery kit on, the new key is sealed to it.
  @discardableResult
  public func rotateKeys(kitCheck: String? = nil, alongWith others: [VaultStore] = []) throws -> VaultKeyRotation {
    let before = try keys.allKeys
    let epoch = try keys.rotate(kitCheck: kitCheck)
    try save(
      id: try derivedID(Self.keyHistoryKind), kind: Self.keyHistoryKind,
      changes: Dictionary(uniqueKeysWithValues: before.map { ("key.\($0.key)", .string(Self.fingerprint(of: $0.value))) }))
    var rewritten = try catchUp().count
    for store in others { rewritten += try store.catchUp().count }
    if kitCheck == nil, let key = try keys.key(id: epoch.keyID) {
      try VaultRecovery(store: self).wrap(vaultKey: key, id: epoch.keyID)
    }
    return VaultKeyRotation(epoch: epoch, rewritten: rewritten)
  }

  /// A record of the keys rotations retired, by fingerprint. Nothing's left under a retired key for it to open but files
  /// (encrypted notes), so on a restore this is what vouches for it: the record opens only with a key that's vouched
  /// for already.
  static let keyHistoryKind = "keyHistory"

  static func fingerprint(of key: SymmetricKey) -> String {
    key.withUnsafeBytes { Data(SHA256.hash(data: Data("dev.v57.vault.key-history".utf8) + Data($0))) }.base64EncodedString()
  }

  /// Which of `candidates` the store's history names, with the very key it knew.
  func keysInHistory(among candidates: [String: SymmetricKey]) throws -> [String: SymmetricKey] {
    guard let history = try item(id: try derivedID(Self.keyHistoryKind)), history.kind == Self.keyHistoryKind else { return [:] }
    return candidates.filter { id, key in history.fields["key.\(id)"]?.stringValue == Self.fingerprint(of: key) }
  }

  /// The keys a rotation retired, once the key that replaced them is here. Until it arrives there's nothing better to
  /// seal with, and sealing again would change nothing.
  func retiredKeys() throws -> Set<String> {
    guard try !keys.keyEpochs.isEmpty else { return [] }
    guard try !keys.isRetired(try keys.primary().id) else { return [] }
    return Set(try keys.allKeys.keys.filter { try keys.isRetired($0) })
  }

  /// Rows sealed with `retired`, in transactions of a batch each. A placeholder that never opened isn't touched: a
  /// device that can read it sends the row again under the new key.
  ///
  /// With `adopting`, a restored kit's keys: placeholders open too, as the user just vouched for the keys with the kit.
  func resealRows(sealedWith retired: Set<String>, adopting: Bool = false) throws -> [String] {
    try withLock { try requireOpen() }
    let names = retired.sorted()
    let marks = names.map { _ in "?" }.joined(separator: ",")
    var written: [String] = []
    var after = ""
    while true {
      let finished: Bool = try database.transaction {
        let rows = try database.query(
          "SELECT id, key_id, payload FROM items WHERE key_id IN (\(marks)) AND id > ? ORDER BY id LIMIT 200",
          names.map { .text($0) } + [.text(after)])
        var any = false
        for row in rows {
          let id = row[0].text ?? ""
          after = id
          let item =
            adopting
            ? try? decode(id: id, keyID: row[1].text ?? "", payload: row[2].blob ?? Data(), from: .local)
            : try loadRow(id: id)?.item
          guard let item else { continue }
          try rewrite(item)
          written.append(id)
          any = true
        }
        if any { try bumpRevision() }
        return rows.isEmpty
      }
      if finished { break }
    }
    return written
  }

  /// Whether a key opens a record here, its own kind's: recovery blobs don't count, as they're what's being checked. The
  /// binding is checked too, so a box moved here from elsewhere doesn't vouch for it.
  func opensARecord(key: SymmetricKey, id keyID: String) throws -> Bool {
    try withLock {
      for row in try database.query("SELECT id, payload FROM items WHERE key_id = ?", [.text(keyID)]) {
        let id = row[0].text ?? ""
        let payload = row[1].blob ?? Data()
        if let parsed = VaultItemSeal.parse(payload) {
          if let opened = try? VaultItemSeal.open(parsed, id: id, account: accountBinding, key: key),
            opened.kind != VaultRecoveryBlob.kind, (try? JSONDecoder().decode(ItemFields.self, from: opened.fields)) != nil
          {
            return true
          }
        } else if try _isWaiting || isAllowedFormat1(id: id, payload: payload),
          let plaintext = try? VaultCrypto.open(payload, key: key),
          let decoded = try? JSONDecoder().decode(Payload.self, from: plaintext), decoded.kind != VaultRecoveryBlob.kind
        {
          return true
        }
      }
      return false
    }
  }

  /// Folders' keys are wrapped in their records with a vault key (`FolderKey.wrapped`: a version byte, the key id's
  /// length, the key id, the AES-GCM box). Nothing in the box changes, only what seals it.
  func rewrapFolderKeys(sealedWith retired: Set<String>) throws -> [String] {
    var written: [String] = []
    for folder in try records(VaultFolder.self) {
      guard let wrapped = folder.wrappedKey, let rewrapped = try Self.rewrap(wrapped, retired: retired, keys: keys) else {
        continue
      }
      if try save(id: folder.id, kind: VaultFolder.kind, changes: ["wrappedKey": .string(rewrapped)]) {
        written.append(folder.id)
      }
    }
    return written
  }

  /// `wrapped` under the current key, if it names a retired one; nil if it doesn't, or isn't a wrapping this build knows.
  static func rewrap(_ wrapped: String, retired: Set<String>, keys: any VaultKeyProvider) throws -> String? {
    guard let data = Data(base64Encoded: wrapped), data.count > 2, data[data.startIndex] == 1 else { return nil }
    let length = Int(data[data.startIndex + 1])
    let start = data.startIndex + 2
    guard data.count > 2 + length else { return nil }
    let keyID = String(decoding: data[start..<start + length], as: UTF8.self)
    guard retired.contains(keyID), let plaintext = try? VaultCrypto.open(Data(data[(start + length)...]), keyID: keyID, keys: keys)
    else { return nil }
    let sealed = try VaultCrypto.seal(plaintext, keys: keys)
    let newID = Data(sealed.keyID.utf8)
    guard newID.count <= 255 else { return nil }
    return (Data([1, UInt8(newID.count)]) + newID + sealed.ciphertext).base64EncodedString()
  }
}
