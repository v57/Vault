import ComponentKit
import PlatformScan
import SwiftUI
import VaultKit

/// The demo vault's documents (boards 01–04): the Tanakas' passports, permits, resumes, policies, the lease and a
/// warranty, with pages drawn here so the viewer, the machine-readable zone and Find on pages work. Dates are
/// relative to today, so Coming Up always has something in it.
@MainActor
enum DemoDocuments {
  static func seed(_ store: VaultStore) throws {
    try store.addDefaultDocumentCollections()
    let aiko = VaultHolder(name: "Aiko Tanaka", color: "purple", order: 0)
    let kenji = VaultHolder(name: "Kenji Tanaka", color: "teal", order: 1)
    let hana = VaultHolder(name: "Hana Tanaka", color: "pink", order: 2)
    for person in [aiko, kenji, hana] { try store.save(person) }

    var order = 0
    func add(
      _ kind: DocumentKind, title: String = "", holder: VaultHolder? = nil, collection: String? = nil,
      fields: [String: String], secrets: [String: String] = [:], tags: Set<String> = [], notes: String = "",
      created: Date, pages: [AnyView], copies: [VaultDocument.SharedCopy] = []
    ) throws -> VaultDocument {
      var document = VaultDocument(
        title: title, kind: kind.id, collection: collection ?? kind.collection, holder: holder?.id ?? "",
        fields: fields, tags: tags, notes: notes, order: order, created: created)
      order += 1
      let images = pages.compactMap { render($0, aspectRatio: kind.aspectRatio) }
      document.thumbnail = images.first.flatMap { PageScanner.thumbnail(of: $0.data, maxPixel: 480)?.data }
      document.text = text(of: fields, title: title)
      try store.save(document)
      for (key, value) in secrets { try store.setDocumentSecret(value, key: key, document: document.id) }
      for (index, image) in images.enumerated() {
        let side = kind.sides.indices.contains(index) ? kind.sides[index] : "Page \(index + 1)"
        try store.addFile(
          VaultDocumentFile(
            document: document.id, name: side, contentType: "image/jpeg", data: image.data, width: image.width,
            height: image.height, pageCount: 1, text: ""))
      }
      for copy in copies { try store.noteSharedCopy(copy, document: document.id) }
      return document
    }

    // Identity.
    let passportNumber = "TR1029384"
    let expires = date(days: 74)
    let zone = passportZone(
      surname: "TANAKA", given: "AIKO", number: passportNumber, nationality: "JPN", birth: (1990, 4, 12), sex: "F",
      expires: expires)
    let passport = try add(
      .passport, holder: aiko,
      fields: [
        "name": "Aiko Tanaka", "country": "Japan", "birthDate": "1990-04-12",
        "issued": DocumentDay.string(from: date(days: 74 - 3_652)), "expires": DocumentDay.string(from: expires),
      ],
      secrets: ["number": passportNumber], tags: ["travel"], notes: "The original is in the desk’s top drawer.",
      created: date(days: -420),
      pages: [AnyView(PassportPage(name: "TANAKA / AIKO", number: passportNumber, birth: "12 APR 1990", expires: expires, zone: zone, tint: .red)), AnyView(CoverPage(title: "JAPAN", subtitle: "PASSPORT", tint: .red))],
      copies: [.init(purpose: "Wohnbau GmbH, rental application", date: date(days: -38), pages: 1, hidden: ["MRZ"])])
    _ = try add(
      .passport, holder: hana,
      fields: [
        "name": "Hana Tanaka", "country": "Japan", "birthDate": "2019-08-03",
        "issued": DocumentDay.string(from: date(days: -380)), "expires": DocumentDay.string(from: date(days: 1_446)),
      ],
      secrets: ["number": "TS5520918"], tags: ["travel"], created: date(days: -380),
      pages: [AnyView(PassportPage(name: "TANAKA / HANA", number: "TS5520918", birth: "03 AUG 2019", expires: date(days: 1_446), zone: passportZone(surname: "TANAKA", given: "HANA", number: "TS5520918", nationality: "JPN", birth: (2019, 8, 3), sex: "F", expires: date(days: 1_446)), tint: .red))])
    _ = try add(
      .residencePermit, holder: aiko,
      fields: [
        "name": "Aiko Tanaka", "country": "Germany", "permit": "EU Blue Card",
        "issued": DocumentDay.string(from: date(days: -700)), "expires": DocumentDay.string(from: date(days: 395)),
      ],
      secrets: ["number": "Y4KT92C61"], created: date(days: -700),
      pages: [AnyView(CardPage(title: "AUFENTHALTSTITEL", lines: ["TANAKA, AIKO", "EU Blue Card", "Y4KT92C61"], tint: .green))])
    _ = try add(
      .driversLicence, holder: kenji,
      fields: [
        "name": "Kenji Tanaka", "country": "Germany", "classes": "B, AM",
        "issued": DocumentDay.string(from: date(days: -1_800)), "expires": DocumentDay.string(from: date(days: 1_850)),
      ],
      secrets: ["number": "B072RRE2I55"], created: date(days: -600),
      pages: [AnyView(CardPage(title: "FÜHRERSCHEIN", lines: ["TANAKA", "KENJI", "B, AM"], tint: .pink))])

    // Work: one resume per kind of job.
    _ = try add(
      .resume, title: "Resume – Product design", holder: aiko,
      fields: ["name": "Aiko Tanaka", "role": "Product designer", "updated": DocumentDay.string(from: date(days: -12))],
      tags: ["jobs"], created: date(days: -12),
      pages: [AnyView(LetterPage(title: "Aiko Tanaka", subtitle: "Product designer · Berlin", lines: ["Atlas GmbH, Lead designer, 2022–", "Field Notes, Designer, 2018–2022", "Offline maps, design systems, research"]))])
    _ = try add(
      .resume, title: "Resume – Engineering manager", holder: aiko,
      fields: ["name": "Aiko Tanaka", "role": "Engineering manager", "updated": DocumentDay.string(from: date(days: -40))],
      tags: ["jobs"], created: date(days: -40),
      pages: [AnyView(LetterPage(title: "Aiko Tanaka", subtitle: "Engineering manager · Berlin", lines: ["Atlas GmbH, Team lead, 2022–", "Hiring, planning, delivery of 6 teams", "Swift, Postgres, design systems"]))])
    _ = try add(
      .employmentContract, holder: aiko,
      fields: ["employer": "Atlas GmbH", "role": "Lead designer", "starts": DocumentDay.string(from: date(days: -1_100)), "notice": "3 months"],
      created: date(days: -1_100),
      pages: [AnyView(LetterPage(title: "Arbeitsvertrag", subtitle: "Atlas GmbH · Aiko Tanaka", lines: ["§1 Beginn des Arbeitsverhältnisses", "§2 Tätigkeit: Lead designer", "§9 Kündigungsfrist: 3 Monate"]))])

    // Insurance.
    _ = try add(
      .insurancePolicy, title: "Health insurance", holder: aiko,
      fields: [
        "insurer": "Techniker Krankenkasse", "policyNumber": "T 482 991 302", "insured": "Aiko, Kenji, Hana",
        "premium": "€ 412 / month", "renews": DocumentDay.string(from: date(days: 40)), "notice": "2 months",
      ],
      created: date(days: -300),
      pages: [AnyView(LetterPage(title: "Versicherungsschein", subtitle: "Techniker Krankenkasse", lines: ["Versicherungsnummer T 482 991 302", "Versicherte: Aiko, Kenji, Hana Tanaka", "Beitrag € 412 monatlich"]))])
    _ = try add(
      .insurancePolicy, title: "Home contents",
      fields: [
        "insurer": "Allianz", "policyNumber": "HR-22-90418", "cover": "€ 65 000", "premium": "€ 9.80 / month",
        "renews": DocumentDay.string(from: date(days: 210)), "notice": "3 months",
      ],
      created: date(days: -520),
      pages: [AnyView(LetterPage(title: "Hausratversicherung", subtitle: "Allianz · HR-22-90418", lines: ["Versicherungssumme € 65 000", "Beitrag € 9,80 monatlich", "Kündigungsfrist 3 Monate"]))])

    // Cards & Banking.
    _ = try add(
      .paymentCard, title: "Personal Mastercard", holder: aiko,
      fields: ["issuer": "N26", "last4": "9012", "expires": DocumentDay.string(from: date(days: 140))],
      created: date(days: -900),
      pages: [AnyView(CardPage(title: "N26", lines: ["•••• •••• •••• 9012", "AIKO TANAKA"], tint: .gray))])

    // House.
    _ = try add(
      .lease, holder: aiko,
      fields: [
        "landlord": "Wohnbau GmbH", "address": "Lychener Str. 18, Berlin", "rent": "€ 1 480", "deposit": "€ 4 440",
        "starts": DocumentDay.string(from: date(days: -30)), "notice": "3 months",
      ],
      tags: ["home"], created: date(days: -45),
      pages: [
        AnyView(LetterPage(title: "Mietvertrag", subtitle: "Wohnbau GmbH · Lychener Str. 18", lines: ["Miete € 1 480 warm", "Kaution € 4 440", "Kündigungsfrist 3 Monate"])),
        AnyView(LetterPage(title: "Anlage 1", subtitle: "Hausordnung", lines: ["Ruhezeiten 22–6 Uhr", "Mülltrennung", "Fahrräder im Hof"])),
      ])
    _ = try add(
      .warranty, title: "MacBook Air", holder: kenji,
      fields: ["shop": "Gravis", "amount": "€ 1 299", "bought": DocumentDay.string(from: date(days: -530)), "warrantyUntil": DocumentDay.string(from: date(days: 200))],
      tags: ["warranty"], created: date(days: -530),
      pages: [AnyView(LetterPage(title: "Rechnung", subtitle: "Gravis · MacBook Air 13″", lines: ["1 × MacBook Air 13″ € 1 299", "Garantie 24 Monate", "Rechnungsnummer 2025-11-4471"]))])

    // Car.
    _ = try add(
      .vehicleRegistration, holder: kenji,
      fields: ["plate": "B-KT 4417", "inspection": DocumentDay.string(from: date(days: 25))],
      secrets: [:], created: date(days: -1_000),
      pages: [AnyView(CardPage(title: "ZULASSUNGSBESCHEINIGUNG", lines: ["B-KT 4417", "Teil I"], tint: .green))])

    // Not filed yet: shared from Mail, not read yet; the app reads it when it starts.
    let dated = date(days: -4).formatted(Date.FormatStyle().day(.twoDigits).month(.twoDigits).year())
    let letter = LetterPage(
      title: "Nebenkostenabrechnung", subtitle: "Wohnbau GmbH",
      lines: ["Datum: \(dated)", "Abrechnungszeitraum 2025", "Nachzahlung € 128,40", "Fällig in 30 Tagen"])
    if let page = render(AnyView(letter), aspectRatio: DocumentKind.other.aspectRatio) {
      try store.addSharedFiles(
        [SharedFile(name: "Scan 5 Nov", contentType: page.contentType, data: page.data, width: page.width, height: page.height)],
        now: date(days: -2))
    }

    // The passport links to the logins it's used with.
    if let login = try store.records(VaultLogin.self).first(where: { $0.title == "Apple Developer" }) {
      try store.save(id: passport.id, kind: VaultDocument.kind, changes: ["link.\(login.id)": .bool(true)])
    }
  }

  // MARK: Helpers

  private static func date(days: Int) -> Date {
    (Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: .now)) ?? .now)
      .addingTimeInterval(12 * 3600)
  }

  private static func text(of fields: [String: String], title: String) -> String {
    ([title] + fields.values.sorted()).filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func render(_ view: AnyView, aspectRatio: CGFloat) -> PageImage? {
    let width: CGFloat = aspectRatio > 1 ? 1_100 : 900
    let renderer = ImageRenderer(content: view.frame(width: width, height: width / aspectRatio).background(Color.white).environment(\.colorScheme, .light))
    renderer.scale = 1.4
    return renderer.cgImage.flatMap { PageScanner.page(from: $0) }
  }

  /// A TD3 zone with the right check digits.
  private static func passportZone(
    surname: String, given: String, number: String, nationality: String, birth: (Int, Int, Int), sex: String,
    expires: Date
  ) -> [String] {
    func pad(_ text: String, _ count: Int) -> String { (text + String(repeating: "<", count: count)).prefix(count).description }
    func yymmdd(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%02d%02d%02d", y % 100, m, d) }
    let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: expires)
    let birthText = yymmdd(birth.0, birth.1, birth.2)
    let expiresText = yymmdd(parts.year ?? 2030, parts.month ?? 1, parts.day ?? 1)
    let line1 = pad("P<\(nationality)\(surname)<<\(given)", 44)
    let numberField = pad(number, 9)
    let personal = pad("", 14)
    let check = MachineReadableZone.checkDigit
    var line2 = numberField + "\(check(numberField))" + nationality + birthText + "\(check(birthText))" + sex
    line2 += expiresText + "\(check(expiresText))" + personal + "\(check(personal))"
    let composite = numberField + "\(check(numberField))" + birthText + "\(check(birthText))" + expiresText
      + "\(check(expiresText))" + personal + "\(check(personal))"
    line2 += "\(check(composite))"
    return [line1, line2]
  }
}

// MARK: - Drawn pages

/// A passport's data page: the photo, the fields and the zone, set large enough to read back.
private struct PassportPage: View {
  var name: String
  var number: String
  var birth: String
  var expires: Date
  var zone: [String]
  var tint: Color

  var body: some View {
    let expiry = expires.formatted(.dateTime.day(.twoDigits).month(.abbreviated).year().locale(Locale(identifier: "en_GB"))).uppercased()
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("PASSPORT  ·  JAPAN").font(.system(size: 26, weight: .bold))
        Spacer()
        Text("P  JPN").font(.system(size: 24, weight: .semibold, design: .monospaced))
      }
      .padding(.bottom, 26)
      HStack(alignment: .top, spacing: 36) {
        RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.25))
          .overlay(Image(systemName: "person.fill").font(.system(size: 120)).foregroundStyle(tint.opacity(0.6)))
          .frame(width: 230, height: 290)
        VStack(alignment: .leading, spacing: 14) {
          field("Surname / Given names", name)
          field("Passport No.", number)
          field("Date of birth", birth)
          field("Date of expiry", expiry)
        }
        Spacer(minLength: 0)
      }
      Spacer(minLength: 20)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(zone, id: \.self) { line in
          Text(line).font(.system(size: 30, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.5)
        }
      }
    }
    .foregroundStyle(.black)
    .padding(44)
    .background(LinearGradient(colors: [Color(white: 0.97), tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
  }

  private func field(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.system(size: 16)).foregroundStyle(.black.opacity(0.55))
      Text(value).font(.system(size: 30, weight: .semibold))
    }
  }
}

/// A passport's cover.
private struct CoverPage: View {
  var title: String
  var subtitle: String
  var tint: Color

  var body: some View {
    VStack(spacing: 20) {
      Text(title).font(.system(size: 52, weight: .bold))
      Image(systemName: "sun.max").font(.system(size: 120, weight: .light))
      Text(subtitle).font(.system(size: 40, weight: .semibold))
    }
    .foregroundStyle(Color(red: 0.92, green: 0.78, blue: 0.42))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(tint.opacity(0.45)).background(Color.black)
  }
}

/// An ID-1 card: a title band and a few lines.
private struct CardPage: View {
  var title: String
  var lines: [String]
  var tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.system(size: 34, weight: .bold))
      Spacer()
      ForEach(lines, id: \.self) { line in Text(line).font(.system(size: 40, weight: .semibold, design: .monospaced)) }
    }
    .foregroundStyle(.black)
    .padding(48)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(LinearGradient(colors: [tint.opacity(0.18), Color(white: 0.96)], startPoint: .topLeading, endPoint: .bottomTrailing))
  }
}

/// An A4 letter: a heading, a subtitle and some lines of text.
private struct LetterPage: View {
  var title: String
  var subtitle: String
  var lines: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(title).font(.system(size: 46, weight: .bold))
      Text(subtitle).font(.system(size: 26)).foregroundStyle(.black.opacity(0.6))
      Rectangle().fill(.black.opacity(0.15)).frame(height: 2).padding(.vertical, 10)
      ForEach(lines, id: \.self) { line in Text(line).font(.system(size: 26)) }
      ForEach(0..<9, id: \.self) { index in
        RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.08))
          .frame(width: [640, 700, 560, 690, 610, 420, 680, 590, 300][index], height: 14)
      }
      Spacer()
    }
    .foregroundStyle(.black)
    .padding(70)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.white)
  }
}
