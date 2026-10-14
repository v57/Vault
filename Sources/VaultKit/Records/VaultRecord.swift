import Foundation

/// A typed view of one kind of item.
///
/// `values` lists every field the type knows, null for empty ones. Saving writes only the fields whose value
/// changed, so concurrent edits of different fields merge, and fields the type doesn't know (written by a
/// newer app, or one with a bigger model) are left alone.
public protocol VaultRecord: Identifiable, Sendable, Equatable where ID == String {
  static var kind: String { get }
  /// Prefixes of fields that come and go (`path.<device>`): a known prefix whose field is missing from
  /// `values` is cleared on save.
  static var dynamicPrefixes: [String] { get }

  var id: String { get }
  init(id: String, values: [String: JSONValue])
  var values: [String: JSONValue] { get }
}

extension VaultRecord {
  public static var dynamicPrefixes: [String] { [] }
}

extension VaultStore {
  /// The live records of a type, sorted by `order` then name where the type has them, else by id.
  public func records<Record: VaultRecord>(_ type: Record.Type = Record.self) throws -> [Record] {
    try items(kind: Record.kind).map { Record(id: $0.id, values: $0.values) }
  }

  public func record<Record: VaultRecord>(_ type: Record.Type = Record.self, id: String) throws -> Record? {
    guard let item = try item(id: id), item.kind == Record.kind, !item.isDeleted else { return nil }
    return Record(id: item.id, values: item.values)
  }

  /// Saves the record's changed fields. Returns whether anything changed.
  @discardableResult
  public func save<Record: VaultRecord>(_ record: Record) throws -> Bool {
    var changes = record.values
    if !Record.dynamicPrefixes.isEmpty, let existing = try item(id: record.id) {
      for key in existing.values.keys where changes[key] == nil {
        if Record.dynamicPrefixes.contains(where: key.hasPrefix) { changes[key] = .null }
      }
    }
    return try save(id: record.id, kind: Record.kind, changes: changes)
  }

  public func delete<Record: VaultRecord>(_ record: Record) throws {
    try delete(id: record.id)
  }
}

/// Reading typed values out of a field map.
struct FieldReader {
  let values: [String: JSONValue]

  init(_ values: [String: JSONValue]) { self.values = values }

  func string(_ key: String) -> String? { values[key]?.stringValue }
  func string(_ key: String, default value: String) -> String { values[key]?.stringValue ?? value }
  func int(_ key: String) -> Int? { values[key]?.intValue }
  func int(_ key: String, default value: Int) -> Int { values[key]?.intValue ?? value }
  func bool(_ key: String, default value: Bool = false) -> Bool { values[key]?.boolValue ?? value }
  func date(_ key: String) -> Date? { values[key]?.dateValue }

  /// Fields under `prefix.`, keyed by the rest of the name.
  func strings(prefixed prefix: String) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in values where key.hasPrefix(prefix + ".") {
      if let text = value.stringValue { result[String(key.dropFirst(prefix.count + 1))] = text }
    }
    return result
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  /// Writes `map` as `prefix.<key>` fields.
  mutating func set(_ map: [String: String], prefixed prefix: String) {
    for (key, value) in map { self["\(prefix).\(key)"] = .string(value) }
  }
}
