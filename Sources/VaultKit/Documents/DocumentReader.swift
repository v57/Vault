import Foundation

/// What the text on a page suggests: the kind of document and the fields it could fill. Works on lines of text that
/// the device recognized (PlatformScan on Apple platforms); nothing leaves the device. The user checks every
/// suggestion before saving.
public struct DocumentSuggestion: Hashable, Sendable {
  public var kind: String
  /// Field values by key; days as "yyyy-MM-dd".
  public var fields: [String: String]
  /// The machine-readable zone, when the page has one.
  public var zone: MachineReadableZone?
  public var title: String

  public init(kind: String, fields: [String: String] = [:], zone: MachineReadableZone? = nil, title: String = "") {
    self.kind = kind
    self.fields = fields
    self.zone = zone
    self.title = title
  }
}

public enum DocumentReader {
  /// Reads a document's pages (the text of each, in order).
  public static func suggest(pages: [[String]], now: Date = .now) -> DocumentSuggestion {
    var suggestion = read(pages: pages, now: now)
    suggestion.fields = plausibleDates(suggestion.fields, kind: suggestion.kind, now: now)
    return suggestion
  }

  private static func read(pages: [[String]], now: Date) -> DocumentSuggestion {
    let lines = pages.flatMap { $0 }
    let text = lines.joined(separator: "\n").lowercased()
    let zone = MachineReadableZone(text: lines, now: now)
    let kind = zone.map { kind(of: $0, text: text) } ?? guessKind(text)
    var fields: [String: String] = [:]
    let known = DocumentKinds()[kind]
    for (key, labels) in labelledDates where known.field(key) != nil {
      if let day = date(after: labels, in: lines, key: key, now: now) { fields[key] = day }
    }
    if identityKinds.contains(kind) {
      fields.merge(person(in: lines)) { old, _ in old }
    }
    if kind == DocumentKind.driversLicence.id {
      // EU licences number their fields: 4a issued, 4b expires, 5 the licence number, 9 the classes.
      if fields["issued"] == nil, let day = date(after: ["4a."], in: lines, now: now) { fields["issued"] = day }
      if fields["expires"] == nil, let day = date(after: ["4b."], in: lines, now: now) { fields["expires"] = day }
      if let number = value(after: ["5."], in: lines) { fields["number"] = number }
      if let classes = value(after: ["9."], in: lines) { fields["classes"] = classes }
    }
    if kind == DocumentKind.insurancePolicy.id, let number = value(after: policyLabels, in: lines) {
      fields["policyNumber"] = number
    }
    if let zone { fields = merge(zone, into: fields) }
    return DocumentSuggestion(kind: kind, fields: fields.filter { !$0.value.isEmpty }, zone: zone)
  }

  static let identityKinds: Set<String> = [
    DocumentKind.passport.id, DocumentKind.idCard.id, DocumentKind.residencePermit.id, DocumentKind.driversLicence.id,
  ]

  private static func kind(of zone: MachineReadableZone, text: String) -> String {
    if zone.isPassport { return DocumentKind.passport.id }
    if zone.documentCode.count > 1 && "RT".contains(zone.documentCode.last!) { return DocumentKind.residencePermit.id }
    if ["aufenthalt", "residence", "titre de séjour", "permesso"].contains(where: text.contains) {
      return DocumentKind.residencePermit.id
    }
    if zone.documentCode.isEmpty {
      // The code's line wasn't read: the words say which, else a passport's zone is a passport.
      let words = guessKind(text)
      if [DocumentKind.passport.id, DocumentKind.idCard.id].contains(words) { return words }
      return zone.format == .td3 ? DocumentKind.passport.id : DocumentKind.idCard.id
    }
    return DocumentKind.idCard.id
  }

  /// The zone's fields over the ones read from labels: its dates and number where their check digits match, its
  /// name unless the printed one is the same name with its accents ("Müller" for MUELLER), its nationality as a
  /// country's name, or the printed one when the code is no country the system names.
  private static func merge(_ zone: MachineReadableZone, into labelled: [String: String]) -> [String: String] {
    var fields = labelled
    let printed = labelled["name"] ?? ""
    if !zone.fullName.isEmpty, printed.isEmpty || !sameName(printed, zone.fullName) { fields["name"] = zone.fullName }
    let code = zone.nationality.isEmpty ? zone.issuer : zone.nationality
    if let country = countryName(code), country != code || (fields["country"] ?? "").isEmpty { fields["country"] = country }
    if zone.numberMatchesCheck || (fields["number"] ?? "").isEmpty, !zone.number.isEmpty { fields["number"] = zone.number }
    if let birth = zone.birthDate { fields["birthDate"] = birth }
    if let expires = zone.expires { fields["expires"] = expires }
    return fields
  }

  /// Whether two spellings are one name: the zone writes Ä as AE or A, drops accents and hyphens.
  static func sameName(_ a: String, _ b: String) -> Bool {
    func folded(_ name: String, spelled: Bool) -> String {
      var text = name.uppercased()
      if spelled {
        for (letter, spelling) in [("Ä", "AE"), ("Ö", "OE"), ("Ü", "UE"), ("ß", "SS"), ("Å", "AA"), ("Æ", "AE"), ("Ø", "OE")] {
          text = text.replacingOccurrences(of: letter, with: spelling)
        }
      }
      return String(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter(\.isLetter))
    }
    let zone = folded(b, spelled: false)
    return folded(a, spelled: true) == zone || folded(a, spelled: false) == zone
  }

  /// Drops the dates that can't be what their field says, so a misread never fills one: a birth or an issue in the
  /// future, an issue on or before the birth, an expiry on or before the issue or the birth, and one day given to two
  /// of these fields (one match read for both). A birth certificate may be issued on the day of the birth.
  static func plausibleDates(_ fields: [String: String], kind: String, now: Date = .now) -> [String: String] {
    var fields = fields
    func day(_ key: String) -> Date? { fields[key].flatMap(DocumentDay.date(from:)) }
    let today = DocumentDay.date(from: DocumentDay.string(from: now)) ?? now
    for key in ["birthDate", "issued"] where day(key).map({ $0 > today }) == true { fields[key] = nil }
    if let birth = day("birthDate"), let issued = day("issued") {
      if issued < birth || (issued == birth && kind != DocumentKind.birthCertificate.id) { fields["issued"] = nil }
    }
    if let expires = day("expires") {
      // The expiry is the one the reader is surest of (the zone's, or its own label): the other date goes.
      if let issued = day("issued"), expires <= issued { fields["issued"] = nil }
      if let birth = day("birthDate"), expires <= birth { fields["birthDate"] = nil }
    }
    return fields
  }

  // MARK: Kinds

  /// Words that name a kind, in the languages the pages are likely in. First match wins, so the specific come first.
  static let kindWords: [(kind: String, words: [String])] = [
    (DocumentKind.driversLicence.id, ["führerschein", "driving licence", "driver license", "driver's license", "permis de conduire", "運転免許"]),
    (DocumentKind.residencePermit.id, ["aufenthaltstitel", "residence permit", "titre de séjour", "permesso di soggiorno"]),
    (DocumentKind.passport.id, ["passport", "reisepass", "passeport", "旅券"]),
    (DocumentKind.idCard.id, ["personalausweis", "identity card", "carte d'identité", "carta d'identità"]),
    (DocumentKind.birthCertificate.id, ["birth certificate", "geburtsurkunde", "acte de naissance"]),
    (DocumentKind.resume.id, ["curriculum vitae", "resume", "résumé", "lebenslauf", "work experience", "berufserfahrung"]),
    (DocumentKind.payslip.id, ["payslip", "pay slip", "gehaltsabrechnung", "lohnabrechnung", "net pay", "nettobezug"]),
    (DocumentKind.employmentContract.id, ["employment contract", "arbeitsvertrag", "contract of employment"]),
    (DocumentKind.insurancePolicy.id, ["insurance policy", "versicherungsschein", "policy schedule", "versicherungsnummer", "policy number", "insured"]),
    (DocumentKind.lease.id, ["mietvertrag", "lease agreement", "tenancy agreement", "rental agreement", "landlord", "vermieter"]),
    (DocumentKind.vehicleRegistration.id, ["zulassungsbescheinigung", "vehicle registration", "certificate of registration", "fahrzeugschein"]),
    (DocumentKind.warranty.id, ["warranty", "garantie", "receipt", "quittung", "kassenbon", "invoice", "rechnung"]),
    (DocumentKind.bankDocument.id, ["iban", "bank statement", "kontoauszug"]),
    (DocumentKind.contract.id, ["contract", "vertrag", "customer number", "kundennummer"]),
    (DocumentKind.certificate.id, ["certificate", "zertifikat", "certified"]),
  ]

  /// The first kind one of whose words starts a word of the text: "Rechnung" is a receipt, "Nebenkostenabrechnung"
  /// (a utility bill) isn't.
  static func guessKind(_ text: String) -> String {
    kindWords.first { $0.words.contains { startsAWord($0, in: text) } }?.kind ?? DocumentKind.other.id
  }

  private static func startsAWord(_ word: String, in text: String) -> Bool {
    var range = text.startIndex..<text.endIndex
    while let found = text.range(of: word, range: range) {
      if found.lowerBound == text.startIndex || !text[text.index(before: found.lowerBound)].isLetter { return true }
      range = found.upperBound..<text.endIndex
    }
    return false
  }

  // MARK: Fields

  static let labelledDates: [(key: String, labels: [String])] = [
    ("expires", ["date of expiry", "expiry", "expires", "valid until", "gültig bis", "ablaufdatum", "date d'expiration", "date d’expiration"]),
    ("issued", ["date of issue", "issued", "ausstellungsdatum", "ausgestellt am", "date de délivrance"]),
    ("birthDate", ["date of birth", "geburtsdatum", "geburtstag", "born", "date de naissance"]),
    ("renews", ["renewal date", "renews", "hauptfälligkeit", "verlängert sich", "next renewal"]),
    ("starts", ["start date", "begins", "beginn", "commencement", "vertragsbeginn", "mietbeginn"]),
    ("bought", ["date of purchase", "purchase date", "kaufdatum", "datum"]),
    ("warrantyUntil", ["warranty until", "garantie bis"]),
    ("dated", ["date", "datum"]),
  ]

  static let policyLabels = ["policy number", "policy no", "versicherungsnummer", "vertragsnummer", "versicherungsschein-nr"]

  /// An identity document's printed labels (the visual zone), as whole words: in English, French and German, as
  /// passports print them ("Surname / Nom", "Given names / Prénoms", "Name/Surname/Nom").
  static let surnameLabels = ["surname", "nom", "name", "familienname", "apellidos", "cognome"]
  static let givenNameLabels = ["given names", "given name", "forenames", "prénoms", "vornamen", "nombres", "nome"]
  static let nationalityLabels = ["nationality", "nationalité", "staatsangehörigkeit", "nacionalidad", "cittadinanza"]
  static let numberLabels = [
    "passport no", "passport number", "passport n°", "n° du passeport", "no. du passeport", "document no",
    "document number", "card no", "pass-nr", "passnummer", "ausweisnummer",
  ]

  /// The holder, nationality and number an identity document prints beside its labels.
  static func person(in lines: [String]) -> [String: String] {
    var fields: [String: String] = [:]
    let isName: (String) -> Bool = { value in
      value.count >= 2 && value.allSatisfy { $0.isLetter || " -'’".contains($0) } && value.contains(where: \.isLetter)
    }
    let surname = text(after: surnameLabels, in: lines, where: isName)
    let given = text(after: givenNameLabels, in: lines, where: isName)
    let name = [given, surname].compactMap { $0 }.map(MachineReadableZone.titleCase).joined(separator: " ")
    if !name.isEmpty { fields["name"] = name }
    if let nationality = text(after: nationalityLabels, in: lines, where: { isName($0) && $0.count >= 3 }) {
      fields["country"] = MachineReadableZone.titleCase(nationality)
    }
    let number = text(after: numberLabels, in: lines) { value in
      let compact = value.replacingOccurrences(of: " ", with: "")
      return (5...12).contains(compact.count) && compact.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
        && compact.contains(where: \.isNumber)
    }
    if let number { fields["number"] = number.replacingOccurrences(of: " ", with: "") }
    return fields
  }

  /// The value printed for a label (a whole word or words on a line): at the end of the label's line in capitals
  /// ("1. Name/Surname/Nom MUSTERMANN"), or in the row of values below the label's row. The first that `isValue`
  /// takes.
  static func text(after labels: [String], in lines: [String], where isValue: (String) -> Bool) -> String? {
    for (index, line) in lines.enumerated() where labels.contains(where: { hasWord($0, in: line) }) {
      // The capitals at the line's end: the labels are in mixed case, the values in capitals.
      let tail = line.split(separator: " ").reversed().prefix { word in
        !word.contains(where: \.isLowercase) && word != "/" && !word.hasSuffix("/")
      }.reversed().joined(separator: " ").trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
      if !tail.isEmpty, isValue(tail) { return tail }
      if let value = values(forLabelAt: index, in: lines).first(where: isValue) { return value }
    }
    return nil
  }

  /// Whether `word` stands as a whole word (or words) in `line`, ignoring case and accents.
  private static func hasWord(_ word: String, in line: String) -> Bool {
    var range = line.startIndex..<line.endIndex
    while let found = line.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
      let before = found.lowerBound == line.startIndex || !line[line.index(before: found.lowerBound)].isLetter
      let after = found.upperBound == line.endIndex || !line[found.upperBound].isLetter
      if before && after { return true }
      range = found.upperBound..<line.endIndex
    }
    return false
  }

  /// A line of labels rather than values: it has lower case letters (passports print values in capitals) and no date.
  static func isLabelLine(_ line: String) -> Bool {
    line.contains(where: \.isLowercase) && dates(in: line).isEmpty
  }

  /// The lines that may hold the value of the label on line `index`, the likeliest first. The text recognizer reads
  /// a row of labels and the row of their values below as separate lines, one per column ("Date of birth / Date de
  /// naissance", "Personal No. / N° personnel", "12 AUG/AOÛT 74", "ZE 184226 B"): the label's place in its row of
  /// labels is its value's place in the row of values. The row's other values follow.
  static func values(forLabelAt index: Int, in lines: [String]) -> [String] {
    var start = index, end = index
    while start > 0, index - start < 3, isLabelLine(lines[start - 1]) { start -= 1 }
    while end + 1 < lines.count, end - start < 3, isLabelLine(lines[end + 1]) { end += 1 }
    var row: [String] = []
    var next = end + 1
    while next < lines.count, row.count <= end - start, !isLabelLine(lines[next]) {
      row.append(lines[next].trimmingCharacters(in: .whitespaces))
      next += 1
    }
    let place = index - start
    guard place < row.count else { return row }
    return [row[place]] + row.enumerated().filter { $0.offset != place }.map(\.element)
  }

  /// The first date on the line of a label, or on the line after it. Where labels stand side by side over a line of
  /// dates ("Date of issue   Date of expiry" over "12 MAR 2022   11 MAR 2032"), the label takes the date in its own
  /// column: the second label the second date; where the row of labels and the row of dates were read as a line per
  /// column, the date at the label's place in its row. A two-digit year is this century's, or the last one's for a
  /// birth in the future (`key` "birthDate") or a day more than 50 years ahead.
  static func date(after labels: [String], in lines: [String], key: String = "", now: Date = .now) -> String? {
    for (index, line) in lines.enumerated() {
      let lower = line.lowercased()
      // Lowercasing can change a line's length (İ, ẞ, ligatures), so the label is found in the line itself.
      guard let label = labels.first(where: lower.contains),
        let range = line.range(of: label, options: [.caseInsensitive, .diacriticInsensitive])
      else { continue }
      let rest = String(line[range.upperBound...])
      // A date before the next label on the line is this label's.
      let own = otherDateLabel(in: rest).map { String(rest[..<$0]) } ?? rest
      if let found = foundDates(in: own).first { return century(found, key: key, now: now) }
      guard index + 1 < lines.count else { continue }
      let below = foundDates(in: lines[index + 1])
      if below.isEmpty {
        // A row of labels read as a line each: the date at this label's place in the row of values.
        if let found = values(forLabelAt: index, in: lines).lazy.compactMap({ foundDates(in: $0).first }).first {
          return century(found, key: key, now: now)
        }
        continue
      }
      let column = dateColumn(before: range.lowerBound, in: line, label: label)
      if column < below.count { return century(below[column], key: key, now: now) }
      // Fewer dates below than labels beside each other: which is whose can't be told.
      if column == 0 { return century(below[0], key: key, now: now) }
    }
    return nil
  }

  /// A date read with a two-digit year put in its century (see `date(after:in:key:now:)`).
  private static func century(_ found: FoundDate, key: String, now: Date) -> String {
    guard found.shortYear, let date = DocumentDay.date(from: found.day) else { return found.day }
    let parts = found.day.split(separator: "-").compactMap { Int($0) }
    let thisYear = Calendar(identifier: .gregorian).component(.year, from: now)
    var year = parts[0]
    if key == "birthDate", date > now { year -= 100 }
    if year > thisYear + 50 { year -= 100 }
    return DocumentDay.string(year: year, month: parts[1], day: parts[2]) ?? found.day
  }

  /// Every label of a date, in all languages, with its field; longest first, so "date of issue" is found before "date".
  private static let allDateLabels: [(label: String, key: String)] =
    (labelledDates.flatMap { field in field.labels.map { ($0, field.key) } } + [("4a.", "issued"), ("4b.", "expires")])
    .sorted { $0.0.count > $1.0.count }

  /// Where the first label of a date starts in `text`.
  private static func otherDateLabel(in text: String) -> String.Index? {
    allDateLabels.compactMap { text.range(of: $0.label, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound }.min()
  }

  /// The label's column on its line: how many other fields' date labels come before `end`. A field labelled in two
  /// languages ("Date of issue / Date de délivrance") is one column, and a label inside a longer one ("date" in
  /// "date of birth") isn't counted.
  private static func dateColumn(before end: String.Index, in line: String, label: String) -> Int {
    let own = allDateLabels.first { $0.label == label }?.key
    var taken: [Range<String.Index>] = []
    var keys: Set<String> = []
    for (other, key) in allDateLabels {
      var start = line.startIndex
      while start < end, let found = line.range(of: other, options: [.caseInsensitive, .diacriticInsensitive], range: start..<end) {
        if !taken.contains(where: { $0.overlaps(found) }) {
          taken.append(found)
          if key != own { keys.insert(key) }
        }
        start = found.upperBound
      }
    }
    return keys.count
  }

  /// The text after a label on its line (or the next line when nothing follows it).
  static func value(after labels: [String], in lines: [String]) -> String? {
    for (index, line) in lines.enumerated() {
      let lower = line.lowercased()
      guard let label = labels.first(where: { lower.hasPrefix($0) || lower.contains(" " + $0) || lower.contains($0 + ":") }),
        let range = line.range(of: label, options: [.caseInsensitive, .diacriticInsensitive])
      else { continue }
      var rest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
      while rest.first.map({ ":.#".contains($0) }) == true { rest.removeFirst() }
      rest = rest.trimmingCharacters(in: .whitespaces)
      if rest.isEmpty, index + 1 < lines.count { rest = lines[index + 1].trimmingCharacters(in: .whitespaces) }
      if !rest.isEmpty { return rest }
    }
    return nil
  }

  private static let months: [String: Int] = {
    var map: [String: Int] = [:]
    // English, German, French, Spanish, Italian, Portuguese and Dutch names and the short forms passports print.
    let names = [
      ["jan", "january", "januar", "janvier", "janv", "ene", "enero", "gen", "gennaio", "janeiro"],
      ["feb", "february", "februar", "février", "fév", "fev", "févr", "febrero", "febbraio", "fevereiro"],
      ["mar", "march", "märz", "mars", "mär", "marzo", "março", "maart", "mrt"],
      ["apr", "april", "avril", "avr", "abr", "abril", "aprile"],
      ["may", "mai", "mayo", "mag", "maggio", "maio", "mei"],
      ["jun", "june", "juni", "juin", "junio", "giu", "giugno", "junho"],
      ["jul", "july", "juli", "juillet", "juil", "julio", "lug", "luglio", "julho"],
      ["aug", "august", "août", "aout", "ago", "agosto", "augustus"],
      ["sep", "sept", "september", "septembre", "septiembre", "set", "settembre", "setembro"],
      ["oct", "october", "okt", "oktober", "octobre", "octubre", "ott", "ottobre", "out", "outubro"],
      ["nov", "november", "novembre", "noviembre", "novembro"],
      ["dec", "december", "dez", "dezember", "décembre", "déc", "dic", "diciembre", "dicembre", "dezembro"],
    ]
    for (index, list) in names.enumerated() { for name in list { map[name] = index + 1 } }
    return map
  }()

  /// The first date in a piece of text: 12.03.2032, 12/03/2032, 12 03 2032, 2032-03-12, 12 MAR 2032 (or 12 MAR/MARS
  /// 2032, 12 MAR/MARS 32), March 12, 2032. Day before month where it's ambiguous, as on European and ICAO documents.
  /// A two-digit year is this century's.
  public static func firstDate(in text: String) -> String? {
    dates(in: text).first
  }

  /// Every date in a piece of text, in the order they come, in the formats `firstDate(in:)` reads.
  static func dates(in text: String) -> [String] {
    foundDates(in: text).map(\.day)
  }

  struct FoundDate {
    var day: String
    /// Read with two digits for its year (taken as 20yy).
    var shortYear: Bool
  }

  private static let month = #"([a-zäéûç]{3,9})\.?(?:\s*/\s*[a-zäéûç]{3,9}\.?)?"#

  // NSRegularExpression matches from any thread.
  nonisolated(unsafe) private static let datePatterns: [(NSRegularExpression, Bool, ([Substring]) -> String?)] = {
    func monthName(_ name: Substring) -> Int? { months[String(name)] }
    let patterns: [(String, Bool, ([Substring]) -> String?)] = [
      (#"(\d{4})-(\d{1,2})-(\d{1,2})"#, false, { DocumentDay.string(year: Int($0[0])!, month: Int($0[1])!, day: Int($0[2])!) }),
      (#"(\d{1,2})[./](\d{1,2})[./](\d{4})"#, false, { DocumentDay.string(year: Int($0[2])!, month: Int($0[1])!, day: Int($0[0])!) }),
      (#"(?<![\d.])(\d{1,2}) (\d{1,2}) (\d{4})\b"#, false, { DocumentDay.string(year: Int($0[2])!, month: Int($0[1])!, day: Int($0[0])!) }),
      (#"(\d{1,2})[./](\d{1,2})[./](\d{2})\b"#, true, { DocumentDay.string(year: 2000 + Int($0[2])!, month: Int($0[1])!, day: Int($0[0])!) }),
      (#"(\d{1,2})\.?\s+"# + month + #"\s+(\d{4})"#, false, { parts in
        monthName(parts[1]).flatMap { DocumentDay.string(year: Int(parts[2])!, month: $0, day: Int(parts[0])!) }
      }),
      (#"(\d{1,2})\.?\s+"# + month + #"\s+(\d{2})\b"#, true, { parts in
        monthName(parts[1]).flatMap { DocumentDay.string(year: 2000 + Int(parts[2])!, month: $0, day: Int(parts[0])!) }
      }),
      (#"([a-zäéûç]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})"#, false, { parts in
        monthName(parts[0]).flatMap { DocumentDay.string(year: Int(parts[2])!, month: $0, day: Int(parts[1])!) }
      }),
    ]
    return patterns.compactMap { pattern, short, make in
      (try? NSRegularExpression(pattern: pattern)).map { ($0, short, make) }
    }
  }()

  /// Every date in a piece of text, with whether its year had two digits.
  static func foundDates(in text: String) -> [FoundDate] {
    let lower = text.lowercased()
    var found: [(range: NSRange, date: FoundDate)] = []
    for (regex, short, make) in datePatterns {
      let range = NSRange(lower.startIndex..., in: lower)
      for match in regex.matches(in: lower, range: range) {
        let groups = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: lower).map { lower[$0] } }
        guard groups.count == match.numberOfRanges - 1, let day = make(groups) else { continue }
        // One date read by two patterns (12.03.2032 is also 12.03.20) counts once, as the earlier pattern read it.
        if found.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) { continue }
        found.append((match.range, FoundDate(day: day, shortYear: short)))
      }
    }
    return found.sorted { $0.range.location < $1.range.location }.map(\.date)
  }

  /// A country's name for its ICAO code ("JPN" → "Japan"), or the code when the system doesn't know it.
  static func countryName(_ code: String) -> String? {
    guard !code.isEmpty else { return nil }
    let alpha2: [String: String] = [
      "JPN": "JP", "DEU": "DE", "D": "DE", "GBR": "GB", "USA": "US", "FRA": "FR", "ITA": "IT", "ESP": "ES", "NLD": "NL",
      "AUT": "AT", "CHE": "CH", "POL": "PL", "UKR": "UA", "CAN": "CA", "AUS": "AU", "CHN": "CN", "KOR": "KR", "IND": "IN",
      "BRA": "BR", "SWE": "SE", "NOR": "NO", "DNK": "DK", "FIN": "FI", "IRL": "IE", "PRT": "PT", "BEL": "BE", "CZE": "CZ",
      "TUR": "TR", "RUS": "RU", "KAZ": "KZ", "GRC": "GR", "HUN": "HU", "ROU": "RO", "MEX": "MX", "NZL": "NZ",
    ]
    if let two = alpha2[code], let name = Locale(identifier: "en_US").localizedString(forRegionCode: two) { return name }
    return code
  }
}
