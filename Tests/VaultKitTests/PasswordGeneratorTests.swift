import Foundation
import Testing

@testable import VaultKit

struct PasswordGeneratorTests {
  @Test func defaultShape() {
    let generator = PasswordGenerator()
    let alphabet = Set(PasswordGenerator.readableAlphabet)
    for _ in 0..<200 {
      let password = generator.generate()
      #expect(password.count == 19)
      #expect(generator.length == 19)
      let groups = password.split(separator: "-", omittingEmptySubsequences: false)
      #expect(groups.count == 4)
      #expect(groups.allSatisfy { $0.count == 4 })
      #expect(groups.joined().allSatisfy(alphabet.contains))
      #expect(password.contains { $0.isLowercase })
      #expect(password.contains { $0.isUppercase })
      #expect(password.contains { $0.isNumber })
    }
  }

  @Test func noLookAlikes() {
    for character in "0Oo1lIi" { #expect(!PasswordGenerator.readableAlphabet.contains(character)) }
    #expect(PasswordGenerator.readableAlphabet.count == 55)
  }

  @Test func configurableLength() {
    let generator = PasswordGenerator(groups: 3, groupLength: 6, separator: ".")
    let password = generator.generate()
    #expect(password.count == 20)
    #expect(password.split(separator: ".").map(\.count) == [6, 6, 6])
    #expect(PasswordGenerator(groups: 1, groupLength: 12, separator: "").generate().count == 12)
  }

  @Test func entropyAndStrength() {
    let standard = PasswordGenerator()
    #expect(abs(standard.entropy - 16 * log2(55)) < 0.0001)
    #expect(standard.strength == .strong)
    #expect(PasswordGenerator(groups: 2).strength == .fair)  // 8 characters, ~46 bits
    #expect(PasswordGenerator(groups: 3).strength == .good)  // 12 characters, ~69 bits
    #expect(PasswordGenerator(groups: 1).strength == .weak)
  }

  @Test func thresholds() {
    #expect(PasswordStrength(bits: 0) == .weak)
    #expect(PasswordStrength(bits: 39.9) == .weak)
    #expect(PasswordStrength(bits: 40) == .fair)
    #expect(PasswordStrength(bits: 60) == .good)
    #expect(PasswordStrength(bits: 79.9) == .good)
    #expect(PasswordStrength(bits: 80) == .strong)
    #expect(PasswordStrength.weak < .strong)
  }

  @Test func typedPasswords() {
    #expect(PasswordStrength(password: "") == .weak)
    #expect(PasswordStrength(password: "Password") == .weak)
    #expect(PasswordStrength(password: "aaaaaaaaaaaaaaaa") == .weak)
    #expect(PasswordStrength(password: "123456789012") == .weak)
    #expect(PasswordStrength(password: "kitten42") == .weak)
    #expect(PasswordStrength(password: "Tr0ub4dor&3") >= .fair)
    #expect(PasswordStrength(password: PasswordGenerator().generate()) == .strong)
  }

  @Test func description() {
    #expect(PasswordStrength.description(of: "vT7q-Lm2x-9KpR-wd4Z") == "Strong · 19 characters")
    #expect(PasswordStrength.description(of: "a") == "Weak · 1 character")
  }
}
