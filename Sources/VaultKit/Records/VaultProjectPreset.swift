import Foundation

/// A run preset of a project, kept in the vault so the project shows it on the user's other devices (Code on another
/// Mac, Code on iPad): an action with the four choices of Code's toolbar. Code's own presets file
/// (`.dev/actions.json`) holds the ones kept on one Mac.
///
/// Every part is a name, as in that file: `from` is "local" for the device the project is opened on, else a machine as
/// Hub or SSH calls it; `project` is the workspace, project or package file ("Git-Local.xcworkspace"); `target` is the
/// destination ("v57 iPhone"). Each is its own field, so a rename on one device and a reorder on another merge.
public struct VaultProjectPreset: VaultRecord, Hashable {
  public static let kind = "projectPreset"

  public var id: String
  /// The `VaultProject` it belongs to.
  public var projectID: String
  public var name: String
  /// "run", "test" or "build".
  public var action: String
  public var from: String
  public var project: String
  public var scheme: String
  public var target: String
  /// Its place among the project's presets.
  public var order: Int

  public init(
    id: String = UUID().uuidString, projectID: String, name: String, action: String, from: String, project: String,
    scheme: String, target: String, order: Int = 0
  ) {
    self.id = id
    self.projectID = projectID
    self.name = name
    self.action = action
    self.from = from
    self.project = project
    self.scheme = scheme
    self.target = target
    self.order = order
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    projectID = read.string("projectID", default: "")
    name = read.string("name", default: "")
    action = read.string("action", default: "run")
    from = read.string("from", default: "local")
    project = read.string("project", default: "")
    scheme = read.string("scheme", default: "")
    target = read.string("target", default: "")
    order = read.int("order", default: 0)
  }

  public var values: [String: JSONValue] {
    [
      "projectID": .string(projectID), "name": .string(name), "action": .string(action), "from": .string(from),
      "project": .string(project), "scheme": .string(scheme), "target": .string(target), "order": .init(order),
    ]
  }
}

extension Vault {
  /// A project's presets, in their order.
  public func presets(of projectID: String) -> [VaultProjectPreset] {
    projectPresets.filter { $0.projectID == projectID }
  }
}
