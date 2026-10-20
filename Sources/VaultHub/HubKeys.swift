import CryptoKit
import Foundation
import VaultKit

/// An Ed25519 key in Hub's encodings (`Docs/Devices/protocol.md` §1): this device's key on every Hub, or the key the
/// apps connect with.
public struct HubKey: Sendable {
  let privateKey: Curve25519.Signing.PrivateKey

  public init() { privateKey = Curve25519.Signing.PrivateKey() }

  public init(seed: Data) throws { privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed) }

  /// The seed (32 bytes).
  public var seed: Data { privateKey.rawRepresentation }

  /// The public key as base64 SubjectPublicKeyInfo DER, as Hub writes every key.
  public var spki: String { (Self.spkiPrefix + privateKey.publicKey.rawRepresentation).base64EncodedString() }

  /// The base64 Ed25519 signature of the text's UTF-8 bytes.
  public func sign(_ text: String) -> String {
    (try? privateKey.signature(for: Data(text.utf8)).base64EncodedString()) ?? ""
  }

  /// Hub's device id for a key: the first 32 hex characters of the SHA-256 of its SPKI bytes.
  public static func deviceID(spki: String) -> String? {
    guard let data = Data(base64Encoded: spki) else { return nil }
    return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32))
  }

  /// The code shown on the device and the one approving it ("474 971").
  public static func safetyCode(spki: String) -> String? {
    guard let data = Data(base64Encoded: spki) else { return nil }
    let value = SHA256.hash(data: data).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
    let digits = String(format: "%06d", value)
    return "\(digits.prefix(3)) \(digits.suffix(3))"
  }

  /// Whether `signature` (base64) is the key's signature of `text`.
  public static func verify(_ signature: String, of text: String, spki: String) -> Bool {
    guard let data = Data(base64Encoded: spki), data.count == 44, data.starts(with: spkiPrefix),
      let signature = Data(base64Encoded: signature),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data.dropFirst(spkiPrefix.count))
    else { return false }
    return key.isValidSignature(signature, for: Data(text.utf8))
  }

  // MARK: Key files

  /// The key file format (base64 of PKCS#8 DER then SPKI DER, 92 bytes), which `~/.hub/device.key` uses.
  public var keyFile: String {
    (Self.pkcs8Prefix + seed + Self.spkiPrefix + privateKey.publicKey.rawRepresentation).base64EncodedString()
  }

  public init(keyFile: String) throws {
    guard let data = Data(base64Encoded: keyFile.trimmingCharacters(in: .whitespacesAndNewlines)),
      data.count == 92, data.starts(with: Self.pkcs8Prefix)
    else { throw HubKeyError.badKeyFile }
    try self.init(seed: data.subdata(in: 16..<48))
  }

  static let spkiPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
  static let pkcs8Prefix = Data([
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
  ])
}

public enum HubKeyError: LocalizedError {
  case badKeyFile

  public var errorDescription: String? { "The Hub key file isn’t an Ed25519 key." }
}

/// Where this device keeps its Hub keys. They never leave the device: a key that synced would let a stolen backup
/// connect as this device.
///
/// - The device key: on the Mac `~/.hub/device.key` (or `HUB_DEVICE_KEY`), the file Hub's launcher and services use,
///   so the Mac is one device on the Hub whichever of them made it. On iPhone and iPad, a this-device-only item in
///   the v57 keychain group: every v57 app there is one device, apart from the Hub app (protocol §3: an app that
///   can't share the device key becomes its own device).
/// - The key the v57 apps connect with: a this-device-only item in the v57 keychain group.
///
/// Demo runs and tests (`VaultSecrets.useInMemoryStore()`) keep both in memory.
public enum HubKeyStore {
  nonisolated(unsafe) private static var memory: [String: HubKey] = [:]
  private static let lock = NSLock()

  public static func deviceKey() throws -> HubKey {
    if VaultSecrets.isInMemory { return inMemory("device") }
    #if os(macOS)
      return try fileKey(at: deviceKeyFile)
    #else
      return try keychainKey("hub.device-key", label: "Hub device key")
    #endif
  }

  public static func clientKey() throws -> HubKey {
    if VaultSecrets.isInMemory { return inMemory("client") }
    return try keychainKey("hub.client-key", label: "v57 Hub key")
  }

  /// `HUB_DEVICE_KEY`, else `~/.hub/device.key`.
  static var deviceKeyFile: URL {
    if let path = ProcessInfo.processInfo.environment["HUB_DEVICE_KEY"], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".hub/device.key")
  }

  private static func inMemory(_ name: String) -> HubKey {
    lock.withLock {
      if let key = memory[name] { return key }
      let key = HubKey()
      memory[name] = key
      return key
    }
  }

  /// Reads the key file, or makes it (directory 0700, file 0600, written to a temporary file and renamed).
  static func fileKey(at url: URL) throws -> HubKey {
    if let text = try? String(contentsOf: url, encoding: .utf8) { return try HubKey(keyFile: text) }
    let directory = url.deletingLastPathComponent()
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = HubKey()
    let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
    guard files.createFile(atPath: temporary.path, contents: Data(key.keyFile.utf8), attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    do {
      // Another process may have made it meanwhile: keep theirs.
      if files.fileExists(atPath: url.path) {
        try? files.removeItem(at: temporary)
        return try HubKey(keyFile: String(contentsOf: url, encoding: .utf8))
      }
      try files.moveItem(at: temporary, to: url)
    } catch {
      try? files.removeItem(at: temporary)
      throw error
    }
    return key
  }

  private static func keychainKey(_ account: String, label: String) throws -> HubKey {
    let keychain = VaultKeychain()
    if let seed = try keychain.read(account, options: .thisDevice) { return try HubKey(seed: seed) }
    let key = HubKey()
    do {
      try keychain.addNew(key.seed, account: account, options: .init(synchronizable: false, label: label))
      return key
    } catch {
      // Another v57 app on the device made it first.
      if let seed = try keychain.read(account, options: .thisDevice) { return try HubKey(seed: seed) }
      throw error
    }
  }
}
