import CryptoKit
import Foundation
import Testing

@testable import VaultKit

struct RecoveryKitTests {
  /// A fixed secret, so the typo tests check the same cases every run.
  let secret = try! RecoverySecret(data: Data((0..<32).map { UInt8(($0 * 37 + 11) % 256) }))

  @Test func englishListIsBIP39() {
    let list = RecoveryWordList.english
    #expect(list.words.count == 2048)
    let file = Data((list.words.joined(separator: "\n") + "\n").utf8)
    #expect(
      SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
        == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
    #expect(RecoveryWordList(words: Array(list.words.dropLast())) == nil)
    #expect(RecoveryWordList(words: list.words.map { $0.uppercased() }) == nil)
  }

  @Test func bip39Vectors() throws {
    func words(_ byte: UInt8) throws -> String {
      try RecoverySecret(data: Data(repeating: byte, count: 32)).words().joined(separator: " ")
    }
    #expect(try words(0x00) == Array(repeating: "abandon", count: 23).joined(separator: " ") + " art")
    #expect(try words(0xFF) == Array(repeating: "zoo", count: 23).joined(separator: " ") + " vote")
    #expect(
      try words(0x7F)
        == "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
    )
    #expect(
      try words(0x80)
        == "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"
    )
  }

  @Test func wordsRoundTrip() throws {
    for _ in 0..<50 {
      let secret = RecoverySecret.random()
      let words = secret.words()
      #expect(words.count == 24)
      #expect(try RecoverySecret(words: words) == secret)
      #expect(try RecoverySecret(parsing: words.joined(separator: " ")) == secret)
    }
  }

  @Test func base32RoundTrip() throws {
    for _ in 0..<50 {
      let secret = RecoverySecret.random()
      #expect(secret.groups.count == 14)
      #expect(secret.groups.allSatisfy { $0.count == 4 })
      #expect(try RecoverySecret(base32: secret.groupedText) == secret)
      #expect(try RecoverySecret(parsing: secret.groupedText.lowercased()) == secret)
      #expect(try RecoverySecret(parsing: secret.groups.joined(separator: "  ")) == secret)
    }
  }

  @Test func parsingTolerance() throws {
    let words = secret.words()
    // Case, line numbers, commas, dashes and line breaks, as people copy a kit.
    let numbered = words.enumerated().map { "\($0 + 1). \($1.uppercased())" }.joined(separator: "\n")
    #expect(try RecoverySecret(parsing: numbered) == secret)
    #expect(try RecoverySecret(parsing: words.joined(separator: ", ")) == secret)
    #expect(try RecoverySecret(parsing: words.joined(separator: "-")) == secret)
    // The first four letters (or more) of each word.
    #expect(try RecoverySecret(parsing: words.map { String($0.prefix(4)) }.joined(separator: " ")) == secret)
    #expect(try RecoverySecret(parsing: words.map { String($0.prefix(5)) }.joined(separator: " ")) == secret)
    // Base32 without the digits it doesn't have: 0, 1 and 8 read as O, I and B.
    let confusable = secret.groupedText.replacingOccurrences(of: "O", with: "0")
      .replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "B", with: "8")
    #expect(try RecoverySecret(parsing: confusable) == secret)
  }

  @Test func unknownWordsAreReportedNotCorrected() throws {
    var words = secret.words()
    let original = words[4]
    words[4] = String(original.dropLast()) + (original.last == "x" ? "y" : "x")  // one letter changed
    words[9] = "qwertyuiop"
    do {
      _ = try RecoverySecret(parsing: words.joined(separator: " "))
      Issue.record("A mistyped word was accepted")
    } catch RecoveryKeyError.unknownWords(let unknown) {
      #expect(unknown.map(\.position) == [5, 10])
      #expect(unknown[0].typed == words[4])
      #expect(unknown[0].suggestions.contains(original))
      #expect(unknown[1].suggestions.isEmpty)
    }
    // Too few words.
    #expect(throws: RecoveryKeyError.wrongWordCount(23)) {
      try RecoverySecret(parsing: self.secret.words().dropLast().joined(separator: " "))
    }
  }

  @Test func checksumCatchesBase32Typos() throws {
    let text = Array(secret.groups.joined())
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var tried = 0
    for position in text.indices {
      for replacement in alphabet where replacement != text[position] {
        var typo = text
        typo[position] = replacement
        tried += 1
        #expect(throws: RecoveryKeyError.self) { try RecoverySecret(base32: String(typo)) }
        // A typo that reads as another secret would be a silent correction.
        #expect((try? RecoverySecret(base32: String(typo))) == nil)
      }
    }
    #expect(tried == 56 * 31)
    #expect(throws: RecoveryKeyError.wrongLength(55)) { try RecoverySecret(base32: String(text.dropLast())) }
    #expect(throws: RecoveryKeyError.invalidCharacter("9")) {
      try RecoverySecret(base32: "9" + String(text.dropFirst()))
    }
  }

  @Test func checksumCatchesWordTypos() throws {
    let words = secret.words()
    let list = RecoveryWordList.english
    var caught = 0
    var tried = 0
    for position in words.indices {
      for step in 1...40 {
        var typo = words
        typo[position] = list.words[(list.index(of: words[position])! + step * 47) % 2048]
        tried += 1
        if (try? RecoverySecret(words: typo)) == nil { caught += 1 }
      }
    }
    // An 8-bit checksum lets about 1 in 256 through; those match no recovery key (`VaultRecovery.check`).
    #expect(Double(caught) / Double(tried) > 0.98)
    // Two words swapped.
    var swapped = words
    swapped.swapAt(0, 1)
    if swapped != words { #expect((try? RecoverySecret(words: swapped)) == nil) }
  }

  @Test func kitText() throws {
    let kit = RecoveryKit(secret: secret, created: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(kit.qrText.hasPrefix("V57R1:"))
    #expect(kit.qrText.count == 6 + 56)
    // QR's alphanumeric set: digits, capitals, and a few symbols.
    #expect(kit.qrText.allSatisfy { $0.isNumber || ($0.isUppercase && $0.isASCII) || $0 == ":" })
    #expect(try RecoverySecret(parsing: kit.qrText) == secret)
    #expect(try RecoverySecret(parsing: kit.printText.components(separatedBy: "Or type: ")[1].prefix(69).description) == secret)
    #expect(kit.check == secret.check)
    #expect(kit.check.wholeMatch(of: /[0-9A-F]{4}-[0-9A-F]{4}/) != nil)
    #expect(kit.printText.contains(kit.check))
    for word in kit.words { #expect(kit.printText.contains(word)) }
    #expect(throws: RecoveryKeyError.unsupportedVersion("V57R2")) {
      try RecoverySecret(parsing: "V57R2:" + self.secret.groups.joined())
    }
    #expect(throws: RecoveryKeyError.unrecognized) { try RecoverySecret(parsing: "  ") }
  }

  @Test func derivedKeyIsStable() throws {
    let copy = try RecoverySecret(data: secret.data)
    #expect(copy.publicKey == secret.publicKey)
    #expect(secret.publicKey.count == 32)
    #expect(RecoverySecret.random().publicKey != secret.publicKey)
  }
}
