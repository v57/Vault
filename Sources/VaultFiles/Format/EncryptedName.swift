import CryptoKit
import Foundation

/// The keys a folder key splits into, each derived with HKDF under its own info string, so content and names never
/// share a key.
public struct FolderSubkeys: Sendable {
  /// Seals file contents (`EncryptedFile`) and the folder's manifest.
  public let content: SymmetricKey
  /// Seals names.
  public let nameEncryption: SymmetricKey
  /// Derives a name's nonce (the synthetic IV that makes name encryption deterministic).
  public let nameNonce: SymmetricKey

  public init(folderKey: SymmetricKey) {
    func derive(_ info: String) -> SymmetricKey {
      HKDF<SHA256>.deriveKey(inputKeyMaterial: folderKey, info: Data(info.utf8), outputByteCount: 32)
    }
    content = derive("dev.v57.files.content")
    nameEncryption = derive("dev.v57.files.names.encryption")
    nameNonce = derive("dev.v57.files.names.nonce")
  }
}

/// Deterministic encryption of file and folder names, so the same name in the same folder always has the same
/// encrypted name and a path resolves without an index (Cryptomator's approach).
///
/// The nonce is the first 12 bytes of HMAC-SHA256(name nonce key, directory id + name), like AES-GCM-SIV's
/// synthetic IV; the name is sealed with AES-GCM under that nonce, authenticating the directory id, so a name moved
/// into another folder doesn't open. The result, `nonce + ciphertext + tag`, is base64url without padding: safe
/// in file names on every file system. It is case-sensitive: on a case-insensitive volume (APFS's default) two
/// encrypted names that differ only in case would collide, which for 28+ random bytes doesn't happen in practice.
/// Names are NFC-normalized first, so both Unicode forms of "é" are one name.
public struct NameCipher: Sendable {
  static let nonceSize = 12
  /// The longest encrypted name kept as the file name itself; longer ones are shortened (`DiskName`).
  public static let maxEncodedLength = 200

  private let encryptionKey: SymmetricKey
  private let nonceKey: SymmetricKey

  public init(keys: FolderSubkeys) {
    encryptionKey = keys.nameEncryption
    nonceKey = keys.nameNonce
  }

  /// A name as it appears decrypted: NFC-normalized; fails for names no file system takes (`..`, `/`, NUL, empty).
  public static func normalized(_ name: String) throws -> String {
    let name = name.precomposedStringWithCanonicalMapping
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
      throw VaultFilesError.invalidName(name)
    }
    return name
  }

  /// The encrypted form of `name` in the directory with id `directoryID`.
  public func encrypt(_ name: String, directoryID: Data) throws -> String {
    let plaintext = Data(try Self.normalized(name).utf8)
    let nonce = try syntheticNonce(plaintext, directoryID: directoryID)
    let box = try AES.GCM.seal(plaintext, using: encryptionKey, nonce: nonce, authenticating: directoryID)
    return Base64URL.encode(Data(nonce) + box.ciphertext + box.tag)
  }

  /// The name `encoded` stands for in the directory with id `directoryID`.
  public func decrypt(_ encoded: String, directoryID: Data) throws -> String {
    guard let data = Base64URL.decode(encoded), data.count >= Self.nonceSize + EncryptedFile.tagSize else {
      throw VaultFilesError.damaged
    }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: data.prefix(Self.nonceSize)),
        ciphertext: data.dropFirst(Self.nonceSize).dropLast(EncryptedFile.tagSize),
        tag: data.suffix(EncryptedFile.tagSize))
      let plaintext = try AES.GCM.open(box, using: encryptionKey, authenticating: directoryID)
      // Only the canonical encryption of a name counts (the synthetic nonce must match).
      guard Data(try syntheticNonce(plaintext, directoryID: directoryID)) == data.prefix(Self.nonceSize),
        let name = String(data: plaintext, encoding: .utf8)
      else { throw VaultFilesError.damaged }
      return name
    } catch {
      throw VaultFilesError.damaged
    }
  }

  private func syntheticNonce(_ name: Data, directoryID: Data) throws -> AES.GCM.Nonce {
    var message = Data([UInt8(directoryID.count)])
    message.append(directoryID)
    message.append(name)
    let mac = HMAC<SHA256>.authenticationCode(for: message, using: nonceKey)
    return try AES.GCM.Nonce(data: Data(mac).prefix(Self.nonceSize))
  }
}

/// How an encrypted name sits on disk. Encrypted names use only base64url characters (no dots), so every name with
/// a dot is the format's own: `dir.v57`, `folder.v57`, long-name entries and their sidecars, and temporary files.
///
/// A name longer than `NameCipher.maxEncodedLength` would break file systems' 255-byte limit, so its entry is
/// `<base64url SHA-256 of the encrypted name>.long` and a sidecar `<same>.name` next to it holds the full
/// encrypted name. The hash is deterministic too, so lookups still need no index.
public enum DiskName {
  public static let longSuffix = ".long"
  public static let sidecarSuffix = ".name"

  /// The entry name for an encrypted name, and the sidecar file name when it is shortened.
  public static func forEncrypted(_ encrypted: String) -> (entry: String, sidecar: String?) {
    guard encrypted.utf8.count > NameCipher.maxEncodedLength else { return (encrypted, nil) }
    let base = Base64URL.encode(Data(SHA256.hash(data: Data(encrypted.utf8))))
    return (base + longSuffix, base + sidecarSuffix)
  }

  /// What a directory entry is: an encrypted name, a shortened one (read its sidecar), or the format's own file.
  public enum Kind: Equatable {
    case encrypted(String)
    case long(sidecar: String)
    case other
  }

  public static func kind(of entry: String) -> Kind {
    if !entry.contains(".") { return .encrypted(entry) }
    if entry.hasSuffix(longSuffix), !entry.hasPrefix(".") {
      return .long(sidecar: String(entry.dropLast(longSuffix.count)) + sidecarSuffix)
    }
    return .other
  }
}

/// Base64 with the URL and file-name safe alphabet (`-`, `_`) and no padding.
public enum Base64URL {
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func decode(_ string: String) -> Data? {
    guard string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
      return nil
    }
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    // Only the canonical encoding (unused trailing bits zero), so one name has exactly one spelling.
    guard let data = Data(base64Encoded: base64), encode(data) == string else { return nil }
    return data
  }
}
