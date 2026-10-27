import Foundation

/// A project folder, shared by Git (which adds them), Code, Dev, Markdown and Shell.
///
/// The folder's path is per device: `paths` maps a device id to where the project is on that device, each
/// one its own field, so two Macs adding their own checkout never overwrite each other. The project's
/// identity is its remote URL when it has one (the same repository on every device), else its path on the
/// device that added it (see `identity`). Its place in the sidebars is `groupID` and `order` (see
/// `VaultProjectTree`). What it is (an Xcode project, a Swift package) is `kinds`, one `kind.<name>` field each, and
/// its picture is `icon` (see `VaultStore.refreshProjectIcons`).
public struct VaultProject: VaultRecord, Hashable {
  public static let kind = "project"
  public static let dynamicPrefixes = ["path.", "kind."]

  public var id: String
  public var name: String
  /// The `origin` remote, as git prints it.
  public var remoteURL: String?
  /// The `VaultProjectGroup` it is in; nil at the top level (see `VaultProjectTree`).
  public var groupID: String?
  /// Its place among the items in its group.
  public var order: Int
  /// Device id → folder path.
  public var paths: [String: String]
  /// What the folder holds (see `Kind.detect`), kept current by `VaultStore.refreshProjectKinds`.
  public var kinds: Set<Kind>
  /// A small square PNG of the project's app icon, for every app's project rows (even where the folder isn't).
  public var icon: Data?
  /// The hash of the file `icon` was made from, so it is made again only when that file changes.
  public var iconSource: String?
  /// The app that added it (bundle id).
  public var addedBy: String?
  public var added: Date?

  public init(
    id: String, name: String, remoteURL: String? = nil, groupID: String? = nil, order: Int = 0,
    paths: [String: String] = [:], kinds: Set<Kind> = [], icon: Data? = nil, iconSource: String? = nil, addedBy: String? = Bundle.main.bundleIdentifier, added: Date? = .now
  ) {
    self.id = id
    self.name = name
    self.remoteURL = remoteURL
    self.groupID = groupID
    self.order = order
    self.paths = paths
    self.kinds = kinds
    self.icon = icon
    self.iconSource = iconSource
    self.addedBy = addedBy
    self.added = added
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    remoteURL = read.string("remoteURL")
    groupID = read.string("groupID")
    order = read.int("order", default: 0)
    paths = read.strings(prefixed: "path")
    kinds = Set(read.flags(prefixed: "kind").map(Kind.init(rawValue:)))
    icon = read.data("icon")
    iconSource = read.string("iconSource")
    addedBy = read.string("addedBy")
    added = read.date("added")
  }

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "name": .string(name), "remoteURL": .init(remoteURL), "groupID": .init(groupID), "order": .init(order),
      "addedBy": .init(addedBy), "added": .init(added), "_identity": .init(identity),
      "icon": .init(icon?.base64EncodedString()), "iconSource": .init(iconSource),
    ]
    values.set(paths, prefixed: "path")
    for kind in kinds { values["kind.\(kind.rawValue)"] = .bool(true) }
    return values
  }

  /// The GitHub user or organization of its remote (`github.com/<owner>/<repo>` over HTTPS or SSH).
  public var gitHubOwner: String? { remoteURL.flatMap(Self.gitHubOwner(ofRemote:)) }

  static func gitHubOwner(ofRemote remote: String) -> String? {
    var text = remote.trimmingCharacters(in: .whitespaces)
    if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
    if let at = text.firstIndex(of: "@"), at < (text.firstIndex(of: "/") ?? text.endIndex) {
      text = String(text[text.index(after: at)...])
    }
    // `github.com:owner/repo` (scp style), `github.com/owner/repo`, `github.com:22/owner/repo`
    guard let separator = text.firstIndex(where: { $0 == "/" || $0 == ":" }) else { return nil }
    var host = text[..<separator].lowercased()
    if host.hasPrefix("www.") { host.removeFirst(4) }
    guard host == "github.com" else { return nil }
    let parts = text[text.index(after: separator)...].split(separator: "/").map(String.init)
    let path = parts.first.map { Int($0) != nil } == true ? Array(parts.dropFirst()) : parts
    guard path.count >= 2, let owner = path.first, !owner.isEmpty else { return nil }
    return owner
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

  /// Adds a folder on this device as a project, or adds this device's path to the existing one, and notes its
  /// kinds. A new project goes at the end of the top level of the tree.
  @discardableResult
  public func addProject(path: String, name: String? = nil, remoteURL: String? = nil) throws -> VaultProject {
    let folderName = (path as NSString).lastPathComponent
    let kinds = VaultProject.Kind.detect(in: URL(fileURLWithPath: path, isDirectory: true))
    if var project = try project(path: path, remoteURL: remoteURL) {
      project.paths[deviceID] = path
      if project.remoteURL == nil, let remoteURL { project.remoteURL = remoteURL }
      if let kinds, !kinds.isEmpty { project.kinds = kinds }
      try save(project)
      return project
    }
    let project = VaultProject(
      id: VaultProject.newID(remoteURL: remoteURL, path: path, in: self), name: name ?? folderName,
      remoteURL: remoteURL, order: try endOrder(in: nil), paths: [deviceID: path], kinds: kinds ?? [])
    try save(project)
    return project
  }

  /// Removes this device's folder from a project; the project goes when no device has it any more, and so
  /// does its group if that leaves it empty.
  public func removeProject(path: String) throws {
    guard var project = try records(VaultProject.self).first(where: { $0.paths[deviceID] == path }) else { return }
    project.paths[deviceID] = nil
    if project.paths.isEmpty {
      let group = try projectTree().parent(of: project.id)
      try delete(id: project.id)
      try removeEmptyProjectGroups(group.map { [$0] } ?? [])
    } else {
      try save(project)
    }
  }
}
