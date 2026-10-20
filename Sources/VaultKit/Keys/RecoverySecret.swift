import CryptoKit
import Foundation

/// The recovery key's secret: 256 random bits that only the user keeps, on the printed kit. Vault never stores it.
///
/// It has two text forms, both with a checksum so a mistyped kit is caught before anything is tried with it:
/// - 24 words (`words(in:)`): BIP-39's encoding, 256 bits and the first 8 bits of their SHA-256, 11 bits a word.
/// - 56 base32 characters in 14 groups of four (`groups`): the 32 bytes and the first 3 bytes of the same
///   SHA-256, for typing where words are awkward and for the QR code.
///
/// `init(parsing:)` reads either, ignoring case, spaces, dashes and line numbers. It accepts a word typed as its
/// first four letters or more, and 0, 1 and 8 for the base32 letters O, I and B (base32 has no such digits);
/// anything else it reports (`RecoveryKeyError`), with suggestions for unknown words, and never guesses. The
/// checksum then catches a wrong word or character: always in base32, all but 1 in 256 times in words, and a
/// secret that slips through matches no recovery key (`VaultRecovery.check` and `recover` say so).
public struct RecoverySecret: Sendable, Equatable {
  public static let byteCount = 32
  public static let wordCount = 24
  public static let groupCount = 14

  public let data: Data

  public init(data: Data) throws {
    guard data.count == Self.byteCount else { throw RecoveryKeyError.damaged }
    self.data = data
  }

  /// A new random secret.
  public static func random() -> RecoverySecret {
    try! RecoverySecret(data: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
  }

  private var checksum: Data { Data(SHA256.hash(data: data)) }

  // MARK: Words

  /// The secret as 24 words of `list`.
  public func words(in list: RecoveryWordList = .english) -> [String] {
    let bits = BitReader(data + checksum.prefix(1))
    return (0..<Self.wordCount).map { list.words[bits.value(at: $0 * 11, width: 11)] }
  }

  /// The secret the 24 words stand for.
  public init(words typed: [String], in list: RecoveryWordList = .english) throws {
    var indices: [Int] = []
    var unknown: [RecoveryKeyError.UnknownWord] = []
    for (position, word) in typed.enumerated() {
      let word = word.lowercased()
      if let index = list.index(of: word) {
        indices.append(index)
      } else {
        unknown.append(.init(position: position + 1, typed: word, suggestions: list.suggestions(for: word)))
      }
    }
    if !unknown.isEmpty { throw RecoveryKeyError.unknownWords(unknown) }
    guard indices.count == Self.wordCount else { throw RecoveryKeyError.wrongWordCount(indices.count) }
    var bytes = [UInt8](repeating: 0, count: Self.byteCount + 1)
    for (n, index) in indices.enumerated() {
      for bit in 0..<11 where index & (1 << (10 - bit)) != 0 {
        let position = n * 11 + bit
        bytes[position / 8] |= 1 << (7 - position % 8)
      }
    }
    let secret = try RecoverySecret(data: Data(bytes.prefix(Self.byteCount)))
    guard secret.checksum.first == bytes[Self.byteCount] else { throw RecoveryKeyError.checksumMismatch }
    self = secret
  }

  // MARK: Base32

  /// The secret as 14 groups of four base32 characters ("ABCD", "EF23", …).
  public var groups: [String] {
    let text = Array(Base32.encode(data + checksum.prefix(3), padding: false))
    return stride(from: 0, to: text.count, by: 4).map { String(text[$0..<$0 + 4]) }
  }

  /// The groups joined with dashes: `ABCD-EF23-…`.
  public var groupedText: String { groups.joined(separator: "-") }

  /// The secret the 56 base32 characters stand for (any grouping and case).
  public init(base32 text: String) throws {
    var characters: [Character] = []
    for character in text.uppercased() {
      if character.isWhitespace || "-_.,".contains(character) { continue }
      let mapped: Character =
        switch character {
        case "0": "O"
        case "1": "I"
        case "8": "B"
        default: character
        }
      guard mapped.isASCII, mapped.isLetter || ("2"..."7").contains(mapped) else {
        throw RecoveryKeyError.invalidCharacter(String(character))
      }
      characters.append(mapped)
    }
    guard characters.count == 56 else { throw RecoveryKeyError.wrongLength(characters.count) }
    guard let bytes = Base32.decode(String(characters)), bytes.count == Self.byteCount + 3 else {
      throw RecoveryKeyError.damaged
    }
    let secret = try RecoverySecret(data: bytes.prefix(Self.byteCount))
    guard secret.checksum.prefix(3) == bytes.suffix(3) else { throw RecoveryKeyError.checksumMismatch }
    self = secret
  }

  // MARK: Any form

  /// Reads what the user typed or scanned: 24 words, the base32 groups, or the kit's QR text (`RecoveryKit`).
  public init(parsing text: String, wordList: RecoveryWordList = .english) throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let colon = trimmed.firstIndex(of: ":"), trimmed.uppercased().hasPrefix(RecoveryKit.tagPrefix) {
      guard trimmed[..<colon].uppercased() == RecoveryKit.versionTag else {
        throw RecoveryKeyError.unsupportedVersion(String(trimmed[..<colon]))
      }
      try self.init(base32: String(trimmed[trimmed.index(after: colon)...]))
      return
    }
    let tokens = trimmed.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let letterTokens = tokens.filter { $0.allSatisfy(\.isLetter) }
    let known = letterTokens.filter { wordList.index(of: $0) != nil }.count
    let looksLikeWords =
      known * 2 >= Self.wordCount || (letterTokens.count >= 18 && letterTokens.contains { $0.count != 4 })
    if looksLikeWords {
      // Numbers are the kit's line numbers ("1. abandon").
      try self.init(words: tokens.filter { !$0.allSatisfy(\.isNumber) }, in: wordList)
    } else if tokens.isEmpty {
      throw RecoveryKeyError.unrecognized
    } else {
      try self.init(base32: trimmed)
    }
  }

  // MARK: Keys

  /// The X25519 key pair derived from the secret (HKDF-SHA256). Every device wraps keys to its public half; only
  /// the secret opens them.
  var agreementKey: Curve25519.KeyAgreement.PrivateKey {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: data), salt: Data("dev.v57.vault.recovery".utf8),
      info: Data("x25519".utf8), outputByteCount: 32)
    return try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: derived.withUnsafeBytes { Data($0) })
  }

  /// The public key devices keep (`VaultRecoveryKey`).
  public var publicKey: Data { agreementKey.publicKey.rawRepresentation }

  /// "3A9F-C27D": a short value that tells recovery keys apart, printed on the kit and shown in Settings.
  public var check: String { Self.check(for: publicKey) }

  public static func check(for publicKey: Data) -> String {
    let hash = SHA256.hash(data: Data("dev.v57.vault.recovery.check".utf8) + publicKey)
    let hex = hash.prefix(4).map { String(format: "%02X", $0) }.joined()
    return String(hex.prefix(4)) + "-" + String(hex.suffix(4))
  }
}

/// Reads big-endian bit fields.
private struct BitReader {
  let bytes: [UInt8]

  init(_ data: Data) { bytes = [UInt8](data) }

  func value(at offset: Int, width: Int) -> Int {
    var value = 0
    for bit in offset..<offset + width {
      value = value << 1 | Int(bytes[bit / 8] >> (7 - bit % 8) & 1)
    }
    return value
  }
}

public enum RecoveryKeyError: LocalizedError, Equatable {
  /// A typed word that isn't in the list, with words close to it.
  public struct UnknownWord: Sendable, Equatable {
    /// 1-based, as the kit numbers them.
    public let position: Int
    public let typed: String
    public let suggestions: [String]
  }

  case unknownWords([UnknownWord])
  case wrongWordCount(Int)
  case wrongLength(Int)
  case invalidCharacter(String)
  case checksumMismatch
  case unrecognized
  case unsupportedVersion(String)
  /// There is no recovery key (`create` makes one).
  case off
  /// There is a recovery key already (`replace` makes a new one).
  case alreadyOn
  /// Well-formed, but not this vault's recovery key, or nothing was wrapped to it.
  case doesNotMatch
  case damaged

  public var errorDescription: String? {
    if case .unknownWords(let words) = self, let first = words.first {
      let hint = first.suggestions.isEmpty ? "" : " Did you mean “\(first.suggestions[0])”?"
      return words.count == 1
        ? "Word \(first.position), “\(first.typed)”, isn’t a recovery word.\(hint)"
        : "\(words.count) words aren’t recovery words, starting with word \(first.position), “\(first.typed)”.\(hint)"
    }
    return switch self {
    case .unknownWords: "These aren’t recovery words."
    case .wrongWordCount(let count): "A recovery key has 24 words; this has \(count)."
    case .wrongLength(let count): "A recovery key has 56 characters; this has \(count)."
    case .invalidCharacter(let character): "“\(character)” can’t be in a recovery key."
    case .checksumMismatch: "A word or character is wrong: the recovery key’s checksum doesn’t match."
    case .unrecognized: "This doesn’t look like a recovery key."
    case .unsupportedVersion(let tag): "This kit (\(tag)) is from a newer version of Vault."
    case .off: "There’s no recovery key."
    case .alreadyOn: "There’s a recovery key already. Replace it to make a new one."
    case .doesNotMatch: "This recovery key doesn’t match this vault’s."
    case .damaged: "The recovery data is damaged."
    }
  }
}
