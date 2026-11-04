import CryptoKit
import Foundation

/// A record's payload, format 2: bound to its store, id and kind, so it opens nowhere else.
///
///     "V57I" 0x02 | key id length, key id | kind blocks | sealed kind | sealed fields
///
/// - The version is inside the payload, as the SQLite schema never changes.
/// - The kind is sealed on its own, padded to 32-byte blocks, because CloudKit never learned kinds and shouldn't start
///   now. It's bound to the store and id; the fields are bound to those and the kind. Two AES-GCM boxes with their own
///   random nonces under one key, each with its own associated data.
/// - The key id is in the header, as a record has nowhere else: CloudKit's `keyID` field stays empty, which is what makes
///   an old build skip the record (`CloudSync.remote`).
///
/// Format 1, every payload before this: AES-GCM with no associated data over `{"k": kind, "f": fields}`. A store reads it
/// until it finished migrating (`VaultStore.prepareFormat`) and refuses it after.
enum VaultItemSeal {
  static let magic: [UInt8] = Array("V57I".utf8) + [2]
  static let version: UInt8 = 2
  private static let block = 32
  private static let maxKindLength = 8 * 32 - 1

  struct Parsed {
    let keyID: String
    let sealedKind: Data
    let body: Data
  }

  /// The header of a format 2 payload; nil for anything else (format 1 has a random first 5 bytes).
  static func parse(_ payload: Data) -> Parsed? {
    let bytes = payload.startIndex
    guard payload.count > magic.count + 2, payload.prefix(magic.count).elementsEqual(magic) else { return nil }
    var at = bytes + magic.count
    let keyIDLength = Int(payload[at])
    at += 1
    guard keyIDLength > 0, payload.endIndex - at > keyIDLength + 1 else { return nil }
    let keyID = String(decoding: payload[at..<at + keyIDLength], as: UTF8.self)
    at += keyIDLength
    let kindLength = Int(payload[at]) * block + 28
    at += 1
    guard payload[at - 1] > 0, payload.endIndex - at > kindLength else { return nil }
    return Parsed(keyID: keyID, sealedKind: Data(payload[at..<at + kindLength]), body: Data(payload[(at + kindLength)...]))
  }

  static func seal(
    kind: String, fields: Data, id: String, account: String, keyID: String, key: SymmetricKey
  ) throws -> Data {
    let name = Data(kind.utf8)
    let keyName = Data(keyID.utf8)
    guard name.count <= maxKindLength, !keyName.isEmpty, keyName.count <= 255 else { throw VaultCrypto.CryptoError.damaged }
    let blocks = (name.count + 1 + block - 1) / block
    var padded = Data([UInt8(name.count)]) + name
    padded.append(Data(count: blocks * block - padded.count))
    let sealedKind = try box(padded, key: key, aad: kindAAD(id: id, account: account))
    let body = try box(fields, key: key, aad: bodyAAD(id: id, account: account, kind: kind))
    return Data(magic) + Data([UInt8(keyName.count)]) + keyName + Data([UInt8(blocks)]) + sealedKind + body
  }

  /// The kind and the fields; `damaged` when either box fails: moved from another record, store or kind, or changed.
  static func open(_ parsed: Parsed, id: String, account: String, key: SymmetricKey) throws -> (kind: String, fields: Data) {
    let padded = try unbox(parsed.sealedKind, key: key, aad: kindAAD(id: id, account: account))
    guard let length = padded.first.map(Int.init), padded.count > length else { throw VaultCrypto.CryptoError.damaged }
    let kind = String(decoding: padded.dropFirst().prefix(length), as: UTF8.self)
    return (kind, try unbox(parsed.body, key: key, aad: bodyAAD(id: id, account: account, kind: kind)))
  }

  private static func box(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
    guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else {
      throw VaultCrypto.CryptoError.damaged
    }
    return combined
  }

  private static func unbox(_ ciphertext: Data, key: SymmetricKey, aad: Data) throws -> Data {
    do {
      return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: aad)
    } catch {
      throw VaultCrypto.CryptoError.damaged
    }
  }

  private static func field(_ text: String) -> Data {
    let bytes = Data(text.utf8)
    return withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Data($0) } + bytes
  }

  private static func kindAAD(id: String, account: String) -> Data {
    Data("dev.v57.vault.item.kind".utf8) + Data([version]) + field(account) + field(id)
  }

  private static func bodyAAD(id: String, account: String, kind: String) -> Data {
    Data("dev.v57.vault.item".utf8) + Data([version]) + field(account) + field(id) + field(kind)
  }
}
