import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3 requests (`Authorization` header, payload in a single chunk): what AWS S3,
/// Cloudflare R2 (region "auto"), Backblaze B2 and MinIO all check.
///
/// The steps are public so the tests can compare each one with AWS's published examples.
public struct AWSSignatureV4: Sendable {
  public var accessKeyID: String
  public var secretAccessKey: String
  public var region: String
  public var service: String
  /// For temporary credentials (STS); sent and signed as `x-amz-security-token`.
  public var sessionToken: String?

  public static let algorithm = "AWS4-HMAC-SHA256"
  /// SHA-256 of an empty body.
  public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  public init(
    accessKeyID: String, secretAccessKey: String, region: String, service: String = "s3", sessionToken: String? = nil
  ) {
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.region = region
    self.service = service
    self.sessionToken = sessionToken
  }

  /// The headers to add to a request: `x-amz-date`, `x-amz-content-sha256`, the session token if any, and
  /// `Authorization`. `headers` are the ones the request sends besides those, `host` included; all of them are
  /// signed.
  ///
  /// `path` is the decoded path ("/bucket/my file.txt"); send it as `encodePath(path)`, which is what's signed.
  /// `query` items are decoded too.
  public func sign(
    method: String, path: String, query: [(String, String)] = [], headers: [String: String], payloadHash: String,
    date: Date
  ) -> [String: String] {
    var signed = headers
    signed["x-amz-date"] = Self.timestamp(date)
    signed["x-amz-content-sha256"] = payloadHash
    if let sessionToken { signed["x-amz-security-token"] = sessionToken }
    let request = canonicalRequest(method: method, path: path, query: query, headers: signed, payloadHash: payloadHash)
    let toSign = stringToSign(canonicalRequest: request, date: date)
    let names = Self.canonicalHeaders(signed).map(\.name).joined(separator: ";")
    var added = signed.filter { headers[$0.key] == nil }
    added["Authorization"] =
      "\(Self.algorithm) Credential=\(accessKeyID)/\(scope(date)),SignedHeaders=\(names),Signature=\(signature(stringToSign: toSign, date: date))"
    return added
  }

  // MARK: The steps

  public func canonicalRequest(
    method: String, path: String, query: [(String, String)], headers: [String: String], payloadHash: String
  ) -> String {
    let canonical = Self.canonicalHeaders(headers)
    return [
      method.uppercased(),
      Self.encodePath(path),
      Self.canonicalQuery(query),
      canonical.map { "\($0.name):\($0.value)\n" }.joined(),
      canonical.map(\.name).joined(separator: ";"),
      payloadHash,
    ].joined(separator: "\n")
  }

  public func stringToSign(canonicalRequest: String, date: Date) -> String {
    [Self.algorithm, Self.timestamp(date), scope(date), Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))]
      .joined(separator: "\n")
  }

  public func signature(stringToSign: String, date: Date) -> String {
    var key = SymmetricKey(data: Data(("AWS4" + secretAccessKey).utf8))
    for part in [Self.day(date), region, service, "aws4_request"] {
      key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
    }
    return Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
  }

  public func scope(_ date: Date) -> String {
    "\(Self.day(date))/\(region)/\(service)/aws4_request"
  }

  // MARK: Encoding

  /// Each segment percent-encoded except `A-Z a-z 0-9 - _ . ~`; `/` stays. S3 encodes once (no double encoding).
  public static func encodePath(_ path: String) -> String {
    let encoded = path.split(separator: "/", omittingEmptySubsequences: false).map { uriEncode(String($0)) }
      .joined(separator: "/")
    return encoded.hasPrefix("/") ? encoded : "/" + encoded
  }

  /// Sorted by name, then value; names and values encoded like path segments (`/` too).
  public static func canonicalQuery(_ query: [(String, String)]) -> String {
    let encoded: [(name: String, value: String)] = query.map { (uriEncode($0.0), uriEncode($0.1)) }
    let sorted = encoded.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
    return sorted.map { item in item.name + "=" + item.value }.joined(separator: "&")
  }

  public static func uriEncode(_ string: String) -> String {
    var result = ""
    for byte in string.utf8 {
      if unreserved.contains(byte) {
        result.unicodeScalars.append(Unicode.Scalar(byte))
      } else {
        result += String(format: "%%%02X", byte)
      }
    }
    return result
  }

  private static let unreserved: Set<UInt8> = Set(
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8))

  static func canonicalHeaders(_ headers: [String: String]) -> [(name: String, value: String)] {
    headers.map { name, value in
      // Trimmed, with runs of spaces inside folded to one.
      let folded = value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
      return (name.lowercased(), folded.trimmingCharacters(in: .whitespaces))
    }
    .sorted { $0.name < $1.name }
  }

  // MARK: Dates and hex

  /// `20130524T000000Z`.
  public static func timestamp(_ date: Date) -> String {
    let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
  }

  static func day(_ date: Date) -> String { String(timestamp(date).prefix(8)) }

  private static var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  public static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Hex SHA-256, for `x-amz-content-sha256`.
  public static func payloadHash(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }
}
