import Foundation

/// A group of projects in the apps' sidebars (Git's groups). Groups nest: `parentID` is the group it is in,
/// nil at the top level. See `VaultProjectTree` for how groups and projects are arranged.
///
/// Whether a group is collapsed is each app's own state, not the vault's.
public struct VaultProjectGroup: VaultRecord, Hashable {
  public static let kind = "projectGroup"
  public static let dynamicPrefixes = ["path."]

  public var id: String
  public var name: String
  /// A secondary label, e.g. the folder above the one an imported group was made from.
  public var note: String?
  /// The group it is in; nil at the top level.
  public var parentID: String?
  /// Its place among the items in its parent.
  public var order: Int
  /// Device id → the folder the group was made from, when it was made by importing a folder, so importing
  /// that folder again joins it.
  public var paths: [String: String]

  public init(
    id: String = UUID().uuidString, name: String, note: String? = nil, parentID: String? = nil, order: Int = 0,
    paths: [String: String] = [:]
  ) {
    self.id = id
    self.name = name
    self.note = note
    self.parentID = parentID
    self.order = order
    self.paths = paths
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    note = read.string("note")
    parentID = read.string("parentID")
    order = read.int("order", default: 0)
    paths = read.strings(prefixed: "path")
  }

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "name": .string(name), "note": .init(note), "parentID": .init(parentID), "order": .init(order),
    ]
    values.set(paths, prefixed: "path")
    return values
  }

  /// The folder it was made from on this device.
  public var localPath: String? { paths[VaultDevice.id] }
  public var localURL: URL? { localPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
}
