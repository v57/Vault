import Foundation

/// A JSON value: the type of every field in an item.
///
/// Fields stay untyped in the store so an app that doesn't know a field (an older build, or an app that keeps
/// a smaller model, like Shell's view of a Database connection) still carries it through unchanged.
public enum JSONValue: Hashable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var intValue: Int? {
    switch self {
    case .int(let value): Int(value)
    case .double(let value) where value.rounded() == value: Int(value)
    default: nil
    }
  }

  public var doubleValue: Double? {
    switch self {
    case .double(let value): value
    case .int(let value): Double(value)
    default: nil
    }
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var isNull: Bool { self == .null }
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(Int64(value)) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
  /// `.string`, or `.null` for nil: how optional text is written to a field.
  public init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
  public init(_ value: Int?) { self = value.map { .int(Int64($0)) } ?? .null }
  public init(_ value: Bool?) { self = value.map(JSONValue.bool) ?? .null }
  public init(_ value: Date?) { self = value.map { .double($0.timeIntervalSince1970) } ?? .null }

  public var dateValue: Date? { doubleValue.map(Date.init(timeIntervalSince1970:)) }

  /// A stable ordering for values written with the same clock (which only happens when two writers race
  /// inside one millisecond on one device): the bigger encoding wins, the same on every device.
  var tieBreakKey: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }
}
