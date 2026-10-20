import Foundation

/// A saved login: a website or app, the username, and notes. The password is a `VaultSecrets` item named after
/// the login, the one-time-code secret another one (`otp.<id>`), so listing logins never reads the keychain.
///
/// A login links to the other items it belongs with (a host, a database, a project, a folder), one
/// `link.<id>` field each, so two devices adding links at once both keep theirs.
///
/// `passwordChanged`, `otpChanged` and `hasOneTimeCode` are written only by the store's helpers
/// (`setPassword(_:forLogin:)`, `setOneTimeCode(_:forLogin:)`), never by saving the record, so a copy loaded
/// before the password changed can't set them back. Each field's clock (`VaultStore.fieldChanges(id:)`) also
/// tells which device made the change.
public struct VaultLogin: VaultRecord, Hashable {
  public static let kind = "login"
  public static let dynamicPrefixes = ["link."]

  public var id: String
  public var title: String
  /// The site's address as typed ("github.com", "https://app.example.com/login").
  public var website: String
  public var username: String
  public var notes: String
  public var favorite: Bool
  public var order: Int
  public var created: Date?
  /// Ids of linked items: hosts, databases, projects, folders.
  public var links: Set<String>
  /// Whether the login has a one-time-code secret (the `otp` field).
  public private(set) var hasOneTimeCode: Bool
  /// When the password last changed (set by `VaultStore.setPassword(_:forLogin:)`).
  public private(set) var passwordChanged: Date?
  /// When the one-time code last changed.
  public private(set) var otpChanged: Date?

  public init(
    id: String = UUID().uuidString, title: String = "", website: String = "", username: String = "",
    notes: String = "", favorite: Bool = false, order: Int = 0, created: Date? = .now, links: Set<String> = []
  ) {
    self.id = id
    self.title = title
    self.website = website
    self.username = username
    self.notes = notes
    self.favorite = favorite
    self.order = order
    self.created = created
    self.links = links
    hasOneTimeCode = false
    passwordChanged = nil
    otpChanged = nil
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    title = read.string("title", default: "")
    website = read.string("website", default: "")
    username = read.string("username", default: "")
    notes = read.string("notes", default: "")
    favorite = read.bool("favorite")
    order = read.int("order", default: 0)
    created = read.date("created")
    links = Set(read.flags(prefixed: "link"))
    hasOneTimeCode = read.bool("otp")
    passwordChanged = read.date("passwordChanged")
    otpChanged = read.date("otpChanged")
  }

  /// The fields saving writes. `otp`, `passwordChanged` and `otpChanged` are left to the store's helpers.
  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "title": .string(title), "website": .string(website), "username": .string(username), "notes": .string(notes),
      "favorite": .bool(favorite), "order": .init(order), "created": .init(created),
    ]
    for link in links { values["link.\(link)"] = .bool(true) }
    return values
  }

  /// Title if given, else the website's host, else the username.
  public var displayName: String {
    if !title.isEmpty { return title }
    if let domain { return domain }
    return username
  }

  /// The website's host without `www.` ("github.com"), nil when there is none.
  public var domain: String? {
    let text = website.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    let url = URL(string: text.contains("://") ? text : "https://" + text)
    guard var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host
  }

  public var password: String? { VaultSecrets.password(for: id) }

  /// The one-time-code generator, nil when the login has none.
  public var oneTimeCode: OneTimeCode? {
    VaultSecrets.secretText(Self.oneTimeCodeSecret(id)).flatMap(OneTimeCode.init)
  }

  /// The `VaultSecrets` name of a login's one-time-code secret.
  public static func oneTimeCodeSecret(_ id: String) -> String { "otp.\(id)" }
}

/// A payment card. The number and security code are `VaultSecrets` items (`card.number.<id>`,
/// `card.code.<id>`); the record keeps only what a list shows (the last four digits, the brand).
public struct VaultCard: VaultRecord, Hashable {
  public static let kind = "card"

  public var id: String
  public var title: String
  public var holder: String
  /// The number's last four digits, set by `VaultStore.setCardNumber(_:forCard:)`.
  public var last4: String
  /// "MM/YY".
  public var expiry: String
  /// "visa", "mastercard", "amex", "discover", or what the user typed.
  public var brand: String
  public var notes: String
  public var order: Int
  public var created: Date?

  public init(
    id: String = UUID().uuidString, title: String = "", holder: String = "", last4: String = "", expiry: String = "",
    brand: String = "", notes: String = "", order: Int = 0, created: Date? = .now
  ) {
    self.id = id
    self.title = title
    self.holder = holder
    self.last4 = last4
    self.expiry = expiry
    self.brand = brand
    self.notes = notes
    self.order = order
    self.created = created
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    title = read.string("title", default: "")
    holder = read.string("holder", default: "")
    last4 = read.string("last4", default: "")
    expiry = read.string("expiry", default: "")
    brand = read.string("brand", default: "")
    notes = read.string("notes", default: "")
    order = read.int("order", default: 0)
    created = read.date("created")
  }

  public var values: [String: JSONValue] {
    [
      "title": .string(title), "holder": .string(holder), "last4": .string(last4), "expiry": .string(expiry),
      "brand": .string(brand), "notes": .string(notes), "order": .init(order), "created": .init(created),
    ]
  }

  public var number: String? { VaultSecrets.secretText(Self.numberSecret(id)) }
  public var securityCode: String? { VaultSecrets.secretText(Self.codeSecret(id)) }

  public static func numberSecret(_ id: String) -> String { "card.number.\(id)" }
  public static func codeSecret(_ id: String) -> String { "card.code.\(id)" }

  /// The brand a card number's first digits name, nil when unknown.
  public static func brand(forNumber number: String) -> String? {
    let digits = number.filter(\.isNumber)
    func prefix(_ count: Int) -> Int? { digits.count >= count ? Int(digits.prefix(count)) : nil }
    if digits.hasPrefix("4") { return "visa" }
    if let two = prefix(2), two == 34 || two == 37 { return "amex" }
    if let two = prefix(2), (51...55).contains(two) { return "mastercard" }
    if let four = prefix(4), (2221...2720).contains(four) { return "mastercard" }
    if digits.hasPrefix("6011") || digits.hasPrefix("65") { return "discover" }
    return nil
  }
}

extension VaultStore {
  public enum PasswordItemError: LocalizedError {
    case invalidOneTimeCode

    public var errorDescription: String? {
      switch self {
      case .invalidOneTimeCode: "This isn’t a one-time-code setup key or otpauth link."
      }
    }
  }

  /// Saves a login's password (nil or empty deletes it) and, when it changed, notes when in `passwordChanged`.
  /// Returns whether it changed.
  @discardableResult
  public func setPassword(_ password: String?, forLogin id: String, now: Date = .now) throws -> Bool {
    let password = password?.isEmpty == true ? nil : password
    guard VaultSecrets.password(for: id) != password else { return false }
    try VaultSecrets.setPassword(password, for: id)
    try save(id: id, kind: VaultLogin.kind, changes: ["passwordChanged": .init(now)])
    return true
  }

  /// Saves a login's one-time-code secret from an `otpauth://` link or a base32 key (nil or empty removes it),
  /// and sets `otp` and `otpChanged`. Throws for text that is neither.
  @discardableResult
  public func setOneTimeCode(_ text: String?, forLogin id: String, now: Date = .now) throws -> Bool {
    let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let text, !text.isEmpty else { return try setOneTimeCode(OneTimeCode?.none, forLogin: id, now: now) }
    guard let code = OneTimeCode(text) else { throw PasswordItemError.invalidOneTimeCode }
    return try setOneTimeCode(code, forLogin: id, now: now)
  }

  /// Saves a login's one-time code (as its `otpauth://` URL), or removes it for nil.
  @discardableResult
  public func setOneTimeCode(_ code: OneTimeCode?, forLogin id: String, now: Date = .now) throws -> Bool {
    let name = VaultLogin.oneTimeCodeSecret(id)
    let text = code?.url
    guard VaultSecrets.secretText(name) != text else { return false }
    try VaultSecrets.setSecretText(text, named: name)
    try save(id: id, kind: VaultLogin.kind, changes: ["otp": .bool(code != nil), "otpChanged": .init(now)])
    return true
  }

  /// Deletes a login and its password and one-time code.
  public func deleteLogin(id: String) throws {
    try delete(id: id)
    try VaultSecrets.setPassword(nil, for: id)
    try VaultSecrets.setSecret(nil, named: VaultLogin.oneTimeCodeSecret(id))
  }

  /// Saves a card's number (nil or empty deletes it) and sets `last4`, and `brand` when it was empty.
  public func setCardNumber(_ number: String?, forCard id: String) throws {
    let digits = number?.filter(\.isNumber) ?? ""
    try VaultSecrets.setSecretText(digits.isEmpty ? nil : digits, named: VaultCard.numberSecret(id))
    var changes: [String: JSONValue] = ["last4": .string(String(digits.suffix(4)))]
    let current = try record(VaultCard.self, id: id)
    if current?.brand.isEmpty ?? true, let brand = VaultCard.brand(forNumber: digits) { changes["brand"] = .string(brand) }
    try save(id: id, kind: VaultCard.kind, changes: changes)
  }

  /// Saves a card's security code, or deletes it for nil.
  public func setCardCode(_ code: String?, forCard id: String) throws {
    try VaultSecrets.setSecretText(code, named: VaultCard.codeSecret(id))
  }

  /// Deletes a card and its number and security code.
  public func deleteCard(id: String) throws {
    try delete(id: id)
    try VaultSecrets.setSecret(nil, named: VaultCard.numberSecret(id))
    try VaultSecrets.setSecret(nil, named: VaultCard.codeSecret(id))
  }
}
