import Foundation

/// A project folder, shared by Git (which adds them), Code, Dev, Markdown and Shell.
///
/// The folder's path is per device: `paths` maps a device id to where the project is on that device, each
/// one its own field, so two Macs adding their own checkout never overwrite each other. The project's
/// identity is its remote URL when it has one (the same repository on every device), else its path on the
/// device that added it (see `identity`).
public struct VaultProject: VaultRecord, Hashable {
  public static let kind = "project"
  public static let dynamicPrefixes = ["path."]

  public var id: String
  public var name: String
  /// The `origin` remote, as git prints it.
  public var remoteURL: String?
  /// A group name (Git's sidebar groups).
  public var group: String?
  /// Device id → folder path.
  public var paths: [String: String]
  /// The app that added it (bundle id).
  public var addedBy: String?
  public var added: Date?

  public init(
    id: String, name: String, remoteURL: String? = nil, group: String? = nil, paths: [String: String] = [:],
    addedBy: String? = Bundle.main.bundleIdentifier, added: Date? = .now
  ) {
    self.id = id
    self.name = name
    self.remoteURL = remoteURL
    self.group = group
    self.paths = paths
    self.addedBy = addedBy
    self.added = added
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    remoteURL = read.string("remoteURL")
    group = read.string("group")
    paths = read.strings(prefixed: "path")
    addedBy = read.string("addedBy")
    added = read.date("added")
  }

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "name": .string(name), "remoteURL": .init(remoteURL), "group": .init(group), "addedBy": .init(addedBy),
      "added": .init(added), "_identity": .init(identity),
    ]
    values.set(paths, prefixed: "path")
    return values
  }

  /// Where the project is on this device.
  public var localPath: String? { paths[VaultDevice.id] }
  public var localURL: URL? { localPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

  /// What makes two projects the same: the normalized remote URL and the folder name, so the same checkout
  /// on two Macs is one project while two clones of one repository on a Mac stay two. Projects without a
  /// remote are only the same when they have the same id (`newID` derives it from the folder, so two apps
  /// adding one folder agree).
  public var identity: String? {
    remoteURL.flatMap(Self.normalizedRemote).map { "remote:\($0)|\(name.lowercased())" }
  }

  /// `git@github.com:v57/Shell.git`, `https://github.com/v57/shell` and `ssh://git@github.com/v57/Shell`
  /// all become `github.com/v57/shell`.
  public static func normalizedRemote(_ url: String) -> String? {
    var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let hasScheme = text.range(of: "://") != nil
    if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
    if let at = text.firstIndex(of: "@"), text[..<at].allSatisfy({ $0 != "/" }) {
      text = String(text[text.index(after: at)...])
    }
    // scp-like `host:path` (a URL's `host:port` stays as it is).
    if !hasScheme, let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
      text = String(text[..<colon]) + "/" + text[text.index(after: colon)...]
    }
    if text.hasSuffix(".git") { text.removeLast(4) }
    while text.hasSuffix("/") { text.removeLast() }
    return text.lowercased()
  }

  /// The id for a new project: derived from its identity, so the same repository added on two devices gets
  /// the same id and syncs as one.
  public static func newID(remoteURL: String?, path: String, in store: VaultStore) -> String {
    let name = (path as NSString).lastPathComponent.lowercased()
    let identity =
      remoteURL.flatMap(normalizedRemote).map { "remote:\($0)|\(name)" } ?? "path:\(store.deviceID):\(path)"
    return (try? store.derivedID("project|" + identity)) ?? UUID().uuidString
  }
}

extension VaultStore {
  /// The project for a folder on this device, or the same checkout added on another device (same remote and
  /// folder name, not yet on this device).
  public func project(path: String, remoteURL: String?) throws -> VaultProject? {
    let projects = try records(VaultProject.self)
    if let project = projects.first(where: { $0.paths[deviceID] == path }) { return project }
    let name = (path as NSString).lastPathComponent
    guard let remote = remoteURL.flatMap(VaultProject.normalizedRemote) else { return nil }
    let identity = "remote:\(remote)|\(name.lowercased())"
    return projects.first { $0.identity == identity && $0.paths[deviceID] == nil }
  }

  /// Adds a folder on this device as a project, or adds this device's path to the existing one.
  @discardableResult
  public func addProject(path: String, name: String? = nil, remoteURL: String? = nil, group: String? = nil) throws
    -> VaultProject
  {
    let folderName = (path as NSString).lastPathComponent
    if var project = try project(path: path, remoteURL: remoteURL) {
      project.paths[deviceID] = path
      if project.remoteURL == nil, let remoteURL { project.remoteURL = remoteURL }
      if let group, project.group == nil { project.group = group }
      try save(project)
      return project
    }
    let project = VaultProject(
      id: VaultProject.newID(remoteURL: remoteURL, path: path, in: self), name: name ?? folderName,
      remoteURL: remoteURL, group: group, paths: [deviceID: path])
    try save(project)
    return project
  }

  /// Removes this device's folder from a project; the project goes when no device has it any more.
  public func removeProject(path: String) throws {
    guard var project = try records(VaultProject.self).first(where: { $0.paths[deviceID] == path }) else { return }
    project.paths[deviceID] = nil
    if project.paths.isEmpty {
      try delete(id: project.id)
    } else {
      try save(project)
    }
  }
}
