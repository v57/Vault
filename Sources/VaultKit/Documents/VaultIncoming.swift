import CryptoKit
import Foundation

/// Files shared to Vault's share extension, which holds no keys (security audit M4): it seals them to Vault's drop key
/// (HPKE, X25519) and leaves them in the app group container, and Vault files them in the Inbox the next time it runs
/// (`collect`). Only the public key sits beside the store; the private one is in the keychain group only Vault lists.
public struct VaultIncoming: Sendable {
  public let folder: URL

  public init(folder: URL = VaultConfiguration.defaultDirectory().appendingPathComponent("Incoming", isDirectory: true)) {
    self.folder = folder
  }

  static let publicKeyName = "drop-key.pub"
  static let fileExtension = "v57drop"
  static let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
  static let info = Data("dev.v57.vault.incoming".utf8)
  static let version: UInt8 = 1

  public enum IncomingError: LocalizedError {
    case noKey

    public var errorDescription: String? {
      switch self {
      case .noKey: "Open Vault on this device once first, so there’s a vault to add to."
      }
    }
  }

  // MARK: The extension's side

  /// The key Vault published; nil until Vault has run here.
  public var publicKey: Curve25519.KeyAgreement.PublicKey? {
    (try? Data(contentsOf: folder.appendingPathComponent(Self.publicKeyName)))
      .flatMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
  }

  /// Seals the files to Vault's key and leaves them for Vault, as one drop.
  public func drop(_ files: [SharedFile]) throws {
    guard let publicKey else { throw IncomingError.noKey }
    let plaintext = try PropertyListEncoder().encode(files.map(Drop.File.init))
    var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: Self.suite, info: Self.info)
    let sealed = Data([Self.version]) + sender.encapsulatedKey + (try sender.seal(plaintext))
    let name = "\(UUID().uuidString).\(Self.fileExtension)"
    let temporary = folder.appendingPathComponent(".\(name).tmp")
    try sealed.write(to: temporary, options: .atomic)
    try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent(name))
  }

  // MARK: Vault's side

  /// Writes the public key of `key` beside the store, for the extension.
  public func publish(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent(Self.publicKeyName)
    let raw = key.publicKey.rawRepresentation
    if (try? Data(contentsOf: file)) != raw { try raw.write(to: file, options: .atomic) }
  }

  /// Every drop that opens with `key`, oldest first, each removed once `file` took it. A drop that doesn't open (another
  /// key's, or damaged) stays for a later look and counts in `failed`.
  public func collect(with key: Curve25519.KeyAgreement.PrivateKey, file: ([SharedFile]) throws -> Void) -> (taken: Int, failed: Int) {
    let manager = FileManager.default
    let drops = ((try? manager.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? [])
      .filter { $0.pathExtension == Self.fileExtension }
      .sorted {
        let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return a < b
      }
    var result = (taken: 0, failed: 0)
    for drop in drops {
      do {
        let bytes = try Data(contentsOf: drop)
        guard bytes.count > 33, bytes.first == Self.version else { throw CocoaError(.fileReadCorruptFile) }
        let start = bytes.startIndex
        var recipient = try HPKE.Recipient(
          privateKey: key, ciphersuite: Self.suite, info: Self.info, encapsulatedKey: bytes[(start + 1)..<(start + 33)])
        let plaintext = try recipient.open(bytes[(start + 33)...])
        let files = try PropertyListDecoder().decode([Drop.File].self, from: plaintext).map(\.shared)
        try file(files)
        try manager.removeItem(at: drop)
        result.taken += 1
      } catch {
        result.failed += 1
      }
    }
    return result
  }

  /// This device's drop key, in the keychain group only Vault lists (memory in demo runs and tests). Made on first use.
  public static func vaultKey() throws -> Curve25519.KeyAgreement.PrivateKey {
    if VaultSecrets.isInMemory {
      return memoryKey.withLock { key in
        if let key { return key }
        let made = Curve25519.KeyAgreement.PrivateKey()
        key = made
        return made
      }
    }
    let keychain = VaultKeychain(service: "dev.v57.vault", accessGroup: VaultConfiguration.secretsGroup)
    let account = "incoming.drop-key"
    if let raw = try keychain.read(account, options: .thisDevice) {
      return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }
    let key = Curve25519.KeyAgreement.PrivateKey()
    try keychain.write(key.rawRepresentation, account: account, options: .init(synchronizable: false, label: "Vault share key"))
    return key
  }

  private static let memoryKey = LockedValue<Curve25519.KeyAgreement.PrivateKey?>(nil)

  struct Drop {
    struct File: Codable {
      var name: String
      var contentType: String
      var data: Data
      var width: Int
      var height: Int
      var pageCount: Int
      var thumbnail: Data?

      init(_ file: SharedFile) {
        name = file.name
        contentType = file.contentType
        data = file.data
        width = file.width
        height = file.height
        pageCount = file.pageCount
        thumbnail = file.thumbnail
      }

      var shared: SharedFile {
        SharedFile(
          name: name, contentType: contentType, data: data, width: width, height: height, pageCount: pageCount,
          thumbnail: thumbnail)
      }
    }
  }
}

/// A value behind a lock.
final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
