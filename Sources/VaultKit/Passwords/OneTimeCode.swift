import CryptoKit
import Foundation

/// A time-based one-time code (TOTP, RFC 6238), built on HOTP (RFC 4226): the six or eight digits an
/// authenticator app shows, from a shared secret and the time.
///
/// A login keeps it as the `VaultSecrets` secret `otp.<id>`, as text (`url`, or a bare base32 key); `init?(_:)`
/// reads either.
public struct OneTimeCode: Sendable, Hashable {
  public enum Algorithm: String, Sendable, CaseIterable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
  }

  public var secret: Data
  /// 6 or 8 (at most 10).
  public var digits: Int
  /// Seconds each code lasts.
  public var period: Int
  public var algorithm: Algorithm
  public var issuer: String?
  public var account: String?

  public init(
    secret: Data, digits: Int = 6, period: Int = 30, algorithm: Algorithm = .sha1, issuer: String? = nil,
    account: String? = nil
  ) {
    self.secret = secret
    self.digits = min(max(digits, 1), 10)
    self.period = max(period, 1)
    self.algorithm = algorithm
    self.issuer = issuer
    self.account = account
  }

  /// Reads an `otpauth://totp/Issuer:account?secret=…&issuer=…&digits=…&period=…&algorithm=…` URL or a bare
  /// base32 key. Nil for anything else (an `otpauth://hotp` counter code included).
  public init?(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.lowercased().hasPrefix("otpauth:") {
      guard let components = URLComponents(string: text), components.host?.lowercased() == "totp" else { return nil }
      var query: [String: String] = [:]
      for item in components.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }
      guard let secretText = query["secret"], let secret = Base32.decode(secretText), !secret.isEmpty else {
        return nil
      }
      var label = components.path
      if label.hasPrefix("/") { label.removeFirst() }
      var issuer: String?
      var account: String? = label.isEmpty ? nil : label
      if let colon = label.firstIndex(of: ":") {
        issuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
        account = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      }
      if let given = query["issuer"], !given.isEmpty { issuer = given }
      var algorithm = Algorithm.sha1
      if let name = query["algorithm"] {
        guard let named = Algorithm(rawValue: name.uppercased()) else { return nil }
        algorithm = named
      }
      let digits = query["digits"].flatMap(Int.init) ?? 6
      let period = query["period"].flatMap(Int.init) ?? 30
      guard (6...10).contains(digits), period > 0 else { return nil }
      self.init(
        secret: secret, digits: digits, period: period, algorithm: algorithm, issuer: issuer?.nilIfEmpty,
        account: account?.nilIfEmpty)
    } else {
      guard let secret = Base32.decode(text), secret.count >= 10 else { return nil }
      self.init(secret: secret)
    }
  }

  /// The code for `date`.
  public func code(at date: Date = .now) -> String {
    Self.hotp(secret: secret, counter: counter(at: date), digits: digits, algorithm: algorithm)
  }

  /// The time step `date` falls in.
  public func counter(at date: Date) -> UInt64 {
    UInt64(max(0, date.timeIntervalSince1970) / Double(period))
  }

  /// Seconds until the code changes (1 through `period`).
  public func secondsRemaining(at date: Date = .now) -> Int {
    let seconds = Int(max(0, date.timeIntervalSince1970).rounded(.down))
    return period - seconds % period
  }

  /// The secret as base32, without padding.
  public var base32Secret: String { Base32.encode(secret, padding: false) }

  /// The `otpauth://totp/…` URL that holds every setting.
  public var url: String {
    var components = URLComponents()
    components.scheme = "otpauth"
    components.host = "totp"
    let label = [issuer, account].compactMap { $0?.nilIfEmpty }.joined(separator: ":")
    components.path = "/" + label
    var items = [URLQueryItem(name: "secret", value: base32Secret)]
    if let issuer = issuer?.nilIfEmpty { items.append(URLQueryItem(name: "issuer", value: issuer)) }
    if algorithm != .sha1 { items.append(URLQueryItem(name: "algorithm", value: algorithm.rawValue)) }
    if digits != 6 { items.append(URLQueryItem(name: "digits", value: String(digits))) }
    if period != 30 { items.append(URLQueryItem(name: "period", value: String(period))) }
    components.queryItems = items
    return components.string ?? ""
  }

  /// An HOTP value (RFC 4226): HMAC of the counter, dynamically truncated to `digits` decimal digits.
  public static func hotp(secret: Data, counter: UInt64, digits: Int = 6, algorithm: Algorithm = .sha1) -> String {
    var bigEndian = counter.bigEndian
    let message = Data(bytes: &bigEndian, count: 8)
    let key = SymmetricKey(data: secret)
    let mac: [UInt8] =
      switch algorithm {
      case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
      case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
      case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
      }
    let offset = Int(mac[mac.count - 1] & 0x0F)
    let binary =
      (UInt64(mac[offset] & 0x7F) << 24) | (UInt64(mac[offset + 1]) << 16) | (UInt64(mac[offset + 2]) << 8)
      | UInt64(mac[offset + 3])
    var modulus: UInt64 = 1
    for _ in 0..<digits { modulus *= 10 }
    let value = String(binary % modulus)
    return String(repeating: "0", count: max(0, digits - value.count)) + value
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
