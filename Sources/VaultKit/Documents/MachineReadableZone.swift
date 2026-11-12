import Foundation

/// The machine-readable zone of a passport (TD3: two lines of 44), an ID card or residence permit (TD1: three of
/// 30) or an older ID (TD2: two of 36), per ICAO 9303. Read from recognized text; the check digits say whether the
/// reading is right.
///
/// The zone is found by its dates, not by its lines' lengths: on a real page the text recognizer drops or merges
/// filler runs, and often stops before a line's last `<<<<<10`. The block every format shares (birth, its check
/// digit, the sex, the expiry and its check digit) is looked for in every line, its check digits confirm it, and the
/// fields around it are read from where they sit relative to it.
public struct MachineReadableZone: Hashable, Sendable {
  public enum Format: Hashable, Sendable { case td1, td2, td3 }

  public var format: Format
  /// "P" for a passport, "I", "A" or "C" for an ID, "IR"/"AR" style codes for residence permits; empty when the line
  /// that holds it couldn't be read.
  public var documentCode: String
  public var issuer: String
  public var surname: String
  public var givenNames: String
  public var number: String
  /// Whether `number` matches its check digit (as read, or with one of OCR's letter–digit slips undone).
  public var numberMatchesCheck: Bool
  public var nationality: String
  /// "yyyy-MM-dd"; nil when its check digit doesn't match.
  public var birthDate: String?
  /// "M", "F" or "X".
  public var sex: String
  /// "yyyy-MM-dd"; nil when its check digit doesn't match.
  public var expires: String?
  /// Whether every check digit that was read matches (the composite one only when the line was read to its end).
  public var isValid: Bool
  /// The zone's lines as read and corrected.
  public var lines: [String]

  public var isPassport: Bool { documentCode.hasPrefix("P") }
  /// "Aiko Tanaka".
  public var fullName: String {
    [givenNames, surname].filter { !$0.isEmpty }.map(Self.titleCase).joined(separator: " ")
  }

  /// Finds a zone in recognized lines of text. OCR's usual slips are corrected: spaces dropped, « as `<<`, letters
  /// read in digit places (O → 0) and digits in letter places (0 → O), fillers dropped at a line's end.
  public init?(text lines: [String], now: Date = .now) {
    let cleaned = lines.map(Self.clean)
    for (index, line) in cleaned.enumerated() {
      let chars = Array(line)
      guard let block = Self.dateBlock(in: chars) else { continue }
      if block.offset >= 5, let zone = Self.numberLine(chars, block: block, index: index, in: cleaned, now: now) {
        self = zone
        return
      }
      if block.offset <= 1, let zone = Self.td1(chars, block: block, index: index, in: cleaned, now: now) {
        self = zone
        return
      }
    }
    return nil
  }

  /// Whether a recognized line looks like one of a zone's: fillers in a long line or after a passport's code, or a
  /// zone's date block with its check digits (a number line read without its fillers). Share a Copy covers these.
  public static func isZoneLine(_ text: String) -> Bool {
    let line = clean(text)
    let fillers = line.filter { $0 == "<" }.count
    if fillers >= 3, line.count >= 28 || (line.hasPrefix("P") && line.count >= 12 && line.contains("<<")) { return true }
    return dateBlock(in: Array(line)).map { $0.birthCheck && $0.expiryCheck } ?? false
  }

  // MARK: Formats

  /// A passport's (TD3) or an older ID's (TD2) second line: number, check, nationality, then the date block; the
  /// names line is the zone line above it.
  private static func numberLine(
    _ chars: [Character], block: DateBlock, index: Int, in lines: [String], now: Date
  ) -> MachineReadableZone? {
    let start = block.offset
    let nationality = letters(String(chars[(start - 3)..<start])).replacingOccurrences(of: "<", with: "")
    let numberField = String(chars[max(0, start - 13)..<(start - 4)])
    let (number, numberCheck) = checkedNumber(numberField, check: digit(chars[start - 4]))
    let header = namesLine(above: index, in: lines)
    // The line from its first place: 44 for TD3, 36 for TD2, when it was read whole.
    let first = start - 13
    let length = chars.count - first
    // A passport's is TD3 (OCR often stops before a line's end, so a short line says little); an ID's is TD2.
    let isPassport = header.map { $0.hasPrefix("P") } ?? true
    let format: Format = isPassport || max(header?.count ?? 0, length) >= 40 ? .td3 : .td2
    var composite: Bool?
    let full = format == .td3 ? 44 : 36
    if first >= 0, length == full {
      let line = Array(numeric(Array(chars[first...]), [9..<10, 13..<20, 21..<28, (full - 1)..<full]))
      let text = s(line, 0, 10) + s(line, 13, 7) + s(line, 21, full - 22)
      composite = check(text, digit(line[full - 1]))
    }
    let names = header.map(parseHeader) ?? (code: "", issuer: "", names: "")
    return MachineReadableZone(
      format: format, documentCode: names.code, issuer: names.issuer, names: names.names, number: number,
      numberCheck: numberCheck, nationality: nationality, block: block, composite: composite,
      lines: [header, String(chars)].compactMap { $0 }, now: now)
  }

  /// An ID card's (TD1) zone: the first line holds the code, the issuer and the number, the second starts with the
  /// date block and has the nationality after it, the third the names.
  private static func td1(
    _ chars: [Character], block: DateBlock, index: Int, in lines: [String], now: Date
  ) -> MachineReadableZone? {
    let after = block.offset + 15
    let nationality = after + 3 <= chars.count
      ? letters(String(chars[after..<(after + 3)])).replacingOccurrences(of: "<", with: "") : ""
    // The first line: the nearest of the two above that starts like an ID's.
    let above = [index - 1, index - 2].filter { $0 >= 0 }.map { Array(lines[$0]) }
    guard let first = above.first(where: { $0.count >= 15 && "IAC".contains($0[0]) }) else { return nil }
    let (number, numberCheck) = checkedNumber(s(first, 5, 9), check: digit(first[14]))
    let names = index + 1 < lines.count && lines[index + 1].contains("<") ? lines[index + 1] : ""
    var composite: Bool?
    if first.count == 30, chars.count == 30, block.offset == 0 {
      let a = numeric(first, [14..<15]), b = numeric(chars, [0..<7, 8..<15, 29..<30])
      composite = check(s(a, 5, 25) + s(b, 0, 7) + s(b, 8, 7) + s(b, 18, 11), digit(b[29]))
    }
    return MachineReadableZone(
      format: .td1, documentCode: s(first, 0, 2), issuer: letters(s(first, 2, 3)), names: names, number: number,
      numberCheck: numberCheck, nationality: nationality, block: block, composite: composite,
      lines: [String(first), String(chars), names].filter { !$0.isEmpty }, now: now)
  }

  private init(
    format: Format, documentCode: String, issuer: String, names: String, number: String, numberCheck: Bool,
    nationality: String, block: DateBlock, composite: Bool?, lines: [String], now: Date
  ) {
    self.format = format
    self.documentCode = documentCode.replacingOccurrences(of: "<", with: "")
    self.issuer = issuer.replacingOccurrences(of: "<", with: "")
    (surname, givenNames) = Self.names(names)
    self.number = number
    numberMatchesCheck = numberCheck
    self.nationality = nationality
    birthDate = block.birthCheck ? Self.day(block.birth, future: false, now: now) : nil
    sex = block.sex == "<" ? "X" : String(block.sex)
    expires = block.expiryCheck ? Self.day(block.expiry, future: true, now: now) : nil
    isValid = numberCheck && block.birthCheck && block.expiryCheck && composite != false
    self.lines = lines
  }

  // MARK: Reading

  /// Birth (6 digits), its check digit, the sex, the expiry (6) and its check digit: 15 places every format has.
  struct DateBlock {
    var offset: Int
    var birth: String
    var birthCheck: Bool
    var sex: Character
    var expiry: String
    var expiryCheck: Bool
  }

  /// The first place in a line where the date block stands with both check digits matching, or one matching in a
  /// line that has fillers (a zone line for sure) while the other date is still a day.
  static func dateBlock(in chars: [Character]) -> DateBlock? {
    guard chars.count >= 15 else { return nil }
    var fallback: DateBlock?
    for offset in 0...(chars.count - 15) {
      let block = numeric(Array(chars[offset..<(offset + 15)]), [0..<7, 8..<15])
      let sex = block[7] == "K" ? "<" : block[7]
      guard "MFX<".contains(sex), block.enumerated().allSatisfy({ $0.offset == 7 || $0.element.isASCII && $0.element.isNumber })
      else { continue }
      let birth = String(block[0..<6]), expiry = String(block[8..<14])
      let found = DateBlock(
        offset: offset, birth: birth, birthCheck: check(birth, digit(block[6])), sex: sex, expiry: expiry,
        expiryCheck: check(expiry, digit(block[14])))
      if found.birthCheck && found.expiryCheck { return found }
      if fallback == nil, found.birthCheck || found.expiryCheck, chars.contains("<"),
        day(birth, future: false) != nil, day(expiry, future: true) != nil
      {
        fallback = found
      }
    }
    return fallback
  }

  /// The zone line just above the number line that holds the code, the issuer and the names.
  private static func namesLine(above index: Int, in lines: [String]) -> String? {
    for row in [index - 1, index - 2] where row >= 0 {
      let line = lines[row]
      if line.count >= 6, line.contains("<"), let first = line.first, "PIACV".contains(first) { return line }
    }
    return nil
  }

  /// A TD2/TD3 first line's code, issuer and names. « read for a single filler after the code ("P«UTO…") is undone.
  private static func parseHeader(_ line: String) -> (code: String, issuer: String, names: String) {
    var chars = Array(line)
    if chars.count > 4, chars[1] == "<", chars[2] == "<", chars[3].isLetter, chars[4].isLetter { chars.remove(at: 2) }
    return (s(chars, 0, 2), letters(s(chars, 2, 3)), chars.count > 5 ? String(chars[5...]) : "")
  }

  /// Surname and given names from a names field: `<<` between them, `<` between words. Names have no digits (a 0
  /// read in one is an O), and a run of fillers read as K's at the end is no name.
  private static func names(_ field: String) -> (surname: String, given: String) {
    let parts = letters(field).components(separatedBy: "<<").map {
      $0.replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
    }.filter { part in !part.isEmpty && !(part.count >= 2 && part.allSatisfy { $0 == "K" || $0 == " " }) }
    return (parts.first ?? "", parts.dropFirst().joined(separator: " "))
  }

  /// The document number and whether it matches its check digit, as read or with letter–digit slips undone (the
  /// change with the fewest swaps that matches). Fillers at the end don't count toward the digit.
  private static func checkedNumber(_ field: String, check digit: Int?) -> (String, Bool) {
    let field = String(field.reversed().drop { $0 == "<" }.reversed())
    guard let digit else { return (field.replacingOccurrences(of: "<", with: ""), false) }
    if check(field, digit) { return (field.replacingOccurrences(of: "<", with: ""), true) }
    let swaps: [Character: Character] = [
      "O": "0", "0": "O", "D": "0", "Q": "0", "I": "1", "1": "I", "L": "1", "B": "8", "8": "B", "S": "5", "5": "S",
      "Z": "2", "2": "Z", "G": "6", "6": "G",
    ]
    let places = Array(field).indices.filter { swaps[Array(field)[$0]] != nil }
    guard places.count <= 10 else { return (field, false) }
    var best: String?
    var fewest = Int.max
    for mask in 1..<(1 << places.count) where mask.nonzeroBitCount < fewest {
      var chars = Array(field)
      for (bit, place) in places.enumerated() where mask & (1 << bit) != 0 { chars[place] = swaps[chars[place]]! }
      if check(String(chars), digit) {
        best = String(chars)
        fewest = mask.nonzeroBitCount
      }
    }
    return best.map { ($0.replacingOccurrences(of: "<", with: ""), true) } ?? (field.replacingOccurrences(of: "<", with: ""), false)
  }

  /// Upper case, no spaces, `«` as `<<` and other lookalikes as `<`.
  static func clean(_ line: String) -> String {
    var text = line.uppercased().replacingOccurrences(of: " ", with: "")
    text = text.replacingOccurrences(of: "«", with: "<<")
    for lookalike in ["‹", "＜", "〈", "く"] { text = text.replacingOccurrences(of: lookalike, with: "<") }
    return String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "<") })
  }

  private static func s(_ chars: [Character], _ start: Int, _ length: Int) -> String {
    guard start < chars.count else { return "" }
    return String(chars[start..<min(chars.count, start + length)])
  }

  /// The characters at these places read as digits (dates and check digits), so the composite check sees them fixed.
  private static func numeric(_ chars: [Character], _ ranges: [Range<Int>]) -> [Character] {
    var chars = chars
    for range in ranges {
      for index in range where chars.indices.contains(index) {
        chars[index] = digits(String(chars[index])).first ?? chars[index]
      }
    }
    return chars
  }

  /// Letters OCR mistakes for digits in a numeric field.
  private static func digits(_ text: String) -> String {
    String(text.map { ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8", "G": "6"][$0] ?? $0 })
  }

  /// Digits OCR mistakes for letters in a field of letters (names, codes of countries).
  private static func letters(_ text: String) -> String {
    String(text.map { ["0": "O", "1": "I", "5": "S", "8": "B", "6": "G", "2": "Z", "4": "A", "7": "T"][$0] ?? $0 })
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

  /// "320312" → "2032-03-12". A birth year in the future is last century; an expiry more than 50 years ahead is
  /// last century too, and one more than 50 years back is next century.
  static func day(_ text: String, future: Bool, now: Date = .now) -> String? {
    guard text.count == 6, let yy = Int(text.prefix(2)), let mm = Int(text.dropFirst(2).prefix(2)),
      let dd = Int(text.suffix(2))
    else { return nil }
    let thisYear = Calendar(identifier: .gregorian).component(.year, from: now)
    var year = 2000 + yy
    if !future, year > thisYear { year -= 100 }
    if future, year > thisYear + 50 { year -= 100 }
    if future, year < thisYear - 50 { year += 100 }
    return DocumentDay.string(year: year, month: mm, day: dd)
  }

  /// "ANNE-MARIE O'NEIL" → "Anne-Marie O'Neil".
  static func titleCase(_ name: String) -> String {
    var result = ""
    var startsWord = true
    for character in name {
      result += startsWord ? character.uppercased() : character.lowercased()
      startsWord = character == " " || character == "-" || character == "'"
    }
    return result
  }
}
