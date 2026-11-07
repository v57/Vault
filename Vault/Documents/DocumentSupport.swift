import ComponentKit
import Foundation
import PlatformScan
import SwiftUI
import VaultKit

/// What the Documents screen lists besides a collection.
enum DocumentScope {
  static let all = "all"
  /// Documents not filed yet (no collection): from the share sheet, Open in Vault, or saved without one.
  static let inbox = "inbox"
}

// MARK: - Looks

/// The kinds' and collections' symbol names as SF Symbols.
enum DocumentSymbol {
  static func image(_ symbol: String) -> String {
    switch symbol {
    case "passport": "person.text.rectangle"
    case "id": "person.crop.rectangle"
    case "work": "briefcase"
    case "umbrella": "umbrella"
    case "card": "creditcard"
    case "house": "house"
    case "car": "car"
    case "receipt": "receipt"
    case "heart": "heart"
    case "tag": "tag"
    default: "doc.text"
    }
  }
}

extension Hue {
  /// A collection's or holder's colour name ("teal") as a hue; gray when it isn't one.
  init(colorName: String) {
    self = Hue(rawValue: colorName) ?? .gray
  }
}

extension DocumentKind {
  /// The page's shape, width over height: ID-1 cards, a passport's data page, A4.
  var aspectRatio: CGFloat {
    switch id {
    case DocumentKind.idCard.id, DocumentKind.driversLicence.id, DocumentKind.residencePermit.id,
      DocumentKind.paymentCard.id, DocumentKind.vehicleRegistration.id:
      1.586
    case DocumentKind.passport.id: 1.42
    default: 0.707
    }
  }
}

/// "1 document", "3 documents".
func counted(_ count: Int, _ word: String, plural: String? = nil) -> String {
  count == 1 ? "1 \(word)" : "\(count) \(plural ?? word + "s")"
}

/// Days as the screens write them.
enum DocumentDates {
  /// Days are kept at noon UTC; written in UTC they read the same everywhere.
  private static let utc = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!)

  /// "Mar 12, 2032".
  static func long(_ date: Date) -> String {
    date.formatted(Self.utc.month(.abbreviated).day().year())
  }

  /// "Jan 2027" or "2032" (a year away or more).
  static func short(_ date: Date, now: Date = .now) -> String {
    DocumentDay.days(from: now, to: date) > 365
      ? date.formatted(Self.utc.year())
      : date.formatted(Self.utc.month(.abbreviated).year())
  }

  /// "74 days", "tomorrow", "today", "5 days ago".
  static func left(_ date: Date, now: Date = .now) -> String {
    let days = DocumentDay.days(from: now, to: date)
    switch days {
    case 0: return String(localized: "today")
    case 1: return String(localized: "tomorrow")
    case -1: return String(localized: "yesterday")
    case ..<0: return String(localized: "\(-days) days ago")
    default: return String(localized: "\(days) days")
    }
  }
}

extension VaultDocument {
  /// A field's value as the inspector shows it: dates written out, months counted; nil when empty.
  func shown(_ field: DocumentField) -> String? {
    guard let value = fields[field.key], !value.isEmpty else { return nil }
    switch field.format {
    case .date: return DocumentDay.date(from: value).map(DocumentDates.long) ?? value
    case .months:
      let months = Self.monthCount(value) ?? 0
      return months == 1 ? "1 month" : "\(months) months"
    default: return value
    }
  }

  static func monthCount(_ text: String) -> Int? {
    Int(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
  }
}

extension Vault {
  /// The documents in a scope: every one, the inbox's, or a collection's.
  func documents(in scope: String) -> [VaultDocument] {
    switch scope {
    case DocumentScope.all: documents
    case DocumentScope.inbox: documents.filter { document in document.collection.isEmpty || !documentCollections.contains { $0.id == document.collection } }
    default: documents.filter { $0.collection == scope }
    }
  }

  func holder(id: String) -> VaultHolder? { holders.first { $0.id == id } }

  func collection(id: String) -> VaultDocumentCollection? { documentCollections.first { $0.id == id } }

  /// What's coming up in the next 90 days, soonest first.
  var documentEvents: [DocumentEvent] { DocumentReminders.comingUp(documents, kinds: documentKinds) }
}

extension PageTextLine {
  /// A line of a machine-readable zone: long, with fillers; a passport's name line may come back short, as OCR often
  /// stops reading the fillers after the names.
  var looksLikeZone: Bool {
    let text = self.text.replacingOccurrences(of: " ", with: "")
    let fillers = text.filter { "<«‹".contains($0) }.count
    return fillers >= 3 && (text.count >= 28 || (text.hasPrefix("P") && text.count >= 12 && text.contains("<<")))
  }
}

// MARK: - Pages on their way in

/// One page or file about to be added: its bytes, what was read on it, and for a photo the page's corners.
struct IncomingPage: Identifiable, Hashable {
  var id = UUID().uuidString
  var name: String
  var data: Data
  var contentType: String
  var width: Int
  var height: Int
  var pageCount: Int
  /// The lines read on it (a PDF's text layer, or recognized on the device).
  var lines: [String]
  /// A photo's page corners, 0...1 from the top left; nil for a scan or a PDF, which are flat already.
  var corners: [CGPoint]?
  /// A preview to draw (a PDF's first page as a picture).
  var preview: Data

  var isPDF: Bool { contentType == "application/pdf" }
  var aspectRatio: CGFloat { height > 0 ? CGFloat(width) / CGFloat(height) : 0.707 }
}

/// Add Document's pages and what reading them suggested, kept on the model so a scan, a drop or Open in Vault can
/// fill it before the sheet shows.
struct DocumentImport {
  var pages: [IncomingPage] = []
  var suggestion: DocumentSuggestion?
  var isReading = false
  var problem: String?
  /// The document new pages go to (Add Page on an existing one).
  var target: String?
}

/// Reads files, photos and scans into `IncomingPage`s on the device.
enum PageReader {
  /// A file the user picked, dropped or opened in Vault.
  static func page(from url: URL) async throws -> IncomingPage {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let data = try Data(contentsOf: url)
    return try await page(data: data, name: url.deletingPathExtension().lastPathComponent, isScan: false)
  }

  /// Bytes from a scan (already straightened: `isScan`), a photo or a file.
  static func page(data: Data, name: String, isScan: Bool) async throws -> IncomingPage {
    guard data.count <= VaultDocumentFile.maximumSize else {
      throw PageReadError("“\(name)” is over \(VaultDocumentFile.maximumSize / 1_048_576) MB.")
    }
    if PDFPages.isPDF(data) {
      guard let count = PDFPages.pageCount(data) else { throw PageReadError("“\(name)” is a PDF this device can't open.") }
      let size = PDFPages.pageSize(data) ?? (595, 842)
      let preview = PDFPages.render(data, page: 0, maxPixel: 1600)?.data ?? Data()
      var lines = PDFPages.text(data).prefix(6).flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
      if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        // A scanned PDF: read its first pages' pictures.
        lines = []
        for page in 0..<min(count, 3) {
          if let image = PDFPages.render(data, page: page, maxPixel: 2400) {
            lines += (try? await PageScanner.text(in: image.data)) ?? []
          }
        }
      }
      return IncomingPage(
        name: name, data: data, contentType: "application/pdf", width: Int(size.width), height: Int(size.height),
        pageCount: count, lines: lines, corners: nil, preview: preview)
    }
    guard let size = PageScanner.pixelSize(of: data) else { throw PageReadError("“\(name)” isn't a picture or a PDF.") }
    var corners: [CGPoint]?
    if !isScan, let quad = try? await PageScanner.edges(in: data), !isWholeImage(quad) {
      corners = quad.corners.map { CGPoint(x: $0.x, y: $0.y) }
    }
    // A photo is read straightened, so lines come out level.
    let readable = corners == nil ? data : (try? PageScanner.straighten(data, quad: quad(corners!), maxPixel: 2400).data) ?? data
    let lines = (try? await PageScanner.text(in: readable)) ?? []
    let contentType = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : data.starts(with: [0xFF, 0xD8]) ? "image/jpeg" : "image/heic"
    return IncomingPage(
      name: name, data: data, contentType: contentType, width: size.width, height: size.height, pageCount: 1,
      lines: lines, corners: corners, preview: data)
  }

  static func quad(_ corners: [CGPoint]) -> PageQuad {
    let points = corners.map { PagePoint(x: $0.x, y: $0.y) }
    return PageQuad(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
  }

  private static func isWholeImage(_ quad: PageQuad) -> Bool {
    zip(quad.corners, PageQuad.full.corners).allSatisfy { abs($0.x - $1.x) < 0.03 && abs($0.y - $1.y) < 0.03 }
  }

  /// The page as it will be stored: a photo straightened to its corners in `look`; a scan or PDF as it came.
  static func finished(_ page: IncomingPage, look: PageLook) throws -> (data: Data, contentType: String, width: Int, height: Int) {
    if page.isPDF { return (page.data, page.contentType, page.width, page.height) }
    if page.corners == nil, look == .color, page.contentType == "image/jpeg" {
      return (page.data, page.contentType, page.width, page.height)
    }
    let image = try PageScanner.straighten(page.data, quad: page.corners.map(quad) ?? .full, look: look)
    return (image.data, image.contentType, image.width, image.height)
  }
}

struct PageReadError: Error, LocalizedError {
  var message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

extension AppModel {
  /// Add Document with no pages yet: its drop area, Scan and Choose Files.
  func newDocument() {
    documentImport = DocumentImport()
    if !(selection.map { if case .documents = $0 { true } else { false } } ?? false) {
      selection = .documents(DocumentScope.all)
    }
    sheet = .addDocument
  }

  /// Reads files into Add Document (Import, a drop, Open in Vault) and shows it.
  func importDocuments(_ urls: [URL], into target: String? = nil) {
    guard !urls.isEmpty else { return }
    read(target: target) { try await urls.asyncMap(PageReader.page(from:)) }
  }

  /// Adds pages the document camera took, or pictures and PDFs from Continuity Camera or a drop.
  func importScans(_ images: [Data], names: [String]? = nil, isScan: Bool = true, into target: String? = nil) {
    guard !images.isEmpty else { return }
    read(target: target) {
      var pages: [IncomingPage] = []
      for (index, data) in images.enumerated() {
        pages.append(try await PageReader.page(data: data, name: names?[index] ?? "Page \(index + 1)", isScan: isScan))
      }
      return pages
    }
  }

  private func read(target: String?, _ load: @escaping () async throws -> [IncomingPage]) {
    if documentImport.target != target || sheet != .addDocument { documentImport = DocumentImport(target: target) }
    documentImport.isReading = true
    documentImport.problem = nil
    if selection == nil || !(selection.map { if case .documents = $0 { true } else { false } } ?? false) {
      selection = .documents(DocumentScope.all)
    }
    if let target {
      sheet = .editDocument(target)
    } else {
      sheet = .addDocument
    }
    Task {
      do {
        let pages = try await load()
        documentImport.pages += pages
        documentImport.suggestion = DocumentReader.suggest(pages: documentImport.pages.map(\.lines))
      } catch {
        documentImport.problem = error.localizedDescription
      }
      documentImport.isReading = false
    }
  }

  /// Reads the pages of documents shared from other apps (`needsReading`): the kind, the fields, the text for
  /// search and a thumbnail, as Add Document would suggest them. They stay in the Inbox for the user to file.
  func readSharedDocuments() async {
    guard let store = vault.store else { return }
    for document in vault.documents where document.needsReading && !readingDocuments.contains(document.id) {
      readingDocuments.insert(document.id)
      defer { readingDocuments.remove(document.id) }
      let files = (try? store.files(of: document)) ?? []
      var pages: [IncomingPage] = []
      for file in files.prefix(4) {
        if let page = try? await PageReader.page(data: file.data, name: file.name, isScan: true) { pages.append(page) }
      }
      // Changed elsewhere while reading: start from the record as it is now.
      guard var current = vault.documents.first(where: { $0.id == document.id }), current.needsReading else { continue }
      let suggestion = DocumentReader.suggest(pages: pages.map(\.lines))
      var secrets: [String: String] = [:]
      if current.kind == DocumentKind.other.id, suggestion.kind != DocumentKind.other.id {
        current.kind = suggestion.kind
        // The file's name until the pages give a better one ("Aiko's Passport"); a camera roll name goes.
        if !suggestion.title.isEmpty || current.title.hasPrefix("IMG_") { current.title = suggestion.title }
      }
      let kind = vault.documentKinds[current.kind]
      for (key, value) in suggestion.fields {
        guard let field = kind.field(key) else { continue }
        if field.format == .secret {
          if !current.secrets.contains(key) { secrets[key] = value }
        } else if (current.fields[key] ?? "").isEmpty {
          current.fields[key] = value
        }
      }
      if current.holder.isEmpty, let holder = holder(named: suggestion.fields["name"]) { current.holder = holder }
      if current.thumbnail == nil, let first = pages.first {
        current.thumbnail = PageScanner.thumbnail(of: first.preview, maxPixel: 480)?.data
      }
      let text = pages.map { $0.lines.joined(separator: "\n") }.joined(separator: "\n")
      current.text = String(([current.text, text].filter { !$0.isEmpty }.joined(separator: "\n")).prefix(20_000))
      current.needsReading = false
      let read = current
      vault.perform { store in
        try store.save(read)
        for (key, value) in secrets { try store.setDocumentSecret(value, key: key, document: read.id) }
      }
    }
  }

  /// The person whose name the pages carry ("Aiko Tanaka" for AIKO TANAKA), when there's one.
  func holder(named name: String?) -> String? {
    guard let name = name?.lowercased(), !name.isEmpty else { return nil }
    return vault.holders.first { person in
      person.name.lowercased().split(separator: " ").allSatisfy { name.contains($0) }
    }?.id
  }

  /// Saves a new document, or new pages and fields on an existing one, with its pages finished in `look`.
  func saveDocument(_ document: VaultDocument, secrets: [String: String], look: PageLook) throws {
    let pages = documentImport.pages
    var document = document
    var finished: [(IncomingPage, (data: Data, contentType: String, width: Int, height: Int))] = []
    for page in pages { finished.append((page, try PageReader.finished(page, look: look))) }
    let firstPicture = finished.first.map { page, done in page.isPDF ? page.preview : done.data }
    if document.thumbnail == nil, let first = firstPicture {
      document.thumbnail = PageScanner.thumbnail(of: first, maxPixel: 480)?.data
    }
    let text = ([document.text] + pages.map { $0.lines.joined(separator: "\n") }).filter { !$0.isEmpty }
      .joined(separator: "\n")
    document.text = String(text.prefix(20_000))
    vault.perform { store in
      try store.save(document)
      for (key, value) in secrets { try store.setDocumentSecret(value, key: key, document: document.id) }
      for (page, done) in finished {
        try store.addFile(
          VaultDocumentFile(
            document: document.id, name: page.name, contentType: done.contentType, data: done.data,
            width: done.width, height: done.height, pageCount: page.pageCount,
            text: page.lines.joined(separator: "\n")))
      }
    }
    documentImport = DocumentImport()
    selectedDocument = document.id
  }
}

extension Array {
  func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var result: [T] = []
    for element in self { result.append(try await transform(element)) }
    return result
  }
}
