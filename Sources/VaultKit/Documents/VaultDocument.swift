import Foundation

/// A document: a passport, a resume, an insurance policy, a lease. Its pages are `VaultDocumentFile` records (one
/// per scanned page or imported file), listed in `files` by id so the list of documents never loads them; a small
/// picture of the first page (`thumbnail`) is kept on the record for lists.
///
/// The kind (`DocumentKinds`) says which fields it has. Plain fields are `field.<key>` text; a day is
/// "yyyy-MM-dd" (`DocumentDay`). Fields the kind marks secret (a passport number, an IBAN) are `VaultSecrets` items
/// (`document.<key>.<id>`), readable only in Vault; the record keeps `secret.<key>` to say one is set. The text read
/// from the pages and the thumbnail carry those values too, so they're sealed (`DocumentSeal`) and read as empty
/// outside Vault.
///
/// Every version is its own document: people keep a resume per kind of job, and a renewed passport is a new one.
/// Tags, links, files and copies shared are one field each so two devices editing at once both keep theirs.
/// `files`, `secrets` and `copies` are written only by the store's helpers (`addFile`, `setDocumentSecret`,
/// `noteSharedCopy`), never by saving the record, so a copy loaded before a page was added can't drop it.
public struct VaultDocument: VaultRecord, Hashable {
  public static let kind = "document"
  public static let dynamicPrefixes = ["field.", "tag.", "link."]

  public var id: String
  public var title: String
  /// A `DocumentKind` id ("passport") or a `VaultDocumentKind` record's id.
  public var kind: String
  /// A `VaultDocumentCollection` id; empty while the document waits in Inbox.
  public var collection: String
  /// A `VaultHolder` id, empty for nobody in particular.
  public var holder: String
  public var fields: [String: String]
  /// Keys of the secret fields that have a value.
  public private(set) var secrets: Set<String>
  public var tags: Set<String>
  /// Ids of linked items: logins, cards, other documents.
  public var links: Set<String>
  /// File ids with their place in the document (lower first).
  public private(set) var files: [String: Double]
  /// Months before the reminding date: nil uses the kind's, 0 turns the reminder off.
  public var remindMonths: Int?
  public var notes: String
  /// The text read from the pages, for search.
  public var text: String
  /// A JPEG of the first page, about 240 points on its long side.
  public var thumbnail: Data?
  /// Saved without reading its pages (shared from another app): the app reads them, suggests a kind and fields,
  /// and turns this off.
  public var needsReading: Bool
  public private(set) var copies: [String: SharedCopy]
  public var order: Int
  public var created: Date?

  /// A copy given out (Share a Copy): what for, when, and what was left out.
  public struct SharedCopy: Hashable, Sendable {
    public var purpose: String
    public var date: Date
    public var pages: Int
    /// Labels of the fields left out ("Passport number", "Machine-readable zone").
    public var hidden: [String]
    public var watermark: Bool

    public init(purpose: String, date: Date = .now, pages: Int, hidden: [String] = [], watermark: Bool = true) {
      self.purpose = purpose
      self.date = date.wholeSeconds
      self.pages = pages
      self.hidden = hidden
      self.watermark = watermark
    }

    init?(_ value: JSONValue) {
      guard let object = value.objectValue else { return nil }
      let read = FieldReader(object)
      purpose = read.string("purpose", default: "")
      date = read.date("date") ?? .distantPast
      pages = read.int("pages", default: 1)
      hidden = object["hidden"]?.arrayValue?.compactMap(\.stringValue) ?? []
      watermark = read.bool("watermark", default: true)
    }

    var value: JSONValue {
      .object([
        "purpose": .string(purpose), "date": .init(date), "pages": .init(pages),
        "hidden": .array(hidden.map(JSONValue.string)), "watermark": .bool(watermark),
      ])
    }
  }

  public init(
    id: String = UUID().uuidString, title: String = "", kind: String = DocumentKind.other.id, collection: String = "",
    holder: String = "", fields: [String: String] = [:], tags: Set<String> = [], links: Set<String> = [],
    remindMonths: Int? = nil, notes: String = "", order: Int = 0, created: Date? = .now
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.collection = collection
    self.holder = holder
    self.fields = fields
    secrets = []
    self.tags = tags
    self.links = links
    files = [:]
    self.remindMonths = remindMonths
    self.notes = notes
    text = ""
    thumbnail = nil
    needsReading = false
    copies = [:]
    self.order = order
    self.created = created?.wholeSeconds
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    title = read.string("title", default: "")
    kind = read.string("kind", default: DocumentKind.other.id)
    collection = read.string("collection", default: "")
    holder = read.string("holder", default: "")
    fields = read.strings(prefixed: "field")
    secrets = Set(read.flags(prefixed: "secret"))
    tags = Set(read.flags(prefixed: "tag"))
    links = Set(read.flags(prefixed: "link"))
    var files: [String: Double] = [:]
    for (key, value) in values where key.hasPrefix("file.") {
      if let place = value.doubleValue { files[String(key.dropFirst(5))] = place }
    }
    self.files = files
    remindMonths = read.int("remindMonths")
    notes = read.string("notes", default: "")
    text = DocumentSeal.read("text", from: values).map { String(decoding: $0, as: UTF8.self) }
      ?? read.string("text", default: "")
    thumbnail = DocumentSeal.read("thumbnail", from: values) ?? read.data("thumbnail")
    needsReading = read.bool("unread")
    var copies: [String: SharedCopy] = [:]
    for (key, value) in values where key.hasPrefix("copy.") {
      if let copy = SharedCopy(value) { copies[String(key.dropFirst(5))] = copy }
    }
    self.copies = copies
    order = read.int("order", default: 0)
    created = read.date("created")
  }

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "title": .string(title), "kind": .string(kind), "collection": .string(collection), "holder": .string(holder),
      "remindMonths": .init(remindMonths), "notes": .string(notes), "unread": needsReading ? .bool(true) : .null,
      "order": .init(order), "created": .init(created),
    ]
    DocumentSeal.write(Data(text.utf8), as: "text", into: &values)
    DocumentSeal.write(thumbnail, as: "thumbnail", into: &values)
    values.set(fields.filter { !$0.value.isEmpty }, prefixed: "field")
    for tag in tags { values["tag.\(tag)"] = .bool(true) }
    for link in links { values["link.\(link)"] = .bool(true) }
    return values
  }

  /// The file ids in page order.
  public var fileIDs: [String] { files.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key) }

  /// The title if given, else the kind's name.
  public func displayName(kinds: DocumentKinds) -> String { title.isEmpty ? kinds[kind].name : title }

  /// A day field ("expires") as a date at noon UTC, nil when empty or unreadable.
  public func day(_ key: String) -> Date? { fields[key].flatMap(DocumentDay.date(from:)) }

  /// The `VaultSecrets` name of a secret field's value.
  public static func secretName(_ key: String, document id: String) -> String { "document.\(key).\(id)" }

  public func secret(_ key: String) -> String? { VaultSecrets.secretText(Self.secretName(key, document: id)) }
}

/// A day without a time ("2032-03-12"), the way document dates are kept: a passport expires on a day, wherever
/// you are.
public enum DocumentDay {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// "yyyy-MM-dd" for a date's day in UTC.
  public static func string(from date: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  public static func string(year: Int, month: Int, day: Int) -> String? {
    guard (1...12).contains(month), (1...31).contains(day), let date = date(year: year, month: month, day: day),
      calendar.component(.day, from: date) == day
    else { return nil }
    return string(from: date)
  }

  /// The day at noon UTC.
  public static func date(from text: String) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return date(year: parts[0], month: parts[1], day: parts[2])
  }

  static func date(year: Int, month: Int, day: Int) -> Date? {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
  }

  /// The day `months` months before (negative: after).
  public static func date(_ date: Date, monthsBefore months: Int) -> Date {
    calendar.date(byAdding: .month, value: -months, to: date) ?? date
  }

  /// Whole days from one day to another (negative when it's before).
  public static func days(from start: Date, to end: Date) -> Int {
    let a = calendar.startOfDay(for: start)
    let b = calendar.startOfDay(for: end)
    return calendar.dateComponents([.day], from: a, to: b).day ?? 0
  }
}

/// One page or attached file of a document: a scanned page (JPEG), a photo, or an imported PDF. The text read from
/// it is kept for search. Files over `maximumSize` aren't kept.
public struct VaultDocumentFile: VaultRecord, Hashable {
  public static let kind = "documentFile"
  public static let maximumSize = 25 * 1024 * 1024

  public var id: String
  public var document: String
  /// "Policy schedule", "Front"; empty for an unnamed page.
  public var name: String
  /// "image/jpeg", "image/png", "image/heic" or "application/pdf".
  public var contentType: String
  public var data: Data
  /// The image's size in pixels, or a PDF's first page in points.
  public var width: Int
  public var height: Int
  /// Pages in a PDF, 1 for an image.
  public var pageCount: Int
  public var text: String
  public var created: Date?

  public init(
    id: String = UUID().uuidString, document: String, name: String = "", contentType: String = "image/jpeg",
    data: Data, width: Int = 0, height: Int = 0, pageCount: Int = 1, text: String = "", created: Date? = .now
  ) {
    self.id = id
    self.document = document
    self.name = name
    self.contentType = contentType
    self.data = data
    self.width = width
    self.height = height
    self.pageCount = pageCount
    self.text = text
    self.created = created?.wholeSeconds
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    document = read.string("document", default: "")
    name = read.string("name", default: "")
    contentType = read.string("contentType", default: "image/jpeg")
    data = DocumentSeal.read("data", from: values) ?? read.data("data") ?? Data()
    width = read.int("width", default: 0)
    height = read.int("height", default: 0)
    pageCount = read.int("pageCount", default: 1)
    text = DocumentSeal.read("text", from: values).map { String(decoding: $0, as: UTF8.self) }
      ?? read.string("text", default: "")
    created = read.date("created")
  }

  public var values: [String: JSONValue] {
    // The page and its text are sealed (`DocumentSeal`): a scan shows everything the secret fields keep.
    var values: [String: JSONValue] = [
      "document": .string(document), "name": .string(name), "contentType": .string(contentType),
      "width": .init(width), "height": .init(height), "pageCount": .init(pageCount), "created": .init(created),
    ]
    DocumentSeal.write(data, as: "data", into: &values)
    DocumentSeal.write(Data(text.utf8), as: "text", into: &values)
    return values
  }

  public var isPDF: Bool { contentType == "application/pdf" }
}

/// Where documents are filed: Identity, Work, Insurance, House, or one of the user's own.
public struct VaultDocumentCollection: VaultRecord, Hashable {
  public static let kind = "documentCollection"

  public var id: String
  public var name: String
  public var symbol: String
  /// A kit colour name ("blue", "teal").
  public var color: String
  public var order: Int
  /// Opening its documents asks for Touch ID or Face ID again.
  public var locked: Bool

  public init(
    id: String = UUID().uuidString, name: String, symbol: String = "doc", color: String = "gray", order: Int = 0,
    locked: Bool = false
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.color = color
    self.order = order
    self.locked = locked
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "Collection")
    symbol = read.string("symbol", default: "doc")
    color = read.string("color", default: "gray")
    order = read.int("order", default: 0)
    locked = read.bool("locked")
  }

  public var values: [String: JSONValue] {
    [
      "name": .string(name), "symbol": .string(symbol), "color": .string(color), "order": .init(order),
      "locked": .bool(locked),
    ]
  }

  /// The collections a vault starts with, under fixed ids.
  public static let defaults: [VaultDocumentCollection] = [
    .init(id: DocumentCollectionID.identity, name: "Identity", symbol: "id", color: "blue", order: 0, locked: true),
    .init(id: DocumentCollectionID.work, name: "Work", symbol: "work", color: "indigo", order: 1),
    .init(id: DocumentCollectionID.insurance, name: "Insurance", symbol: "umbrella", color: "teal", order: 2),
    .init(id: DocumentCollectionID.banking, name: "Cards & Banking", symbol: "card", color: "green", order: 3),
    .init(id: DocumentCollectionID.house, name: "House", symbol: "house", color: "orange", order: 4),
    .init(id: DocumentCollectionID.car, name: "Car", symbol: "car", color: "red", order: 5),
    .init(id: DocumentCollectionID.other, name: "Other", symbol: "tag", color: "gray", order: 6),
  ]

  /// Collections Settings offers to add.
  public static let suggestions: [VaultDocumentCollection] = [
    .init(name: "Health", symbol: "heart", color: "pink"), .init(name: "Taxes", symbol: "doc", color: "brown"),
    .init(name: "Pets", symbol: "tag", color: "yellow"), .init(name: "School", symbol: "work", color: "purple"),
  ]
}

/// A file shared from another app, as `VaultStore.addSharedFiles` takes it.
public struct SharedFile: Sendable, Hashable {
  public var name: String
  public var contentType: String
  public var data: Data
  public var width: Int
  public var height: Int
  public var pageCount: Int
  /// A small JPEG of its first page, when the sharing side could make one.
  public var thumbnail: Data?

  public init(
    name: String, contentType: String, data: Data, width: Int = 0, height: Int = 0, pageCount: Int = 1,
    thumbnail: Data? = nil
  ) {
    self.name = name
    self.contentType = contentType
    self.data = data
    self.width = width
    self.height = height
    self.pageCount = pageCount
    self.thumbnail = thumbnail
  }

  public var isPDF: Bool { contentType == "application/pdf" }
}

/// Whose a document is: a person in the household, with or without a device of their own (a child has a passport
/// but no keys). Not the address book and not the people folders are shared with.
public struct VaultHolder: VaultRecord, Hashable {
  public static let kind = "holder"

  public var id: String
  public var name: String
  public var color: String
  public var order: Int

  public init(id: String = UUID().uuidString, name: String, color: String = "purple", order: Int = 0) {
    self.id = id
    self.name = name
    self.color = color
    self.order = order
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    color = read.string("color", default: "purple")
    order = read.int("order", default: 0)
  }

  public var values: [String: JSONValue] { ["name": .string(name), "color": .string(color), "order": .init(order)] }

  /// "AT" for Aiko Tanaka, "A" for Aiko.
  public var initials: String {
    let words = name.split(separator: " ")
    return String(words.prefix(2).compactMap(\.first)).uppercased()
  }
}

extension VaultStore {
  /// Adds the collections a vault starts with, except any this vault already has or had (one the user deleted
  /// stays deleted).
  public func addDefaultDocumentCollections() throws {
    for collection in VaultDocumentCollection.defaults where try item(id: collection.id) == nil {
      try save(collection)
    }
  }

  /// A document's files in page order (each loaded on its own: the list of documents never reads them).
  public func files(of document: VaultDocument) throws -> [VaultDocumentFile] {
    try document.fileIDs.compactMap { try record(VaultDocumentFile.self, id: $0) }
  }

  /// Saves a file and adds it to its document after the last page (or at `place`).
  public func addFile(_ file: VaultDocumentFile, place: Double? = nil) throws {
    try save(file)
    let document = try record(VaultDocument.self, id: file.document)
    let last = document?.files.values.max() ?? 0
    try save(id: file.document, kind: VaultDocument.kind, changes: ["file.\(file.id)": .double(place ?? last + 1)])
  }

  /// Files shared from another app (the share sheet), saved to the Inbox without reading them: pictures shared
  /// together are one document's pages (a card's front and back), each PDF is a document of its own. The app reads
  /// them later (`needsReading`). Returns the documents in the order the files came.
  @discardableResult
  public func addSharedFiles(_ files: [SharedFile], now: Date = .now) throws -> [VaultDocument] {
    var groups: [[SharedFile]] = []
    for file in files {
      if !file.isPDF, let last = groups.last, last.allSatisfy({ !$0.isPDF }) {
        groups[groups.count - 1].append(file)
      } else {
        groups.append([file])
      }
    }
    let order = (try records(VaultDocument.self).map(\.order).max() ?? -1) + 1
    var documents: [VaultDocument] = []
    for (index, group) in groups.enumerated() {
      var document = VaultDocument(title: group[0].name, order: order + index, created: now)
      document.needsReading = true
      document.thumbnail = group[0].thumbnail
      try save(document)
      for file in group {
        try addFile(VaultDocumentFile(
          document: document.id, name: file.name, contentType: file.contentType, data: file.data, width: file.width,
          height: file.height, pageCount: file.pageCount, created: now))
      }
      documents.append(try record(VaultDocument.self, id: document.id) ?? document)
    }
    return documents
  }

  /// Removes a file from its document and deletes it.
  public func deleteFile(id: String, from document: String) throws {
    try save(id: document, kind: VaultDocument.kind, changes: ["file.\(id)": .null])
    try delete(id: id)
  }

  /// Puts a document's files in this order.
  public func reorderFiles(_ ids: [String], in document: String) throws {
    var changes: [String: JSONValue] = [:]
    for (index, id) in ids.enumerated() { changes["file.\(id)"] = .double(Double(index + 1)) }
    try save(id: document, kind: VaultDocument.kind, changes: changes)
  }

  /// Saves a secret field's value (nil or empty removes it) and marks it set on the record.
  public func setDocumentSecret(_ value: String?, key: String, document id: String) throws {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    let isSet = !(value ?? "").isEmpty
    try VaultSecrets.setSecretText(isSet ? value : nil, named: VaultDocument.secretName(key, document: id))
    try save(id: id, kind: VaultDocument.kind, changes: ["secret.\(key)": isSet ? .bool(true) : .null])
  }

  /// Notes a copy given out under Copies Shared.
  public func noteSharedCopy(_ copy: VaultDocument.SharedCopy, document id: String) throws {
    try save(id: id, kind: VaultDocument.kind, changes: ["copy.\(UUID().uuidString)": copy.value])
  }

  /// Deletes a document, its files and its secret fields.
  public func deleteDocument(id: String) throws {
    guard let document = try record(VaultDocument.self, id: id) else { return try delete(id: id) }
    for file in document.fileIDs { try delete(id: file) }
    for key in document.secrets { try VaultSecrets.setSecret(nil, named: VaultDocument.secretName(key, document: id)) }
    try delete(id: id)
  }

  /// A copy of a document with its fields, secrets, tags and files: the next resume, or next year's policy. Copies
  /// shared stay with the original.
  @discardableResult
  public func duplicateDocument(id: String, title: String? = nil) throws -> VaultDocument? {
    guard let original = try record(VaultDocument.self, id: id) else { return nil }
    var copy = VaultDocument(
      title: title ?? (original.title.isEmpty ? "" : original.title + " (copy)"), kind: original.kind,
      collection: original.collection, holder: original.holder, fields: original.fields, tags: original.tags,
      links: original.links, remindMonths: original.remindMonths, notes: original.notes, order: original.order)
    copy.text = original.text
    copy.thumbnail = original.thumbnail
    try save(copy)
    for key in original.secrets { try setDocumentSecret(original.secret(key), key: key, document: copy.id) }
    for (index, file) in try files(of: original).enumerated() {
      var new = file
      new.id = UUID().uuidString
      new.document = copy.id
      new.created = Date.now.wholeSeconds
      try addFile(new, place: Double(index + 1))
    }
    return try record(VaultDocument.self, id: copy.id)
  }
}
