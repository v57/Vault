import CryptoKit
import Foundation
import VaultKit

/// An encrypted folder's own 256-bit key, with an id the folder's files name in their headers.
///
/// The vault keeps it wrapped: `wrapped(with:)` seals it with the vault key into a base64 string for the
/// `VaultFolder` record's `wrappedKey` field, and `init(wrapped:keys:)` opens it on any device that has the vault
/// key. (Wrapping it with each member's key, for sharing, comes later.)
public struct FolderKey: Sendable, Equatable {
  public let id: String
  public let key: SymmetricKey

  /// A new random key with a random id.
  public init() {
    id = randomBytes(8).map { String(format: "%02x", $0) }.joined()
    key = SymmetricKey(size: .bits256)
  }

  public init(id: String, keyData: Data) throws {
    guard keyData.count == 32, !id.isEmpty, id.utf8.count <= 255 else { throw VaultFilesError.damaged }
    self.id = id
    key = SymmetricKey(data: keyData)
  }

  /// The raw key bytes.
  public var keyData: Data { key.withUnsafeBytes { Data($0) } }

  /// The keys for contents and names, derived from this one.
  public var subkeys: FolderSubkeys { FolderSubkeys(folderKey: key) }

  public static func == (lhs: FolderKey, rhs: FolderKey) -> Bool {
    lhs.id == rhs.id && lhs.keyData == rhs.keyData
  }

  static let wrapVersion: UInt8 = 1

  /// This key sealed with the vault's primary key, as base64: version, vault key id, then the AES-GCM box of the
  /// folder key's id and bytes.
  public func wrapped(with keys: VaultKeyProvider) throws -> String {
    let idData = Data(id.utf8)
    let sealed = try VaultCrypto.seal(Data([UInt8(idData.count)]) + idData + keyData, keys: keys)
    let vaultKeyID = Data(sealed.keyID.utf8)
    guard vaultKeyID.count <= 255 else { throw VaultFilesError.damaged }
    return (Data([Self.wrapVersion, UInt8(vaultKeyID.count)]) + vaultKeyID + sealed.ciphertext).base64EncodedString()
  }

  /// Opens a key wrapped by `wrapped(with:)`. Throws `VaultCrypto.CryptoError.missingKey` when this device doesn't
  /// have the vault key yet.
  public init(wrapped: String, keys: VaultKeyProvider) throws {
    guard let data = Data(base64Encoded: wrapped).map({ [UInt8]($0) }), data.count > 2 else {
      throw VaultFilesError.damaged
    }
    guard data[0] == Self.wrapVersion else { throw VaultFilesError.unsupportedVersion(Int(data[0])) }
    let keyIDLength = Int(data[1])
    guard data.count > 2 + keyIDLength else { throw VaultFilesError.damaged }
    let vaultKeyID = String(decoding: data[2..<2 + keyIDLength], as: UTF8.self)
    let plaintext = [UInt8](try VaultCrypto.open(Data(data[(2 + keyIDLength)...]), keyID: vaultKeyID, keys: keys))
    guard let idLength = plaintext.first.map(Int.init), plaintext.count == 1 + idLength + 32 else {
      throw VaultFilesError.damaged
    }
    try self.init(
      id: String(decoding: plaintext[1..<1 + idLength], as: UTF8.self), keyData: Data(plaintext[(1 + idLength)...]))
  }
}
