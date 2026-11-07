import Foundation

/// The machine-readable zone of a passport (TD3: two lines of 44), an ID card or residence permit (TD1: three of
/// 30) or an older ID (TD2: two of 36), per ICAO 9303. Read from recognized text; the check digits say whether the
/// reading is right.
public struct MachineReadableZone: Hashable, Sendable {
  public enum Format: Hashable, Sendable { case td1, td2, td3 }

  public var format: Format
  /// "P" for a passport, "I", "A" or "C" for an ID, "IR"/"AR" style codes for residence permits.
  public var documentCode: String
  public var issuer: String
  public var surname: String
  public var givenNames: String
  public var number: String
  public var nationality: String
  /// "yyyy-MM-dd".
  public var birthDate: String?
  /// "M", "F" or "X".
  public var sex: String
  /// "yyyy-MM-dd".
  public var expires: String?
  /// Whether every check digit matches.
  public var isValid: Bool
  /// The zone's lines as read and corrected.
  public var lines: [String]

  public var isPassport: Bool { documentCode.hasPrefix("P") }
  /// "Aiko Tanaka".
  public var fullName: String {
    [givenNames, surname].filter { !$0.isEmpty }.map(Self.titleCase).joined(separator: " ")
  }

  /// Finds a zone in recognized lines of text. OCR's usual slips are corrected: spaces dropped, « and K-runs read
  /// as `<` where the line's shape needs filler.
  public init?(text lines: [String]) {
    // A passport's name line may come back short: OCR often stops reading the fillers after the names.
    let candidates = lines.map(Self.clean).filter { line in
      line.filter({ $0 == "<" }).count >= 2 && (line.count >= 28 || (line.hasPrefix("P") && line.count >= 10))
    }
    for (index, line) in candidates.enumerated() {
      let rest = Array(candidates[(index + 1)...])
      // OCR drops trailing fillers from the name line more often than from the number line, which check digits cover.
      if line.count >= 42 || line.hasPrefix("P"),
        line.hasPrefix("P") || line.first.map({ "ACIV".contains($0) }) == true,
        let second = rest.first(where: { $0.count >= 42 }), let zone = Self.td3(Self.fit(line, 44), Self.fit(second, 44))
      {
        self = zone
        return
      }
      if line.count >= 34, line.count < 42, let second = rest.first(where: { $0.count >= 34 && $0.count < 42 }),
        let zone = Self.td2(Self.fit(line, 36), Self.fit(second, 36))
      {
        self = zone
        return
      }
      if line.count >= 28, line.count < 34, rest.count >= 2, let zone = Self.td1(
        Self.fit(line, 30), Self.fit(rest[0], 30), Self.fit(rest[1], 30))
      {
        self = zone
        return
      }
    }
    return nil
  }

  private init(
    format: Format, code: String, issuer: String, names: String, number: String, numberCheck: Bool,
    nationality: String, birth: String, birthCheck: Bool, sex: String, expiry: String, expiryCheck: Bool,
    composite: Bool, lines: [String]
  ) {
    self.format = format
    documentCode = code.replacingOccurrences(of: "<", with: "")
    self.issuer = issuer.replacingOccurrences(of: "<", with: "")
    // Names have no digits: a 0 read in one is an O.
    let parts = Self.letters(names).components(separatedBy: "<<")
    surname = parts.first.map { $0.replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces) } ?? ""
    givenNames = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "<", with: " ")
      .trimmingCharacters(in: .whitespaces)
    self.number = number.replacingOccurrences(of: "<", with: "")
    self.nationality = nationality.replacingOccurrences(of: "<", with: "")
    birthDate = Self.day(birth, future: false)
    self.sex = sex == "<" ? "X" : sex
    expires = Self.day(expiry, future: true)
    isValid = numberCheck && birthCheck && expiryCheck && composite
    self.lines = lines
  }

  private static func td3(_ a: String, _ b: String) -> MachineReadableZone? {
    let a = Array(a), b = numeric(Array(b), [9..<10, 13..<20, 21..<28, 42..<44])
    guard a.count == 44, b.count == 44 else { return nil }
    let number = s(b, 0, 9), birth = digits(s(b, 13, 6)), expiry = digits(s(b, 21, 6))
    let composite = s(b, 0, 10) + s(b, 13, 7) + s(b, 21, 22)
    return MachineReadableZone(
      format: .td3, code: s(a, 0, 2), issuer: s(a, 2, 3), names: s(a, 5, 39), number: number,
      numberCheck: check(number, digit(b[9])), nationality: s(b, 10, 3), birth: birth,
      birthCheck: check(birth, digit(b[19])), sex: String(b[20]), expiry: expiry,
      expiryCheck: check(expiry, digit(b[27])), composite: check(composite, digit(b[43])),
      lines: [String(a), String(b)])
  }

  private static func td2(_ a: String, _ b: String) -> MachineReadableZone? {
    let a = Array(a), b = numeric(Array(b), [9..<10, 13..<20, 21..<28, 35..<36])
    guard a.count == 36, b.count == 36 else { return nil }
    let number = s(b, 0, 9), birth = digits(s(b, 13, 6)), expiry = digits(s(b, 21, 6))
    let composite = s(b, 0, 10) + s(b, 13, 7) + s(b, 21, 14)
    return MachineReadableZone(
      format: .td2, code: s(a, 0, 2), issuer: s(a, 2, 3), names: s(a, 5, 31), number: number,
      numberCheck: check(number, digit(b[9])), nationality: s(b, 10, 3), birth: birth,
      birthCheck: check(birth, digit(b[19])), sex: String(b[20]), expiry: expiry,
      expiryCheck: check(expiry, digit(b[27])), composite: check(composite, digit(b[35])),
      lines: [String(a), String(b)])
  }

  private static func td1(_ a: String, _ b: String, _ c: String) -> MachineReadableZone? {
    let a = numeric(Array(a), [14..<15]), b = numeric(Array(b), [0..<7, 8..<15, 29..<30]), c = Array(c)
    guard a.count == 30, b.count == 30, c.count == 30 else { return nil }
    let number = s(a, 5, 9), birth = digits(s(b, 0, 6)), expiry = digits(s(b, 8, 6))
    let composite = s(a, 5, 25) + s(b, 0, 7) + s(b, 8, 7) + s(b, 18, 11)
    return MachineReadableZone(
      format: .td1, code: s(a, 0, 2), issuer: s(a, 2, 3), names: s(c, 0, 30), number: number,
      numberCheck: check(number, digit(a[14])), nationality: s(b, 15, 3), birth: birth,
      birthCheck: check(birth, digit(b[6])), sex: String(b[7]), expiry: expiry,
      expiryCheck: check(expiry, digit(b[14])), composite: check(composite, digit(b[29])),
      lines: [String(a), String(b), String(c)])
  }

  // MARK: Reading

  /// Upper case, no spaces, `«` as `<<` and other lookalikes as `<`.
  static func clean(_ line: String) -> String {
    var text = line.uppercased().replacingOccurrences(of: " ", with: "")
    text = text.replacingOccurrences(of: "«", with: "<<")
    for lookalike in ["‹", "＜", "〈"] { text = text.replacingOccurrences(of: lookalike, with: "<") }
    return String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "<") })
  }

  /// The line padded with `<` or cut to `length`. OCR drops or adds fillers: at the end of a line that ends in them,
  /// in the last run of them in one that ends in check digits ("…194<<<<<<<<<<<<<04").
  static func fit(_ line: String, _ length: Int) -> String {
    guard line.count != length else { return line }
    var chars = Array(line)
    if chars.last != "<", let run = lastRun(chars) {
      if chars.count < length {
        chars.insert(contentsOf: Array(repeating: "<", count: length - chars.count), at: run.upperBound)
        return String(chars)
      }
      if chars.count - length < run.count {
        chars.removeSubrange(run.upperBound - (chars.count - length)..<run.upperBound)
        return String(chars)
      }
    }
    return chars.count > length ? String(chars.prefix(length)) : line + String(repeating: "<", count: length - chars.count)
  }

  /// The last run of two or more fillers.
  private static func lastRun(_ chars: [Character]) -> Range<Int>? {
    var end = chars.count
    while end > 0 {
      guard let last = chars[..<end].lastIndex(of: "<") else { return nil }
      var start = last
      while start > 0, chars[start - 1] == "<" { start -= 1 }
      if last - start >= 1 { return start..<(last + 1) }
      end = start
    }
    return nil
  }

  private static func s(_ chars: [Character], _ start: Int, _ length: Int) -> String {
    String(chars[start..<min(chars.count, start + length)])
  }

  /// The characters at these places read as digits (dates and check digits), so the composite check sees them fixed.
  private static func numeric(_ chars: [Character], _ ranges: [any RangeExpression<Int>]) -> [Character] {
    var chars = chars
    for range in ranges {
      for index in range.relative(to: chars.indices) where chars.indices.contains(index) {
        chars[index] = digits(String(chars[index])).first ?? chars[index]
      }
    }
    return chars
  }

  /// Letters OCR mistakes for digits in a numeric field.
  private static func digits(_ text: String) -> String {
    String(text.map { ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8", "G": "6"][$0] ?? $0 })
  }

  private static func letters(_ text: String) -> String {
    String(text.map { ["0": "O", "1": "I", "5": "S", "8": "B", "6": "G", "2": "Z"][$0] ?? $0 })
  }

  private static func digit(_ character: Character) -> Int? {
    character == "<" ? 0 : Int(digits(String(character)))
  }

  /// ICAO 9303's check digit: weights 7, 3, 1 over the values (digits, A=10…Z=35, < = 0), mod 10.
  public static func checkDigit(_ text: String) -> Int {
    let weights = [7, 3, 1]
    var sum = 0
    for (index, character) in text.enumerated() {
      let value: Int
      if let number = character.wholeNumberValue {
        value = number
      } else if let ascii = character.asciiValue, character.isLetter {
        value = Int(ascii) - 55
      } else {
        value = 0
      }
      sum += value * weights[index % 3]
    }
    return sum % 10
  }

  private static func check(_ text: String, _ digit: Int?) -> Bool { digit == checkDigit(text) }

  /// "320312" → "2032-03-12". A birth year in the future is last century; an expiry is this century.
  static func day(_ text: String, future: Bool, now: Date = .now) -> String? {
    guard text.count == 6, let yy = Int(text.prefix(2)), let mm = Int(text.dropFirst(2).prefix(2)),
      let dd = Int(text.suffix(2))
    else { return nil }
    let thisYear = Calendar(identifier: .gregorian).component(.year, from: now)
    var year = 2000 + yy
    if !future, year > thisYear { year -= 100 }
    if future, year < thisYear - 50 { year += 100 }
    return DocumentDay.string(year: year, month: mm, day: dd)
  }

  private static func titleCase(_ name: String) -> String {
    name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
  }
}
