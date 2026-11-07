import Foundation
import Testing

@testable import VaultKit

struct DocumentStoreTests {
  let keys = MemoryKeyProvider()

  init() { VaultSecrets.useInMemoryStore() }

  func makeStore(_ device: String = "mac") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  @Test func sharedFilesWaitInTheInboxToBeRead() throws {
    let store = try makeStore()
    let front = SharedFile(name: "IMG_1", contentType: "image/jpeg", data: Data([1]), width: 10, height: 6, thumbnail: Data([9]))
    let back = SharedFile(name: "IMG_2", contentType: "image/jpeg", data: Data([2]), width: 10, height: 6)
    let policy = SharedFile(name: "Policy", contentType: "application/pdf", data: Data([3]), pageCount: 4)
    let receipt = SharedFile(name: "Receipt", contentType: "image/png", data: Data([4]))

    let documents = try store.addSharedFiles([front, back, policy, receipt])
    #expect(documents.map(\.title) == ["IMG_1", "Policy", "Receipt"])
    #expect(documents.allSatisfy { $0.needsReading && $0.collection.isEmpty && $0.kind == DocumentKind.other.id })
    #expect(documents[0].thumbnail == Data([9]))
    #expect(try store.files(of: documents[0]).map(\.data) == [Data([1]), Data([2])])
    #expect(try store.files(of: documents[1]).map(\.pageCount) == [4])

    // Read: the flag goes, and is gone on the record.
    var read = documents[0]
    read.needsReading = false
    try store.save(read)
    #expect(try store.record(VaultDocument.self, id: read.id)?.needsReading == false)
    #expect(try store.record(VaultDocument.self, id: documents[1].id)?.needsReading == true)
  }

  @Test func documentRoundTrips() throws {
    let store = try makeStore()
    var document = VaultDocument(
      title: "Aiko's Passport", kind: DocumentKind.passport.id, collection: DocumentCollectionID.identity,
      holder: "h1", fields: ["name": "Aiko Tanaka", "expires": "2032-03-12"], tags: ["travel"], remindMonths: 6,
      notes: "Renew at the embassy")
    document.text = "PASSPORT JAPAN"
    document.thumbnail = Data([1, 2, 3])
    try store.save(document)

    let read = try #require(try store.record(VaultDocument.self, id: document.id))
    #expect(read.title == "Aiko's Passport")
    #expect(read.kind == "passport")
    #expect(read.fields == ["name": "Aiko Tanaka", "expires": "2032-03-12"])
    #expect(read.tags == ["travel"])
    #expect(read.remindMonths == 6)
    #expect(read.text == "PASSPORT JAPAN")
    #expect(read.thumbnail == Data([1, 2, 3]))
    #expect(read.day("expires") == DocumentDay.date(from: "2032-03-12"))

    // A removed field is cleared; one this build doesn't know stays.
    try store.save(id: document.id, kind: VaultDocument.kind, changes: ["future.thing": .string("kept")])
    var edited = read
    edited.fields["expires"] = nil
    edited.tags = []
    try store.save(edited)
    let again = try #require(try store.record(VaultDocument.self, id: document.id))
    #expect(again.fields == ["name": "Aiko Tanaka"])
    #expect(again.tags.isEmpty)
    #expect(try store.item(id: document.id)?.values["future.thing"] == .string("kept"))
  }

  @Test func pagesAreKeptOutsideTheDocument() throws {
    let store = try makeStore()
    let document = VaultDocument(title: "Lease", kind: DocumentKind.lease.id)
    try store.save(document)
    let stale = try #require(try store.record(VaultDocument.self, id: document.id))

    let first = VaultDocumentFile(document: document.id, name: "Page 1", data: Data(repeating: 1, count: 64), width: 10, height: 14)
    let second = VaultDocumentFile(document: document.id, contentType: "application/pdf", data: Data([2]), pageCount: 3)
    try store.addFile(first)
    try store.addFile(second)

    // Saving a copy loaded before the pages were added keeps them.
    var edited = stale
    edited.title = "Flat lease"
    try store.save(edited)

    let read = try #require(try store.record(VaultDocument.self, id: document.id))
    #expect(read.title == "Flat lease")
    #expect(read.fileIDs == [first.id, second.id])
    let files = try store.files(of: read)
    #expect(files.map(\.name) == ["Page 1", ""])
    #expect(files[0].data == Data(repeating: 1, count: 64))
    #expect(files[1].isPDF && files[1].pageCount == 3)

    try store.reorderFiles([second.id, first.id], in: document.id)
    #expect(try store.record(VaultDocument.self, id: document.id)?.fileIDs == [second.id, first.id])

    try store.deleteFile(id: second.id, from: document.id)
    #expect(try store.record(VaultDocument.self, id: document.id)?.fileIDs == [first.id])
    #expect(try store.record(VaultDocumentFile.self, id: second.id) == nil)
  }

  @Test func secretFieldsLiveInSecrets() throws {
    let store = try makeStore()
    let document = VaultDocument(kind: DocumentKind.passport.id)
    try store.save(document)
    try store.setDocumentSecret(" TR4821 ", key: "number", document: document.id)

    let read = try #require(try store.record(VaultDocument.self, id: document.id))
    #expect(read.secrets == ["number"])
    #expect(read.secret("number") == "TR4821")
    #expect(read.fields["number"] == nil)
    #expect(try store.item(id: document.id)?.values.values.contains(.string("TR4821")) == false)

    try store.setDocumentSecret("", key: "number", document: document.id)
    let cleared = try #require(try store.record(VaultDocument.self, id: document.id))
    #expect(cleared.secrets.isEmpty)
    #expect(cleared.secret("number") == nil)
  }

  @Test func deletingRemovesFilesAndSecrets() throws {
    let store = try makeStore()
    let document = VaultDocument(kind: DocumentKind.bankDocument.id)
    try store.save(document)
    let file = VaultDocumentFile(document: document.id, data: Data([9]))
    try store.addFile(file)
    try store.setDocumentSecret("DE89 3704", key: "iban", document: document.id)

    try store.deleteDocument(id: document.id)
    #expect(try store.record(VaultDocument.self, id: document.id) == nil)
    #expect(try store.record(VaultDocumentFile.self, id: file.id) == nil)
    #expect(VaultSecrets.secretText(VaultDocument.secretName("iban", document: document.id)) == nil)
  }

  @Test func duplicateCopiesEverythingButSharedCopies() throws {
    let store = try makeStore()
    let resume = VaultDocument(
      title: "Resume — iOS Engineer", kind: DocumentKind.resume.id, collection: DocumentCollectionID.work,
      fields: ["role": "iOS Engineer"], tags: ["2026"])
    try store.save(resume)
    try store.addFile(VaultDocumentFile(document: resume.id, data: Data([1])))
    try store.addFile(VaultDocumentFile(document: resume.id, data: Data([2])))
    try store.setDocumentSecret("secret", key: "number", document: resume.id)
    try store.noteSharedCopy(.init(purpose: "Acme application", pages: 2), document: resume.id)
    #expect(try store.record(VaultDocument.self, id: resume.id)?.copies.count == 1)

    let copy = try #require(try store.duplicateDocument(id: resume.id, title: "Resume — Team Lead"))
    #expect(copy.id != resume.id)
    #expect(copy.title == "Resume — Team Lead")
    #expect(copy.fields == ["role": "iOS Engineer"])
    #expect(copy.tags == ["2026"])
    #expect(copy.copies.isEmpty)
    #expect(copy.secret("number") == "secret")
    let files = try store.files(of: copy)
    #expect(files.map(\.data) == [Data([1]), Data([2])])
    #expect(files.allSatisfy { $0.document == copy.id })
    // The original keeps its own pages.
    let original = try #require(try store.record(VaultDocument.self, id: resume.id))
    #expect(Set(original.fileIDs).isDisjoint(with: copy.fileIDs))
  }

  @Test func defaultCollectionsAreAddedOnce() throws {
    let store = try makeStore()
    try store.addDefaultDocumentCollections()
    let collections = try store.records(VaultDocumentCollection.self)
    #expect(collections.count == VaultDocumentCollection.defaults.count)
    #expect(collections.first { $0.id == DocumentCollectionID.identity }?.locked == true)

    // One the user deleted stays deleted.
    try store.delete(id: DocumentCollectionID.car)
    try store.addDefaultDocumentCollections()
    #expect(try store.records(VaultDocumentCollection.self).count == VaultDocumentCollection.defaults.count - 1)
  }

  @Test func customKindsRoundTrip() throws {
    let store = try makeStore()
    let kind = VaultDocumentKind(
      name: "Pet Passport", symbol: "doc", collection: DocumentCollectionID.other,
      fields: [DocumentField("chip", "Chip number"), DocumentField("rabies", "Rabies shot", .date, reminds: true)],
      remindMonths: 1)
    try store.save(kind)
    let read = try #require(try store.record(VaultDocumentKind.self, id: kind.id))
    #expect(read.fields == kind.fields)
    let kinds = DocumentKinds(custom: [read])
    #expect(kinds[kind.id].isCustom)
    #expect(kinds[kind.id].remindingField?.key == "rabies")
    #expect(kinds["passport"].name == "Passport")
    #expect(kinds["gone"].fields.isEmpty)
  }

  @Test func holderInitials() {
    #expect(VaultHolder(name: "Aiko Tanaka").initials == "AT")
    #expect(VaultHolder(name: "Ken").initials == "K")
  }
}

struct DocumentReminderTests {
  let now = DocumentDay.date(from: "2026-11-07")!

  @Test func passportRemindsMonthsBefore() {
    let passport = VaultDocument(kind: DocumentKind.passport.id, fields: ["expires": "2027-06-01"])
    let events = passport.events(kind: .passport)
    #expect(events.count == 1)
    #expect(events[0].remindOn == DocumentDay.date(from: "2026-09-01"))
    // The reminder went off, so it's coming up though the date is more than 90 days away.
    #expect(DocumentReminders.comingUp([passport], kinds: DocumentKinds(), now: now).map(\.document) == [passport.id])
  }

  @Test func reminderOffOrNoDate() {
    let off = VaultDocument(kind: DocumentKind.passport.id, fields: ["expires": "2027-01-01"], remindMonths: 0)
    let empty = VaultDocument(kind: DocumentKind.passport.id)
    #expect(off.events(kind: .passport).isEmpty)
    #expect(empty.events(kind: .passport).isEmpty)
  }

  @Test func noticeDeadlineComesFirst() {
    let policy = VaultDocument(
      kind: DocumentKind.insurancePolicy.id, fields: ["renews": "2027-02-01", "notice": "3 months"])
    let events = policy.events(kind: .insurancePolicy)
    #expect(events.map(\.kind) == [.due, .notice])
    #expect(events[1].date == DocumentDay.date(from: "2026-11-01"))
    #expect(events[1].label == "Notice by")
    // The deadline passed a few days ago: the renewal is what's next.
    let next = DocumentReminders.comingUp([policy], kinds: DocumentKinds(), now: now)
    #expect(next.map(\.kind) == [.due])
    let earlier = DocumentDay.date(from: "2026-10-20")!
    #expect(DocumentReminders.comingUp([policy], kinds: DocumentKinds(), now: earlier).map(\.kind) == [.notice])
  }

  @Test func comingUpIsSortedAndDropsOldDates() {
    let soon = VaultDocument(kind: DocumentKind.warranty.id, fields: ["warrantyUntil": "2026-11-20"])
    let later = VaultDocument(kind: DocumentKind.idCard.id, fields: ["expires": "2027-01-15"])
    let longGone = VaultDocument(kind: DocumentKind.idCard.id, fields: ["expires": "2026-01-01"])
    let farOff = VaultDocument(kind: DocumentKind.idCard.id, fields: ["expires": "2030-01-01"])
    let expiredLastWeek = VaultDocument(kind: DocumentKind.idCard.id, fields: ["expires": "2026-11-01"])
    let result = DocumentReminders.comingUp([later, longGone, farOff, soon, expiredLastWeek], kinds: DocumentKinds(), now: now)
    #expect(result.map(\.document) == [expiredLastWeek.id, soon.id, later.id])
  }

  @Test func upcomingListsRemindersStillToGoOff() {
    let policy = VaultDocument(
      kind: DocumentKind.insurancePolicy.id, fields: ["renews": "2027-06-01", "notice": "1"])
    let result = DocumentReminders.upcoming([policy], kinds: DocumentKinds(), now: now)
    #expect(result.map(\.kind) == [.notice, .due])
  }
}

struct MachineReadableZoneTests {
  @Test func fillersOCRDroppedInsideTheNumberLineArePutBack() throws {
    // Vision reads a zone's long filler runs as pieces and drops a filler between them.
    let zone = try #require(MachineReadableZone(text: [
      "P<JPNTANAKA<<AIK0<<<<<<<", "TR10293849JPN9004126F2701194<<<<<<<<<<<<<04",
    ]))
    #expect(zone.isValid)
    #expect(zone.number == "TR1029384")
    #expect(zone.surname == "TANAKA")
    #expect(zone.givenNames == "AIKO")
  }

  @Test func passportFromICAOSample() throws {
    let zone = try #require(
      MachineReadableZone(text: [
        "Some header text",
        "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
        "L898902C36UTO7408122F1204159ZE184226B<<<<<10",
      ]))
    #expect(zone.format == .td3)
    #expect(zone.isPassport)
    #expect(zone.issuer == "UTO")
    #expect(zone.surname == "ERIKSSON")
    #expect(zone.givenNames == "ANNA MARIA")
    #expect(zone.fullName == "Anna Maria Eriksson")
    #expect(zone.number == "L898902C3")
    #expect(zone.nationality == "UTO")
    #expect(zone.birthDate == "1974-08-12")
    #expect(zone.sex == "F")
    #expect(zone.expires == "2012-04-15")
    #expect(zone.isValid)
  }

  @Test func ocrSlipsAreCorrected() throws {
    let zone = try #require(
      MachineReadableZone(text: [
        "P<UTOERIKSSON«ANNA<MARIA<<<<<<<<<<<<<<<<",
        "L898902C36 UTO74O8122F12O4159ZE184226B<<<<<10",
      ]))
    #expect(zone.surname == "ERIKSSON")
    #expect(zone.birthDate == "1974-08-12")
    #expect(zone.expires == "2012-04-15")
    #expect(zone.isValid)
  }

  @Test func idCardFromICAOSample() throws {
    let zone = try #require(
      MachineReadableZone(text: [
        "I<UTOD231458907<<<<<<<<<<<<<<<",
        "7408122F1204159UTO<<<<<<<<<<<6",
        "ERIKSSON<<ANNA<MARIA<<<<<<<<<<",
      ]))
    #expect(zone.format == .td1)
    #expect(!zone.isPassport)
    #expect(zone.number == "D23145890")
    #expect(zone.fullName == "Anna Maria Eriksson")
    #expect(zone.expires == "2012-04-15")
    #expect(zone.isValid)
  }

  @Test func wrongDigitIsNotValid() throws {
    let zone = try #require(
      MachineReadableZone(text: [
        "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
        "L898902C36UTO7408122F1204159ZE184226B<<<<<19",
      ]))
    #expect(!zone.isValid)
  }

  @Test func checkDigits() {
    #expect(MachineReadableZone.checkDigit("L898902C3") == 6)
    #expect(MachineReadableZone.checkDigit("740812") == 2)
    #expect(MachineReadableZone.checkDigit("120415") == 9)
  }

  @Test func centuries() {
    let now = DocumentDay.date(from: "2026-11-07")!
    #expect(MachineReadableZone.day("990101", future: false, now: now) == "1999-01-01")
    #expect(MachineReadableZone.day("100101", future: false, now: now) == "2010-01-01")
    #expect(MachineReadableZone.day("320312", future: true, now: now) == "2032-03-12")
  }

  @Test func plainTextHasNoZone() {
    #expect(MachineReadableZone(text: ["Mietvertrag", "zwischen Herrn Müller und Frau Tanaka"]) == nil)
  }
}

struct DocumentReaderTests {
  @Test func kindWordsStartAWord() {
    #expect(DocumentReader.guessKind("nebenkostenabrechnung\nnachzahlung € 128,40") == DocumentKind.other.id)
    #expect(DocumentReader.guessKind("rechnung nr. 2025-11-4471") == DocumentKind.warranty.id)
    #expect(DocumentReader.guessKind("ihre gehaltsabrechnung") == DocumentKind.payslip.id)
  }

  @Test func passportZoneFillsFields() {
    let suggestion = DocumentReader.suggest(pages: [[
      "PASSPORT", "Date of issue 15 APR 2007",
      "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
      "L898902C36UTO7408122F1204159ZE184226B<<<<<10",
    ]])
    #expect(suggestion.kind == "passport")
    #expect(suggestion.zone != nil)
    #expect(suggestion.fields["name"] == "Anna Maria Eriksson")
    #expect(suggestion.fields["number"] == "L898902C3")
    #expect(suggestion.fields["expires"] == "2012-04-15")
    #expect(suggestion.fields["issued"] == "2007-04-15")
    #expect(suggestion.fields["country"] == "UTO")
  }

  @Test func germanLicenceByNumberedFields() {
    let suggestion = DocumentReader.suggest(pages: [[
      "FÜHRERSCHEIN", "1. TANAKA", "2. AIKO", "4a. 12.03.2019", "4b. 11.03.2034", "5. B072RRE2I55", "9. AM/B/L",
    ]])
    #expect(suggestion.kind == "driversLicence")
    #expect(suggestion.fields["issued"] == "2019-03-12")
    #expect(suggestion.fields["expires"] == "2034-03-11")
    #expect(suggestion.fields["number"] == "B072RRE2I55")
    #expect(suggestion.fields["classes"] == "AM/B/L")
  }

  @Test func insurancePolicyNumberAndRenewal() {
    let suggestion = DocumentReader.suggest(pages: [
      ["Versicherungsschein", "Hausratversicherung"],
      ["Versicherungsnummer: HR-2231-77", "Hauptfälligkeit", "01.02.2027"],
    ])
    #expect(suggestion.kind == "insurancePolicy")
    #expect(suggestion.fields["policyNumber"] == "HR-2231-77")
    #expect(suggestion.fields["renews"] == "2027-02-01")
  }

  @Test func kindsFromWords() {
    #expect(DocumentReader.guessKind("curriculum vitae\nwork experience") == "resume")
    #expect(DocumentReader.guessKind("mietvertrag über wohnraum") == "lease")
    #expect(DocumentReader.guessKind("kassenbon") == "warranty")
    #expect(DocumentReader.guessKind("grocery list") == "other")
  }

  @Test func dateFormats() {
    #expect(DocumentReader.firstDate(in: "valid until 12.03.2032") == "2032-03-12")
    #expect(DocumentReader.firstDate(in: "2032-03-12") == "2032-03-12")
    #expect(DocumentReader.firstDate(in: "12 MAR/MARS 2032") == "2032-03-12")
    #expect(DocumentReader.firstDate(in: "March 12, 2032") == "2032-03-12")
    #expect(DocumentReader.firstDate(in: "12. März 2032") == "2032-03-12")
    #expect(DocumentReader.firstDate(in: "from 01/02/2026 to 31.12.2026") == "2026-02-01")
    #expect(DocumentReader.firstDate(in: "31.02.2026") == nil)
    #expect(DocumentReader.firstDate(in: "no date here") == nil)
  }
}
