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
  public static func suggest(pages: [[String]]) -> DocumentSuggestion {
    let lines = pages.flatMap { $0 }
    if let zone = MachineReadableZone(text: lines) { return suggestion(for: zone, lines: lines) }
    let text = lines.joined(separator: "\n").lowercased()
    let kind = guessKind(text)
    var fields: [String: String] = [:]
    let known = DocumentKinds()[kind]
    for (key, labels) in labelledDates where known.field(key) != nil {
      if let day = date(after: labels, in: lines) { fields[key] = day }
    }
    if kind == DocumentKind.driversLicence.id {
      // EU licences number their fields: 4a issued, 4b expires, 5 the licence number, 9 the classes.
      if fields["issued"] == nil, let day = date(after: ["4a."], in: lines) { fields["issued"] = day }
      if fields["expires"] == nil, let day = date(after: ["4b."], in: lines) { fields["expires"] = day }
      if let number = value(after: ["5."], in: lines) { fields["number"] = number }
      if let classes = value(after: ["9."], in: lines) { fields["classes"] = classes }
    }
    if kind == DocumentKind.insurancePolicy.id, let number = value(after: policyLabels, in: lines) {
      fields["policyNumber"] = number
    }
    return DocumentSuggestion(kind: kind, fields: fields)
  }

  private static func suggestion(for zone: MachineReadableZone, lines: [String]) -> DocumentSuggestion {
    let kind: String
    if zone.isPassport {
      kind = DocumentKind.passport.id
    } else if zone.documentCode.count > 1 && "RT".contains(zone.documentCode.last!) {
      kind = DocumentKind.residencePermit.id
    } else {
      let text = lines.joined(separator: " ").lowercased()
      kind = ["aufenthalt", "residence", "titre de séjour", "permesso"].contains(where: text.contains)
        ? DocumentKind.residencePermit.id : DocumentKind.idCard.id
    }
    var fields: [String: String] = ["name": zone.fullName, "number": zone.number]
    if let country = countryName(zone.nationality.isEmpty ? zone.issuer : zone.nationality) { fields["country"] = country }
    if let birth = zone.birthDate { fields["birthDate"] = birth }
    if let expires = zone.expires { fields["expires"] = expires }
    if let issued = date(after: labelledDates.first { $0.key == "issued" }!.labels, in: lines) { fields["issued"] = issued }
    return DocumentSuggestion(kind: kind, fields: fields.filter { !$0.value.isEmpty }, zone: zone)
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
    ("expires", ["date of expiry", "expiry", "expires", "valid until", "gültig bis", "ablaufdatum", "date d'expiration"]),
    ("issued", ["date of issue", "issued", "ausstellungsdatum", "ausgestellt am", "date de délivrance"]),
    ("birthDate", ["date of birth", "geburtsdatum", "born", "date de naissance"]),
    ("renews", ["renewal date", "renews", "hauptfälligkeit", "verlängert sich", "next renewal"]),
    ("starts", ["start date", "begins", "beginn", "commencement", "vertragsbeginn", "mietbeginn"]),
    ("bought", ["date of purchase", "purchase date", "kaufdatum", "datum"]),
    ("warrantyUntil", ["warranty until", "garantie bis"]),
    ("dated", ["date", "datum"]),
  ]

  static let policyLabels = ["policy number", "policy no", "versicherungsnummer", "vertragsnummer", "versicherungsschein-nr"]

  /// The first date on the line of a label, or on the line after it.
  static func date(after labels: [String], in lines: [String]) -> String? {
    for (index, line) in lines.enumerated() {
      let lower = line.lowercased()
      // Lowercasing can change a line's length (İ, ẞ, ligatures), so the label is found in the line itself.
      guard let label = labels.first(where: lower.contains),
        let range = line.range(of: label, options: [.caseInsensitive, .diacriticInsensitive])
      else { continue }
      let rest = String(line[range.upperBound...])
      if let day = firstDate(in: rest) { return day }
      if index + 1 < lines.count, let day = firstDate(in: lines[index + 1]) { return day }
    }
    return nil
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
    let names = [
      ["jan", "january", "januar", "janvier"], ["feb", "february", "februar", "février", "fev"],
      ["mar", "march", "märz", "mars", "mär"], ["apr", "april", "avril"], ["may", "mai"], ["jun", "june", "juni", "juin"],
      ["jul", "july", "juli", "juillet"], ["aug", "august", "août"], ["sep", "sept", "september", "septembre"],
      ["oct", "october", "okt", "oktober", "octobre"], ["nov", "november", "novembre"],
      ["dec", "december", "dez", "dezember", "décembre"],
    ]
    for (index, list) in names.enumerated() { for name in list { map[name] = index + 1 } }
    return map
  }()

  /// The first date in a piece of text: 12.03.2032, 12/03/2032, 2032-03-12, 12 MAR 2032 (or 12 MAR/MARS 2032),
  /// March 12, 2032. Day before month where it's ambiguous, as on European and ICAO documents.
  public static func firstDate(in text: String) -> String? {
    let lower = text.lowercased()
    let patterns: [(String, ([Substring]) -> String?)] = [
      (#"(\d{4})-(\d{1,2})-(\d{1,2})"#, { DocumentDay.string(year: Int($0[0])!, month: Int($0[1])!, day: Int($0[2])!) }),
      (#"(\d{1,2})[./](\d{1,2})[./](\d{4})"#, { DocumentDay.string(year: Int($0[2])!, month: Int($0[1])!, day: Int($0[0])!) }),
      (#"(\d{1,2})[./](\d{1,2})[./](\d{2})\b"#, { DocumentDay.string(year: 2000 + Int($0[2])!, month: Int($0[1])!, day: Int($0[0])!) }),
      (#"(\d{1,2})\.?\s+([a-zäéû]{3,9})(?:/[a-zäéû]{3,9})?\.?\s+(\d{4})"#, { parts in
        months[String(parts[1])].flatMap { DocumentDay.string(year: Int(parts[2])!, month: $0, day: Int(parts[0])!) }
      }),
      (#"([a-zäéû]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})"#, { parts in
        months[String(parts[0])].flatMap { DocumentDay.string(year: Int(parts[2])!, month: $0, day: Int(parts[1])!) }
      }),
    ]
    var best: (offset: Int, day: String)?
    for (pattern, make) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(lower.startIndex..., in: lower)
      for match in regex.matches(in: lower, range: range) {
        let groups = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: lower).map { lower[$0] } }
        guard groups.count == match.numberOfRanges - 1, let day = make(groups) else { continue }
        if best == nil || match.range.location < best!.offset { best = (match.range.location, day) }
        break
      }
    }
    return best?.day
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
