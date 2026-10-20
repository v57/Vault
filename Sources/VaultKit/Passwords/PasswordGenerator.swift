import Foundation

/// Makes passwords that are easy to read and type: groups of letters and digits joined by dashes
/// (`vT7q-Lm2x-9KpR-wd4Z`), from an alphabet without look-alikes (no 0/O/o, 1/l/I/i).
public struct PasswordGenerator: Sendable, Hashable {
  /// Letters and digits with the look-alikes left out: 23 lowercase, 24 uppercase, 8 digits.
  public static let readableAlphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

  public var groups: Int
  public var groupLength: Int
  public var separator: String
  public var alphabet: [Character]

  public init(
    groups: Int = 4, groupLength: Int = 4, separator: String = "-",
    alphabet: [Character] = PasswordGenerator.readableAlphabet
  ) {
    self.groups = max(groups, 1)
    self.groupLength = max(groupLength, 1)
    self.separator = separator
    self.alphabet = alphabet.isEmpty ? Self.readableAlphabet : alphabet
  }

  /// Random characters in total, separators not counted.
  public var randomCharacters: Int { groups * groupLength }

  /// The password's length with separators.
  public var length: Int { randomCharacters + (groups - 1) * separator.count }

  /// Bits of entropy: each character drawn uniformly from the alphabet. (Requiring a lowercase letter, an
  /// uppercase letter and a digit costs well under a bit for 16 characters.)
  public var entropy: Double { Double(randomCharacters) * log2(Double(Set(alphabet).count)) }

  public var strength: PasswordStrength { PasswordStrength(bits: entropy) }

  /// A new password. With the readable alphabet and at least three characters it has a lowercase letter,
  /// an uppercase letter and a digit, as many sites require.
  public func generate() -> String {
    var generator = SystemRandomNumberGenerator()
    return generate(using: &generator)
  }

  public func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
    let needsClasses = randomCharacters >= 3 && alphabet.contains(where: \.isLowercase)
      && alphabet.contains(where: \.isUppercase) && alphabet.contains(where: \.isNumber)
    while true {
      let characters = (0..<randomCharacters).map { _ in alphabet.randomElement(using: &generator)! }
      if needsClasses
        && !(characters.contains(where: \.isLowercase) && characters.contains(where: \.isUppercase)
          && characters.contains(where: \.isNumber))
      {
        continue
      }
      return stride(from: 0, to: characters.count, by: groupLength)
        .map { String(characters[$0..<min($0 + groupLength, characters.count)]) }
        .joined(separator: separator)
    }
  }
}

/// How hard a password is to guess, from its entropy.
public enum PasswordStrength: Int, Sendable, Comparable, CaseIterable {
  /// Under 40 bits, or a common password.
  case weak
  /// 40 to 60 bits.
  case fair
  /// 60 to 80 bits.
  case good
  /// 80 bits and more.
  case strong

  public init(bits: Double) {
    switch bits {
    case ..<40: self = .weak
    case ..<60: self = .fair
    case ..<80: self = .good
    default: self = .strong
    }
  }

  /// The strength of a password someone typed, from `estimatedBits(_:)`.
  public init(password: String) {
    self.init(bits: Self.estimatedBits(password))
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public var name: String {
    switch self {
    case .weak: "Weak"
    case .fair: "Fair"
    case .good: "Good"
    case .strong: "Strong"
    }
  }

  /// "Strong · 19 characters".
  public static func description(of password: String) -> String {
    let count = password.count
    return "\(PasswordStrength(password: password).name) · \(count) character\(count == 1 ? "" : "s")"
  }

  /// A rough entropy estimate: length times the bits of the character classes it uses (lowercase 26,
  /// uppercase 26, digits 10, symbols 33, anything else 100), with repeats and runs counted once, and
  /// 0 for a common password.
  public static func estimatedBits(_ password: String) -> Double {
    guard !password.isEmpty else { return 0 }
    if commonPasswords.contains(password.lowercased()) { return 0 }
    var pool = 0
    let scalars = password.unicodeScalars
    if scalars.contains(where: { ("a"..."z").contains($0) }) { pool += 26 }
    if scalars.contains(where: { ("A"..."Z").contains($0) }) { pool += 26 }
    if scalars.contains(where: { ("0"..."9").contains($0) }) { pool += 10 }
    if scalars.contains(where: {
      $0.isASCII && !("a"..."z").contains($0) && !("A"..."Z").contains($0) && !("0"..."9").contains($0)
    }) {
      pool += 33
    }
    if scalars.contains(where: { !$0.isASCII }) { pool += 100 }
    pool = max(pool, 10)
    // Characters that repeat the one before or continue a run (aaaa, 1234, abcd) add almost nothing.
    var effective = 0.0
    var previous: Unicode.Scalar?
    var step: Int?
    for scalar in scalars {
      if let previous {
        let delta = Int(scalar.value) - Int(previous.value)
        if delta == 0 || (abs(delta) == 1 && step == delta) {
          effective += 0.25
        } else {
          effective += 1
        }
        step = delta
      } else {
        effective += 1
      }
      previous = scalar
    }
    return effective * log2(Double(pool))
  }

  static let commonPasswords: Set<String> = [
    "password", "password1", "password123", "123456", "12345678", "123456789", "1234567890", "qwerty", "qwerty123",
    "letmein", "welcome", "admin", "iloveyou", "monkey", "dragon", "football", "baseball", "abc123", "111111",
    "000000", "sunshine", "princess", "trustno1", "passw0rd", "master", "login", "starwars", "whatever",
  ]
}
