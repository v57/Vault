import Foundation
import Testing

@testable import VaultKit

struct Base32Tests {
  // RFC 4648, section 10.
  let vectors: [(String, String)] = [
    ("", ""), ("f", "MY======"), ("fo", "MZXQ===="), ("foo", "MZXW6==="), ("foob", "MZXW6YQ="),
    ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI======"),
  ]

  @Test func rfcVectors() {
    for (plain, encoded) in vectors {
      #expect(Base32.encode(Data(plain.utf8)) == encoded)
      #expect(Base32.decode(encoded) == Data(plain.utf8))
    }
  }

  @Test func ignoresCaseSpacesAndPadding() {
    #expect(Base32.decode("mzxw 6ytb-oi") == Data("foobar".utf8))
    #expect(Base32.encode(Data("foobar".utf8), padding: false) == "MZXW6YTBOI")
  }

  @Test func rejectsOtherCharacters() {
    #expect(Base32.decode("MZXW1") == nil)
    #expect(Base32.decode("MZ!W") == nil)
  }
}

struct OneTimeCodeTests {
  static let sha1Secret = Data("12345678901234567890".utf8)
  static let sha256Secret = Data("12345678901234567890123456789012".utf8)
  static let sha512Secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

  // RFC 6238, appendix B: time, SHA1, SHA256, SHA512.
  static let totpVectors: [(TimeInterval, String, String, String)] = [
    (59, "94287082", "46119246", "90693936"),
    (1_111_111_109, "07081804", "68084774", "25091201"),
    (1_111_111_111, "14050471", "67062674", "99943326"),
    (1_234_567_890, "89005924", "91819424", "93441116"),
    (2_000_000_000, "69279037", "90698825", "38618901"),
    (20_000_000_000, "65353130", "77737706", "47863826"),
  ]

  @Test func rfc6238Vectors() {
    let sha1 = OneTimeCode(secret: Self.sha1Secret, digits: 8, algorithm: .sha1)
    let sha256 = OneTimeCode(secret: Self.sha256Secret, digits: 8, algorithm: .sha256)
    let sha512 = OneTimeCode(secret: Self.sha512Secret, digits: 8, algorithm: .sha512)
    for (time, one, two, five) in Self.totpVectors {
      let date = Date(timeIntervalSince1970: time)
      #expect(sha1.code(at: date) == one)
      #expect(sha256.code(at: date) == two)
      #expect(sha512.code(at: date) == five)
    }
  }

  @Test func rfc4226Vectors() {
    let expected = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
    for (counter, code) in expected.enumerated() {
      #expect(OneTimeCode.hotp(secret: Self.sha1Secret, counter: UInt64(counter)) == code)
    }
  }

  @Test func secondsRemaining() {
    let code = OneTimeCode(secret: Self.sha1Secret)
    #expect(code.secondsRemaining(at: Date(timeIntervalSince1970: 60)) == 30)
    #expect(code.secondsRemaining(at: Date(timeIntervalSince1970: 61.5)) == 29)
    #expect(code.secondsRemaining(at: Date(timeIntervalSince1970: 89)) == 1)
    #expect(code.code(at: Date(timeIntervalSince1970: 60)) == code.code(at: Date(timeIntervalSince1970: 89)))
  }

  @Test func parsesOtpauthURLs() throws {
    let code = try #require(
      OneTimeCode(
        "otpauth://totp/Example%20Co:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&digits=8&period=60&algorithm=sha256"
      ))
    #expect(code.secret == Base32.decode("JBSWY3DPEHPK3PXP"))
    #expect(code.issuer == "Example")
    #expect(code.account == "alice@example.com")
    #expect(code.digits == 8)
    #expect(code.period == 60)
    #expect(code.algorithm == .sha256)
    #expect(OneTimeCode(code.url) == code)
  }

  @Test func labelIssuerWithoutParameter() throws {
    let code = try #require(OneTimeCode("otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP"))
    #expect(code.issuer == "GitHub")
    #expect(code.account == "octocat")
    #expect(code.digits == 6 && code.period == 30 && code.algorithm == .sha1)
  }

  @Test func parsesABareKey() throws {
    let code = try #require(OneTimeCode("jbsw y3dp ehpk 3pxp"))
    #expect(code.secret == Base32.decode("JBSWY3DPEHPK3PXP"))
    #expect(code.issuer == nil)
  }

  @Test func rejectsOtherText() {
    #expect(OneTimeCode("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1") == nil)
    #expect(OneTimeCode("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=md5") == nil)
    #expect(OneTimeCode("otpauth://totp/x") == nil)
    #expect(OneTimeCode("hello world") == nil)
    #expect(OneTimeCode("ABC") == nil)
  }
}
