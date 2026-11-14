import Foundation

/// The ssh-agent protocol (draft-miller-ssh-agent): what `ssh`, `ssh-add` and `ssh-keygen -Y sign` send to the socket
/// in `SSH_AUTH_SOCK` or `IdentityAgent`, and what Vault's agent answers. Each message is a uint32 length and a body
/// whose first byte is its type. Only what an agent holding Secure Enclave keys needs: list keys, sign, and the
/// `session-bind@openssh.com` extension (answered, so ssh doesn't warn); adding, removing and locking keys fail, as
/// the keys can't leave the chip.
public enum SSHAgentProtocol {
  public static let failure: UInt8 = 5
  public static let success: UInt8 = 6
  public static let requestIdentities: UInt8 = 11
  public static let identitiesAnswer: UInt8 = 12
  public static let signRequest: UInt8 = 13
  public static let signResponse: UInt8 = 14
  public static let extensionRequest: UInt8 = 27

  /// The largest message read: OpenSSH's own agent caps them at 256 KB.
  public static let maximumLength = 256 * 1024

  public enum Request: Equatable, Sendable {
    case identities
    case sign(keyBlob: Data, data: Data, flags: UInt32)
    /// ssh telling the agent which server it's talking to: the server's host key, the session id it signed.
    case sessionBind(hostKey: Data, sessionID: Data, isForwarding: Bool)
    /// Another extension, by name.
    case otherExtension(String)
    /// A type this agent doesn't do (add, remove, lock…).
    case other(UInt8)
  }

  /// The request in a message body (the length already taken off); nil when it's malformed.
  public static func request(_ body: Data) -> Request? {
    var reader = SSHWireReader(body)
    guard let type = reader.byte() else { return nil }
    switch type {
    case requestIdentities:
      return .identities
    case signRequest:
      guard let key = reader.string(), let data = reader.string(), let flags = reader.uint32() else { return nil }
      return .sign(keyBlob: key, data: data, flags: flags)
    case extensionRequest:
      guard let name = reader.text() else { return nil }
      guard name == "session-bind@openssh.com" else { return .otherExtension(name) }
      guard let hostKey = reader.string(), let session = reader.string(), reader.string() != nil,
        let forwarding = reader.byte()
      else { return nil }
      return .sessionBind(hostKey: hostKey, sessionID: session, isForwarding: forwarding != 0)
    default:
      return .other(type)
    }
  }

  /// SSH_AGENT_IDENTITIES_ANSWER for these keys (their wire blobs and comments).
  public static func identities(_ keys: [(blob: Data, comment: String)]) -> Data {
    var body = Data([identitiesAnswer])
    body += uint32(UInt32(keys.count))
    for key in keys { body += SSHWire.string(key.blob) + SSHWire.string(key.comment) }
    return body
  }

  /// SSH_AGENT_SIGN_RESPONSE carrying an `ecdsa-sha2-nistp256` signature (`rs`: mpint(r) + mpint(s)).
  public static func ecdsaSignature(_ rs: Data) -> Data {
    Data([signResponse]) + SSHWire.string(SSHWire.string("ecdsa-sha2-nistp256") + SSHWire.string(rs))
  }

  public static var failureMessage: Data { Data([failure]) }
  public static var successMessage: Data { Data([success]) }

  /// A body with its length in front, as it goes on the socket.
  public static func framed(_ body: Data) -> Data { uint32(UInt32(body.count)) + body }

  static func uint32(_ value: UInt32) -> Data {
    var big = value.bigEndian
    return Data(bytes: &big, count: 4)
  }

  /// What a sign request's data is: a login (`ssh`), a signature over a file or commit (`ssh-keygen -Y sign`, as git
  /// does with `gpg.format ssh`), or something else.
  public enum Payload: Equatable, Sendable {
    /// SSH_MSG_USERAUTH_REQUEST (RFC 4252 §7): the user it signs in as.
    case login(user: String)
    /// SSHSIG (OpenSSH's PROTOCOL.sshsig): the namespace, "git" for a commit or tag.
    case signature(namespace: String)
    case unknown
  }

  public static func payload(_ data: Data) -> Payload {
    if data.starts(with: Data("SSHSIG".utf8)) {
      var reader = SSHWireReader(data.dropFirst(6))
      return reader.text().map { .signature(namespace: $0) } ?? .unknown
    }
    var reader = SSHWireReader(data)
    guard reader.string() != nil, reader.byte() == 50, let user = reader.text(), reader.text() == "ssh-connection",
      reader.text() == "publickey"
    else { return .unknown }
    return .login(user: user)
  }
}

/// Reads SSH wire encodings (RFC 4251) from the front of some bytes.
public struct SSHWireReader {
  private var bytes: Data

  public init(_ data: Data) { bytes = Data(data) }

  public var isAtEnd: Bool { bytes.isEmpty }

  public mutating func byte() -> UInt8? {
    guard let first = bytes.first else { return nil }
    bytes = bytes.dropFirst()
    return first
  }

  public mutating func uint32() -> UInt32? {
    guard bytes.count >= 4 else { return nil }
    let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    bytes = bytes.dropFirst(4)
    return value
  }

  public mutating func string() -> Data? {
    guard let length = uint32(), Int(length) <= bytes.count else { return nil }
    let value = Data(bytes.prefix(Int(length)))
    bytes = bytes.dropFirst(Int(length))
    return value
  }

  public mutating func text() -> String? { string().flatMap { String(data: $0, encoding: .utf8) } }
}
