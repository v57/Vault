import CryptoKit
import Foundation

/// The code two people compare to make sure each has the other's real keys (like Signal's safety numbers):
/// 60 digits in 12 groups of 5, the same on both phones whichever side computes it.
///
/// Each side's public keys are hashed with iterated SHA-512 (so finding a lookalike key costs real work), the
/// first 30 bytes give 30 digits (6 chunks of 5 bytes, each mod 100000), and the two halves are sorted so the
/// order of the people doesn't matter.
public enum SafetyCode {
  public static let iterations = 5200
  static let version: [UInt8] = [0, 1]

  /// 12 groups of 5 digits.
  public static func compute(_ a: PublicIdentity, _ b: PublicIdentity) -> [String] {
    let halves = [digits(for: a), digits(for: b)].sorted()
    let all = Array(halves.joined())
    return stride(from: 0, to: all.count, by: 5).map { String(all[$0..<$0 + 5]) }
  }

  /// The groups joined by spaces.
  public static func text(_ a: PublicIdentity, _ b: PublicIdentity) -> String {
    compute(a, b).joined(separator: " ")
  }

  /// Whether `text` (typed or scanned, spaces ignored) is the code for the two identities.
  public static func matches(_ text: String, _ a: PublicIdentity, _ b: PublicIdentity) -> Bool {
    text.filter(\.isNumber) == compute(a, b).joined()
  }

  /// 30 digits for one side.
  static func digits(for identity: PublicIdentity) -> String {
    let keys = identity.signingKey + identity.agreementKey
    var hash = Data(SHA512.hash(data: Data(version) + keys + Data("dev.v57.safety-code".utf8)))
    for _ in 0..<iterations {
      hash = Data(SHA512.hash(data: hash + keys))
    }
    let bytes = [UInt8](hash.prefix(30))
    return stride(from: 0, to: 30, by: 5).map { start in
      let value = bytes[start..<start + 5].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 100_000
      let text = String(value)
      return String(repeating: "0", count: 5 - text.count) + text
    }.joined()
  }
}
