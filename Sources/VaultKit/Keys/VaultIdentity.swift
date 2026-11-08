import CryptoKit
import Foundation

#if canImport(LocalAuthentication)
  import LocalAuthentication
  import Security
#endif
#if canImport(AppKit)
  import AppKit
#endif

/// This device's SSH key: a P-256 key made inside the Secure Enclave, shared by every v57 app on the device.
///
/// The private key never leaves the chip; the keychain (shared access group, this device only) holds the
/// Secure Enclave's wrapped blob, which is useless on another device. Each device has its own key, published
/// in the vault as a `VaultDeviceKey` so the others can add it to a server's `authorized_keys`.
///
/// **A key made since 2026-11-04 needs the user** (`.userPresence`, where the device has a passcode or a login password):
/// the Secure Enclave won't sign with it for a process that hasn't had Touch ID, Face ID or the password. `key()` and
/// `signature(for:key:)` never ask, so anything in the background just fails with `presenceNeeded`; what the user started
/// asks through `presencePrompt(reason:)` or `confirmPresence(reason:)`, and that yes lasts `presenceWindow` in this app.
/// **A key made before that keeps working as it did, with nothing asked:** a new key would lock the user out of every
/// server that trusts this one, so it's never replaced here.
public enum VaultIdentity {
  static let keychain = VaultKeychain()
  static let account = "ssh-identity"

  public enum IdentityError: LocalizedError {
    case secureEnclaveUnavailable
    case invalidKey
    /// The key needs the user, and nobody confirmed it just now.
    case presenceNeeded

    public var errorDescription: String? {
      switch self {
      case .secureEnclaveUnavailable: "This device has no Secure Enclave, so it can't hold an SSH key."
      case .invalidKey: "The saved SSH key belongs to another device or is damaged."
      case .presenceNeeded: "This device's SSH key signs only after you confirm it's you. Try again to be asked."
      }
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var cached: SecureEnclave.P256.Signing.PrivateKey?

  /// The key, made on first use.
  public static func key() throws -> SecureEnclave.P256.Signing.PrivateKey {
    lock.lock()
    defer { lock.unlock() }
    #if canImport(LocalAuthentication)
      if let presenceBlob { return try bound(presenceBlob) }
    #endif
    if let cached { return cached }
    guard SecureEnclave.isAvailable else { throw IdentityError.secureEnclaveUnavailable }
    if let saved = try loadSaved() { return saved }
    #if canImport(LocalAuthentication)
      if let made = makeKeyThatAsks() {
        do {
          try keychain.addNew(made, account: account, options: .init(synchronizable: false, label: presenceLabel))
          presenceBlob = made
          return try bound(made)
        } catch VaultKeychain.KeychainError.status(errSecDuplicateItem) {
          if let saved = try loadSaved() { return saved }
        }
      }
    #endif
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    do {
      try keychain.addNew(
        key.dataRepresentation, account: account,
        options: .init(synchronizable: false, label: "v57 SSH key (Secure Enclave)"))
    } catch VaultKeychain.KeychainError.status(errSecDuplicateItem) {
      // Another app made it a moment ago: use that one.
      if let saved = try loadSaved() { return saved }
    }
    cached = key
    return key
  }

  /// The key the keychain holds, as whatever it was made: this never makes or changes one.
  private static func loadSaved() throws -> SecureEnclave.P256.Signing.PrivateKey? {
    guard let blob = try keychain.read(account, options: .thisDevice) else { return nil }
    #if canImport(LocalAuthentication)
      if (try? keychain.attributes(of: account, options: .thisDevice))?.label == presenceLabel {
        presenceBlob = blob
        return try bound(blob)
      }
    #endif
    guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) else {
      throw IdentityError.invalidKey
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

  /// Whether this device's Secure Enclave opens a key's wrapped blob: false for another device's (a backup restored
  /// elsewhere). Opening it signs nothing, so it asks nothing.
  public static func opensHere(_ blob: Data) -> Bool {
    guard SecureEnclave.isAvailable else { return false }
    #if canImport(LocalAuthentication)
      if (try? bound(blob)) != nil { return true }
    #endif
    return (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)) != nil
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
    let raw = try signature(for: data, key: key).rawRepresentation
    return SSHWire.mpint(raw.prefix(32)) + SSHWire.mpint(raw.suffix(32))
  }
}

// MARK: The user's presence

extension VaultIdentity {
  /// How long a yes lasts in the app that asked.
  public static let presenceWindow = Duration.seconds(15 * 60)

  @TaskLocal private static var isQuiet = false

  static var isQuietForTesting: Bool { isQuiet }

  /// Runs `body` as work nobody started just now (Git's auto-fetch): whatever it signs with a key that needs the user fails
  /// with `presenceNeeded` unless a window is open, and nothing is asked.
  public static func quietly<T>(_ body: () async throws -> T) async rethrows -> T {
    try await $isQuiet.withValue(true) { try await body() }
  }

  #if canImport(LocalAuthentication)
    /// How a key made to need the user is told from one made before: the item's label, written with it in one step. It only
    /// decides how this code behaves; the Secure Enclave enforces what the key was made with, whatever the label says.
    static let presenceLabel = "v57 SSH key (Secure Enclave, confirms it's you)"

    /// Set once the key is known to need the user. Guarded by `lock`.
    nonisolated(unsafe) fileprivate static var presenceBlob: Data?

    /// Asks for nothing: with this, signing with a key that needs the user fails at once.
    nonisolated(unsafe) private static let quietContext: LAContext = {
      let context = LAContext()
      context.interactionNotAllowed = true
      return context
    }()

    private final class Answer: @unchecked Sendable {
      var succeeded = false
      var error: Error?
    }

    /// A context held for the length of a window: the proof each signature shows the Secure Enclave. It doesn't set
    /// `touchIDAuthenticationAllowableReuseDuration`, which would let a new window open with no question for up to 5 minutes
    /// after the Mac was last unlocked with Touch ID.
    nonisolated(unsafe) private static let gate: PresenceGate<LAContext> = {
      let gate = PresenceGate<LAContext>(
        length: presenceWindow,
        isFrontmost: {
          #if canImport(AppKit)
            NSRunningApplication.current.isActive
          #else
            // On iOS the system refuses to ask for an app that isn't active.
            true
          #endif
        },
        ask: { reason in
          let context = LAContext()
          let answer = Answer()
          let done = DispatchSemaphore(value: 0)
          context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { succeeded, error in
            answer.succeeded = succeeded
            answer.error = error
            done.signal()
          }
          done.wait()
          guard answer.succeeded else { throw answer.error ?? IdentityError.presenceNeeded }
          return context
        },
        ended: { $0.invalidate() })
      // Locking the device ends the window, whatever's left of it.
      #if os(macOS)
        DistributedNotificationCenter.default().addObserver(
          forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil
        ) { _ in gate.close() }
      #else
        NotificationCenter.default.addObserver(
          forName: Notification.Name("UIApplicationProtectedDataWillBecomeUnavailable"), object: nil, queue: nil
        ) { _ in gate.close() }
      #endif
      return gate
    }()

    /// The key, signing with the open window's proof or, with none, with nothing, so it fails instead of asking.
    fileprivate static func bound(_ blob: Data) throws -> SecureEnclave.P256.Signing.PrivateKey {
      do {
        return try SecureEnclave.P256.Signing.PrivateKey(
          dataRepresentation: blob, authenticationContext: gate.credential ?? quietContext)
      } catch {
        throw IdentityError.invalidKey
      }
    }

    /// A new Secure Enclave key that needs the user, as its wrapped blob. Nil where it can't be: a device with no passcode or
    /// login password has nothing to ask for, and no key at all would be worse than one that doesn't ask.
    fileprivate static func makeKeyThatAsks() -> Data? {
      guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil),
        let access = SecAccessControlCreateWithFlags(
          nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil)
      else { return nil }
      return (try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: quietContext))?
        .dataRepresentation
    }
  #endif

  /// Whether this device's key was made to need the user. False for a key made before that, and with no key yet. Doesn't make one.
  public static var asksForPresence: Bool {
    #if canImport(LocalAuthentication)
      lock.lock()
      defer { lock.unlock() }
      if presenceBlob != nil { return true }
      if cached != nil { return false }
      return (try? keychain.attributes(of: account, options: .thisDevice))?.label == presenceLabel
    #else
      return false
    #endif
  }

  /// Whether this app can sign without asking right now: its key doesn't need the user, or a window is open.
  public static var canSignWithoutAsking: Bool {
    #if canImport(LocalAuthentication)
      return !asksForPresence || gate.credential != nil
    #else
      return true
    #endif
  }

  /// The signature of `data`, through the open window if `key` needs one. It never asks.
  public static func signature(
    for data: Data, key: SecureEnclave.P256.Signing.PrivateKey
  ) throws -> P256.Signing.ECDSASignature {
    #if canImport(LocalAuthentication)
      lock.lock()
      let blob = presenceBlob
      lock.unlock()
      if let blob, blob == key.dataRepresentation {
        do {
          return try bound(blob).signature(for: data)
        } catch {
          // Out of window, or the system stopped honoring it: the next thing the user starts asks again.
          gate.close()
          throw IdentityError.presenceNeeded
        }
      }
    #endif
    return try key.signature(for: data)
  }

  /// For a login: asks if the key needs the user and no window is open, unless it's `unattended` or inside `quietly`. Blocks
  /// while asking, so call it off the main thread. Throws `presenceNeeded` if there's no yes. Does nothing for a key that
  /// doesn't need the user.
  public static func confirm(reason: String, unattended: Bool = false) throws {
    #if canImport(LocalAuthentication)
      guard asksForPresence else { return }
      do {
        try gate.prepare(reason: reason, unattended: unattended)
      } catch {
        throw IdentityError.presenceNeeded
      }
    #endif
  }

  /// `SSHKey`'s `prepare`: `confirm` at the moment of the login, remembering whether this was made inside `quietly`.
  public static func presencePrompt(
    reason: String = "sign in with this device's SSH key"
  ) -> @Sendable (_ unattended: Bool) throws -> Void {
    let quiet = isQuiet
    return { unattended in try confirm(reason: reason, unattended: unattended || quiet) }
  }

  /// `confirm` from async code, for what the user just clicked.
  public static func confirmPresence(reason: String) async throws {
    let quiet = isQuiet
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try confirm(reason: reason, unattended: quiet) })
      }
    }
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
