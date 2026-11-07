import Foundation

/// One field a kind of document has: "Number" on a passport, "Renews" on an insurance policy.
public struct DocumentField: Hashable, Sendable, Codable {
  public enum Format: String, Hashable, Sendable, Codable {
    case text
    /// A day ("2032-03-12" in the record), shown as a date.
    case date
    /// Kept as a `VaultSecrets` item, shown as dots until revealed.
    case secret
    /// An amount as typed ("€148 a year").
    case money
    /// A number of months ("3"): a notice period, counted back from the kind's renewal date.
    case months
  }

  public var key: String
  public var label: String
  public var format: Format
  /// The date the reminder counts back from (expiry, renewal, end of warranty). One per kind.
  public var reminds: Bool

  public init(_ key: String, _ label: String, _ format: Format = .text, reminds: Bool = false) {
    self.key = key
    self.label = label
    self.format = format
    self.reminds = reminds
  }
}

/// What a document is: its fields, which date reminds, where it's filed by default. The built-in kinds are below;
/// the user's own are `VaultDocumentKind` records.
public struct DocumentKind: Hashable, Sendable, Identifiable {
  public var id: String
  public var name: String
  /// A symbol name from the app's icon set ("passport", "id", "umbrella").
  public var symbol: String
  /// The collection a new document of this kind goes to.
  public var collection: String
  public var fields: [DocumentField]
  /// Months before the reminding date to remind; nil when the kind has no reminder.
  public var remindMonths: Int?
  /// What the pages are called while scanning ("Front", "Back"), empty for plain pages.
  public var sides: [String]
  public var isCustom: Bool

  public init(
    id: String, name: String, symbol: String, collection: String, fields: [DocumentField], remindMonths: Int? = nil,
    sides: [String] = [], isCustom: Bool = false
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.collection = collection
    self.fields = fields
    self.remindMonths = remindMonths
    self.sides = sides
    self.isCustom = isCustom
  }

  /// The field the reminder counts back from.
  public var remindingField: DocumentField? { fields.first(where: \.reminds) }
  /// The notice period, counted back from the reminding date ("cancel 3 months before it renews").
  public var noticeField: DocumentField? { fields.first { $0.format == .months } }

  public func field(_ key: String) -> DocumentField? { fields.first { $0.key == key } }

  /// A kind nobody knows any more (its custom record was deleted): the document keeps its fields as text.
  public static func unknown(_ id: String) -> DocumentKind {
    DocumentKind(id: id, name: "Document", symbol: "doc", collection: DocumentCollectionID.other, fields: [])
  }
}

/// The ids of the collections every vault starts with. Fixed, so two devices creating them at once write the same
/// records instead of two of each.
public enum DocumentCollectionID {
  public static let identity = "documents.identity"
  public static let work = "documents.work"
  public static let insurance = "documents.insurance"
  public static let banking = "documents.banking"
  public static let house = "documents.house"
  public static let car = "documents.car"
  public static let other = "documents.other"
}

extension DocumentKind {
  private typealias F = DocumentField

  public static let passport = DocumentKind(
    id: "passport", name: "Passport", symbol: "passport", collection: DocumentCollectionID.identity,
    fields: [
      F("name", "Holder"), F("country", "Nationality"), F("number", "Number", .secret),
      F("birthDate", "Date of birth", .date), F("issued", "Issued", .date), F("expires", "Expires", .date, reminds: true),
    ], remindMonths: 9, sides: ["Data page", "Cover"])

  public static let idCard = DocumentKind(
    id: "idCard", name: "ID Card", symbol: "id", collection: DocumentCollectionID.identity,
    fields: [
      F("name", "Holder"), F("country", "Country"), F("number", "Number", .secret), F("birthDate", "Date of birth", .date),
      F("issued", "Issued", .date), F("expires", "Expires", .date, reminds: true),
    ], remindMonths: 3, sides: ["Front", "Back"])

  public static let residencePermit = DocumentKind(
    id: "residencePermit", name: "Residence Permit", symbol: "id", collection: DocumentCollectionID.identity,
    fields: [
      F("name", "Holder"), F("country", "Country"), F("permit", "Type"), F("number", "Number", .secret),
      F("issued", "Issued", .date), F("expires", "Expires", .date, reminds: true),
    ], remindMonths: 4, sides: ["Front", "Back"])

  public static let driversLicence = DocumentKind(
    id: "driversLicence", name: "Driver’s Licence", symbol: "id", collection: DocumentCollectionID.identity,
    fields: [
      F("name", "Holder"), F("country", "Country"), F("number", "Number", .secret), F("classes", "Classes"),
      F("issued", "Issued", .date), F("expires", "Expires", .date, reminds: true),
    ], remindMonths: 3, sides: ["Front", "Back"])

  public static let birthCertificate = DocumentKind(
    id: "birthCertificate", name: "Birth Certificate", symbol: "doc", collection: DocumentCollectionID.identity,
    fields: [F("name", "Name"), F("birthDate", "Born", .date), F("place", "Place")])

  public static let resume = DocumentKind(
    id: "resume", name: "Resume", symbol: "work", collection: DocumentCollectionID.work,
    fields: [F("name", "Holder"), F("role", "For"), F("updated", "Updated", .date)])

  public static let employmentContract = DocumentKind(
    id: "employmentContract", name: "Employment Contract", symbol: "work", collection: DocumentCollectionID.work,
    fields: [
      F("employer", "Employer"), F("role", "Role"), F("starts", "Starts", .date), F("ends", "Ends", .date, reminds: true),
      F("notice", "Notice period", .months),
    ], remindMonths: 3)

  public static let payslip = DocumentKind(
    id: "payslip", name: "Payslip", symbol: "work", collection: DocumentCollectionID.work,
    fields: [F("employer", "Employer"), F("period", "Period"), F("amount", "Net pay", .money)])

  public static let certificate = DocumentKind(
    id: "certificate", name: "Certificate", symbol: "work", collection: DocumentCollectionID.work,
    fields: [F("issuer", "Issuer"), F("issued", "Issued", .date), F("expires", "Expires", .date, reminds: true)],
    remindMonths: 2)

  public static let insurancePolicy = DocumentKind(
    id: "insurancePolicy", name: "Insurance Policy", symbol: "umbrella", collection: DocumentCollectionID.insurance,
    fields: [
      F("insurer", "Insurer"), F("policyNumber", "Policy number"), F("insured", "Insured"), F("cover", "Cover", .money),
      F("premium", "Premium", .money), F("renews", "Renews", .date, reminds: true), F("notice", "Notice period", .months),
    ], remindMonths: 1)

  public static let paymentCard = DocumentKind(
    id: "paymentCard", name: "Payment Card", symbol: "card", collection: DocumentCollectionID.banking,
    fields: [F("issuer", "Bank"), F("last4", "Last 4 digits"), F("expires", "Expires", .date, reminds: true)],
    remindMonths: 1, sides: ["Front", "Back"])

  public static let bankDocument = DocumentKind(
    id: "bankDocument", name: "Bank Document", symbol: "card", collection: DocumentCollectionID.banking,
    fields: [F("bank", "Bank"), F("iban", "IBAN", .secret), F("dated", "Dated", .date)])

  public static let lease = DocumentKind(
    id: "lease", name: "Lease", symbol: "house", collection: DocumentCollectionID.house,
    fields: [
      F("landlord", "Landlord"), F("address", "Address"), F("rent", "Rent", .money), F("deposit", "Deposit", .money),
      F("starts", "Starts", .date), F("ends", "Ends", .date, reminds: true), F("notice", "Notice period", .months),
    ], remindMonths: 3)

  public static let contract = DocumentKind(
    id: "contract", name: "Contract", symbol: "doc", collection: DocumentCollectionID.house,
    fields: [
      F("provider", "Provider"), F("customerNumber", "Customer number"), F("price", "Price", .money),
      F("starts", "Starts", .date), F("renews", "Renews", .date, reminds: true), F("notice", "Notice period", .months),
    ], remindMonths: 1)

  public static let warranty = DocumentKind(
    id: "warranty", name: "Receipt or Warranty", symbol: "receipt", collection: DocumentCollectionID.house,
    fields: [
      F("shop", "Shop"), F("amount", "Amount", .money), F("bought", "Bought", .date),
      F("warrantyUntil", "Warranty until", .date, reminds: true),
    ], remindMonths: 1)

  public static let vehicleRegistration = DocumentKind(
    id: "vehicleRegistration", name: "Vehicle Registration", symbol: "car", collection: DocumentCollectionID.car,
    fields: [F("plate", "Plate"), F("vin", "Vehicle number"), F("inspection", "Next inspection", .date, reminds: true)],
    remindMonths: 1, sides: ["Front", "Back"])

  public static let other = DocumentKind(
    id: "other", name: "Document", symbol: "doc", collection: DocumentCollectionID.other,
    fields: [F("dated", "Dated", .date)])

  /// Every built-in kind, in the order a picker lists them.
  public static let builtIn: [DocumentKind] = [
    passport, idCard, residencePermit, driversLicence, birthCertificate, resume, employmentContract, payslip,
    certificate, insurancePolicy, paymentCard, bankDocument, lease, contract, warranty, vehicleRegistration, other,
  ]
}

/// A kind the user made: its name, symbol, collection and fields. Its id is the document's `kind`.
public struct VaultDocumentKind: VaultRecord, Hashable {
  public static let kind = "documentKind"

  public var id: String
  public var name: String
  public var symbol: String
  public var collection: String
  public var fields: [DocumentField]
  public var remindMonths: Int?
  public var order: Int

  public init(
    id: String = UUID().uuidString, name: String, symbol: String = "doc", collection: String = DocumentCollectionID.other,
    fields: [DocumentField] = [], remindMonths: Int? = nil, order: Int = 0
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.collection = collection
    self.fields = fields
    self.remindMonths = remindMonths
    self.order = order
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "Document")
    symbol = read.string("symbol", default: "doc")
    collection = read.string("collection", default: DocumentCollectionID.other)
    fields = read.string("fields").flatMap { try? JSONDecoder().decode([DocumentField].self, from: Data($0.utf8)) } ?? []
    remindMonths = read.int("remindMonths")
    order = read.int("order", default: 0)
  }

  public var values: [String: JSONValue] {
    let encoded = (try? JSONEncoder().encode(fields)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    return [
      "name": .string(name), "symbol": .string(symbol), "collection": .string(collection), "fields": .string(encoded),
      "remindMonths": .init(remindMonths), "order": .init(order),
    ]
  }

  public var documentKind: DocumentKind {
    DocumentKind(
      id: id, name: name, symbol: symbol, collection: collection, fields: fields, remindMonths: remindMonths,
      isCustom: true)
  }
}

/// The built-in kinds and the user's own, looked up by id.
public struct DocumentKinds: Sendable {
  public let all: [DocumentKind]
  private let byID: [String: DocumentKind]

  public init(custom: [VaultDocumentKind] = []) {
    all = DocumentKind.builtIn + custom.sorted { ($0.order, $0.name) < ($1.order, $1.name) }.map(\.documentKind)
    byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  public subscript(id: String) -> DocumentKind { byID[id] ?? .unknown(id) }
}
