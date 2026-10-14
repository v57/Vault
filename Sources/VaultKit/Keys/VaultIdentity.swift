import CryptoKit
import Foundation

/// This device's SSH key: a P-256 key made inside the Secure Enclave, shared by every v57 app on the device.
///
/// The private key never leaves the chip; the keychain (shared access group, this device only) holds the
/// Secure Enclave's wrapped blob, which is useless on another device. Each device has its own key, published
/// in the vault as a `VaultDeviceKey` so the others can add it to a server's `authorized_keys`.
public enum VaultIdentity {
  static let keychain = VaultKeychain()
  static let account = "ssh-identity"

  public enum IdentityError: LocalizedError {
    case secureEnclaveUnavailable
    case invalidKey

    public var errorDescription: String? {
      switch self {
      case .secureEnclaveUnavailable: "This device has no Secure Enclave, so it can't hold an SSH key."
      case .invalidKey: "The saved SSH key belongs to another device or is damaged."
      }
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var cached: SecureEnclave.P256.Signing.PrivateKey?

  /// The key, made on first use.
  public static func key() throws -> SecureEnclave.P256.Signing.PrivateKey {
    lock.lock()
    defer { lock.unlock() }
    if let cached { return cached }
    guard SecureEnclave.isAvailable else { throw IdentityError.secureEnclaveUnavailable }
    if let blob = try keychain.read(account, options: .thisDevice) {
      guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) else {
        throw IdentityError.invalidKey
      }
      cached = key
      return key
    }
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    do {
      try keychain.addNew(
        key.dataRepresentation, account: account,
        options: .init(synchronizable: false, label: "v57 SSH key (Secure Enclave)"))
    } catch VaultKeychain.KeychainError.status(errSecDuplicateItem) {
      // Another app made it a moment ago: use that one.
      if let blob = try keychain.read(account, options: .thisDevice),
        let existing = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
      {
        cached = existing
        return existing
      }
    }
    cached = key
    return key
  }

  /// Takes over an existing Secure Enclave key of this device (its wrapped blob), so servers that already
  /// trust it keep working: an app that had its own key before the vault (Shell) hands it over once. Does
  /// nothing when the device already has a vault key.
  public static func adopt(_ blob: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    guard (try keychain.read(account, options: .thisDevice)) == nil else { return }
    let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
    try keychain.addNew(blob, account: account, options: .init(synchronizable: false, label: "v57 SSH key (Secure Enclave)"))
    cached = key
  }

  /// Whether the key exists (without making it).
  public static var exists: Bool {
    (try? keychain.read(account, options: .thisDevice)) != nil
  }

  // MARK: SSH formats

  /// The public key in SSH wire format (RFC 5656):
  /// string("ecdsa-sha2-nistp256") + string("nistp256") + string(Q), Q the uncompressed point.
  public static func publicKeyBlob(_ key: SecureEnclave.P256.Signing.PrivateKey) -> Data {
    let point = Data([0x04]) + key.publicKey.rawRepresentation
    return SSHWire.string("ecdsa-sha2-nistp256") + SSHWire.string("nistp256") + SSHWire.string(point)
  }

  /// "ecdsa-sha2-nistp256 AAAA… comment", for `authorized_keys`.
  public static func publicKeyLine(_ key: SecureEnclave.P256.Signing.PrivateKey, comment: String) -> String {
    "ecdsa-sha2-nistp256 \(publicKeyBlob(key).base64EncodedString()) \(comment)"
  }

  /// "SHA256:…", as `ssh-keygen -l` prints it.
  public static func fingerprint(blob: Data) -> String {
    "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
  }

  /// The fingerprint of an `authorized_keys` line, nil when it isn't one.
  public static func fingerprint(keyLine: String) -> String? {
    let fields = keyLine.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])), !blob.isEmpty else { return nil }
    return fingerprint(blob: blob)
  }

  /// The signature of `data` as SSH wants it from a libssh2 sign callback: mpint(r) + mpint(s).
  public static func sshSignature(_ data: Data, key: SecureEnclave.P256.Signing.PrivateKey) throws -> Data {
    let raw = try key.signature(for: data).rawRepresentation
    return SSHWire.mpint(raw.prefix(32)) + SSHWire.mpint(raw.suffix(32))
  }
}

/// SSH wire encodings (RFC 4251).
public enum SSHWire {
  /// UInt32 big-endian length + bytes.
  public static func string(_ data: Data) -> Data {
    var length = UInt32(data.count).bigEndian
    return Data(bytes: &length, count: 4) + data
  }

  public static func string(_ text: String) -> Data { string(Data(text.utf8)) }

  /// A positive big-endian integer: leading zeros stripped, one zero byte added when the high bit is set.
  public static func mpint(_ bytes: Data) -> Data {
    var payload = Array(bytes)
    while payload.count > 1 && payload[0] == 0 { payload.removeFirst() }
    if let first = payload.first, first & 0x80 != 0 { payload.insert(0, at: 0) }
    return string(Data(payload))
  }
}
