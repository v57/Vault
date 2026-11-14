import CryptoKit
import Foundation

#if canImport(LocalAuthentication)
  import LocalAuthentication
  import Security
#endif

/// Which key the agent offers: its own (the default) or this device's, the one Shell, Git and Database use.
public enum SSHAgentKeyChoice: String, Sendable, CaseIterable, Codable {
  /// A second Secure Enclave key, made for the agent only (`VaultAgentKey`): turning the agent off or replacing it never
  /// locks the apps out of a server.
  case agent
  /// `VaultIdentity`'s key: every server that trusts this device is open to what the agent lets in.
  case device
}

/// The user's yes for signing: an `LAContext` that Touch ID, a watch or the password answered. A Secure Enclave key made
/// to need the user signs only with one. It lasts until `invalidate()` (the agent stops, the screen locks).
public final class SSHAgentProof: @unchecked Sendable {
  #if canImport(LocalAuthentication)
    public let context: LAContext?

    public init(context: LAContext?) { self.context = context }

    /// Asks (Touch ID, a watch or the password), with `reason` finishing "Vault is trying to …".
    public static func ask(reason: String) async throws -> SSHAgentProof {
      let context = LAContext()
      try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
      return SSHAgentProof(context: context)
    }

    public func invalidate() { context?.invalidate() }
  #else
    public init() {}
    public func invalidate() {}
  #endif

  /// A proof that asked nothing: for keys that don't need the user (tests, the demo).
  public static var none: SSHAgentProof {
    #if canImport(LocalAuthentication)
      SSHAgentProof(context: nil)
    #else
      SSHAgentProof()
    #endif
  }
}

/// The keys the agent signs with.
public protocol SSHAgentKeys: Sendable {
  /// The key's SSH wire blob (`ecdsa-sha2-nistp256`); makes the agent key on first use.
  func publicKeyBlob(_ choice: SSHAgentKeyChoice) throws -> Data
  /// mpint(r) + mpint(s) over `data`, with the user's `proof`.
  func sign(_ data: Data, with choice: SSHAgentKeyChoice, proof: SSHAgentProof) throws -> Data
  /// Throws the agent key away and makes a new one: servers that trusted the old one no longer let the agent in.
  func replaceAgentKey() throws
}

/// The real keys: the agent key in this app's own keychain group (no other v57 app reads it), and this device's key.
public struct SecureEnclaveAgentKeys: SSHAgentKeys {
  static let keychain = VaultKeychain(accessGroup: VaultConfiguration.ownGroup)
  static let account = "ssh-agent-key"

  public init() {}

  public func publicKeyBlob(_ choice: SSHAgentKeyChoice) throws -> Data {
    switch choice {
    case .device:
      return VaultIdentity.publicKeyBlob(try VaultIdentity.key())
    case .agent:
      let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: try agentBlob())
      return VaultIdentity.publicKeyBlob(key)
    }
  }

  public func sign(_ data: Data, with choice: SSHAgentKeyChoice, proof: SSHAgentProof) throws -> Data {
    let signature: P256.Signing.ECDSASignature
    switch choice {
    case .device:
      signature = try VaultIdentity.signature(for: data, proof: proof)
    case .agent:
      #if canImport(LocalAuthentication)
        let key = try SecureEnclave.P256.Signing.PrivateKey(
          dataRepresentation: try agentBlob(), authenticationContext: proof.context ?? LAContext())
      #else
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: try agentBlob())
      #endif
      signature = try key.signature(for: data)
    }
    let raw = signature.rawRepresentation
    return SSHWire.mpint(raw.prefix(32)) + SSHWire.mpint(raw.suffix(32))
  }

  public func replaceAgentKey() throws {
    try? Self.keychain.delete(Self.account, options: .thisDevice)
    _ = try agentBlob()
  }

  /// The agent key's wrapped blob, made on first use: needing the user where the device has a password to ask for.
  private func agentBlob() throws -> Data {
    if let blob = try Self.keychain.read(Self.account, options: .thisDevice) { return blob }
    guard SecureEnclave.isAvailable else { throw VaultIdentity.IdentityError.secureEnclaveUnavailable }
    var blob: Data?
    #if canImport(LocalAuthentication)
      if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil),
        let access = SecAccessControlCreateWithFlags(
          nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil)
      {
        blob = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access).dataRepresentation
      }
    #endif
    let made = try blob ?? SecureEnclave.P256.Signing.PrivateKey().dataRepresentation
    do {
      try Self.keychain.addNew(made, account: Self.account, options: .init(synchronizable: false, label: "v57 SSH agent key (Secure Enclave)"))
    } catch VaultKeychain.KeychainError.status(errSecDuplicateItem) {
      if let saved = try Self.keychain.read(Self.account, options: .thisDevice) { return saved }
    }
    return made
  }
}

/// Software keys in memory: tests and the demo, never the user's keychain.
public final class SoftwareAgentKeys: SSHAgentKeys, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [SSHAgentKeyChoice: P256.Signing.PrivateKey] = [.agent: .init(), .device: .init()]

  public init() {}

  public func publicKeyBlob(_ choice: SSHAgentKeyChoice) throws -> Data {
    let point = Data([0x04]) + lock.withLock { keys[choice]! }.publicKey.rawRepresentation
    return SSHWire.string("ecdsa-sha2-nistp256") + SSHWire.string("nistp256") + SSHWire.string(point)
  }

  public func sign(_ data: Data, with choice: SSHAgentKeyChoice, proof: SSHAgentProof) throws -> Data {
    let raw = try lock.withLock { keys[choice]! }.signature(for: data).rawRepresentation
    return SSHWire.mpint(raw.prefix(32)) + SSHWire.mpint(raw.suffix(32))
  }

  public func replaceAgentKey() throws { lock.withLock { keys[.agent] = .init() } }
}
