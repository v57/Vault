import Foundation

#if canImport(LocalAuthentication)
  import LocalAuthentication
#endif

/// Vault's app lock (security audit M13): Touch ID, Face ID or the device password before the vault shows, before a
/// secret is shown or copied, and before AutoFill fills a password without showing anything. One unlock holds for
/// `grace` (5 minutes) in the app and its AutoFill extension both, as Passwords and 1Password do.
///
/// On by default; Settings ▸ General turns it off. The switch and the last unlock are this device's (never synced:
/// unlocking the Mac says nothing about who holds the iPad) and live in the secrets group, which only Vault and its
/// AutoFill extension open, so neither another app nor a `defaults write` turns the lock off or forges an unlock.
///
/// A device with no password at all has nothing to ask for: everything opens, as it does for Passwords. Demo runs and
/// tests (`VaultSecrets.useInMemoryStore()`) keep both values in memory.
public enum VaultAppLock {
  /// How long one unlock lets secrets through.
  public static let grace: TimeInterval = 5 * 60

  static let keychain = VaultKeychain(service: "dev.v57.vault.lock", accessGroup: VaultConfiguration.secretsGroup)
  static let offAccount = "off"
  static let unlockedAccount = "unlocked"

  private static let lock = NSLock()
  nonisolated(unsafe) private static var memory: [String: Data] = [:]
  /// The question itself (Touch ID, Face ID or the password): replaced by tests.
  nonisolated(unsafe) static var authenticate: @Sendable (String) async -> Bool = { await askOwner(reason: $0) }
  /// The clock, for tests.
  nonisolated(unsafe) static var now: @Sendable () -> Date = { Date() }

  /// Whether Vault asks at all (the setting, on unless turned off).
  public static var isEnabled: Bool { read(offAccount) == nil }

  /// Turns the lock on or off. Turning it off asks first, always, even inside the grace period: whoever has the
  /// unlocked app for a minute shouldn't leave it unlocked for good.
  @MainActor
  public static func setEnabled(_ enabled: Bool, reason: String) async -> Bool {
    if enabled {
      write(nil, offAccount)
      return true
    }
    guard await authenticate(reason) else { return false }
    write(Data([1]), offAccount)
    return true
  }

  /// Whether secrets open without asking now: the lock is off, or the last unlock was less than `grace` ago (a clock
  /// set back counts as no unlock).
  public static var isUnlocked: Bool {
    guard isEnabled else { return true }
    guard let last = lastUnlock else { return false }
    let elapsed = now().timeIntervalSince(last)
    return elapsed >= 0 && elapsed < grace
  }

  /// When the owner last proved it was them, on this device.
  static var lastUnlock: Date? {
    guard let data = read(unlockedAccount), let seconds = Double(String(decoding: data, as: UTF8.self)) else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  /// Asks (Touch ID, Face ID or the password) unless an unlock less than `grace` ago still holds; true when the
  /// secret may open. `reason` finishes the system's sentence ("Vault wants to show the password").
  @MainActor
  public static func unlock(reason: String) async -> Bool {
    if isUnlocked { return true }
    return await unlockNow(reason: reason)
  }

  /// Asks whatever the grace period says (the launch, the return after minutes away), and starts a new one.
  @MainActor
  public static func unlockNow(reason: String) async -> Bool {
    guard isEnabled else { return true }
    guard await authenticate(reason) else { return false }
    write(Data(String(now().timeIntervalSince1970).utf8), unlockedAccount)
    return true
  }

  /// Ends the grace period (Lock Vault, or the app going away for longer than `grace`).
  public static func lockNow() {
    write(nil, unlockedAccount)
  }

  // MARK: Storage

  private static func read(_ account: String) -> Data? {
    if VaultSecrets.isInMemory { return lock.withLock { memory[account] } }
    return (try? keychain.read(account, options: .thisDevice)) ?? nil
  }

  private static func write(_ data: Data?, _ account: String) {
    if VaultSecrets.isInMemory { return lock.withLock { memory[account] = data } }
    if let data {
      try? keychain.write(data, account: account, options: VaultKeychain.Options(synchronizable: false, label: "Vault app lock"))
    } else {
      try? keychain.delete(account, options: .thisDevice)
    }
  }

  /// Tests: forgets the setting and the last unlock.
  static func reset() {
    lock.withLock { memory = [:] }
  }

  // MARK: Asking

  private static func askOwner(reason: String) async -> Bool {
    #if canImport(LocalAuthentication)
      let context = LAContext()
      var error: NSError?
      guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
        // No password, Touch ID or Face ID on this device: there's no owner to tell apart.
        return error?.code == LAError.passcodeNotSet.rawValue
      }
      return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    #else
      // Linux and Windows have no Vault app yet; their kits read secrets as every app does.
      return true
    #endif
  }
}
