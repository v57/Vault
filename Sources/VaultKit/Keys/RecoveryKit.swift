import Foundation

/// What the user keeps of a recovery key, shown once when it is made: the 24 words, the same secret as base32
/// groups, the text for its QR code, and the printable kit.
///
/// The QR text is the version tag and the 56 base32 characters, `V57R1:ABCDEF…`, all in QR's alphanumeric set so
/// the code stays small. `RecoverySecret(parsing:)` reads it, the words and the groups alike.
public struct RecoveryKit: Sendable, Equatable {
  /// The kit format's version tag, at the start of the QR text and on the printout.
  public static let versionTag = "V57R1"
  static let tagPrefix = "V57R"

  public let words: [String]
  /// 14 groups of four base32 characters.
  public let groups: [String]
  /// "3A9F-C27D", the same as `VaultRecoveryKey.check`: tells which kit is the current one.
  public let check: String
  public let created: Date

  public init(secret: RecoverySecret, created: Date = .now, wordList: RecoveryWordList = .english) {
    words = secret.words(in: wordList)
    groups = secret.groups
    check = secret.check
    self.created = created
  }

  /// `ABCD-EF23-…`
  public var groupedText: String { groups.joined(separator: "-") }

  /// The QR code's text: `V57R1:` and the 56 characters.
  public var qrText: String { Self.versionTag + ":" + groups.joined() }

  /// The kit as plain text, for printing or saving: the words numbered in four columns, the groups, the QR text
  /// and what the kit is for.
  public var printText: String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = .current
    let day = formatter.string(from: created)
    var lines = [
      "v57 Vault Recovery Kit",
      "Recovery key \(check), made \(day) (\(Self.versionTag))",
      "",
    ]
    let width = (words.map(\.count).max() ?? 8) + 2
    for row in 0..<6 {
      let cells = (0..<4).map { column -> String in
        let n = column * 6 + row
        let number = String(n + 1)
        return String(repeating: " ", count: 2 - number.count) + number + ". "
          + words[n].padding(toLength: width, withPad: " ", startingAt: 0)
      }
      lines.append(cells.joined().trimmingCharacters(in: .whitespaces))
    }
    lines += [
      "",
      "Or type: \(groupedText)",
      "QR code: \(qrText)",
      "",
      "This key brings back your vault keys, your identity and your encrypted folders' keys if iCloud Keychain",
      "loses them: choose “Recover with Key” in Vault and scan the QR code or type the words. Anyone who has it",
      "and gets into your iCloud or a remote can do the same, so keep it safe and offline. Vault keeps no copy.",
    ]
    return lines.joined(separator: "\n") + "\n"
  }
}
