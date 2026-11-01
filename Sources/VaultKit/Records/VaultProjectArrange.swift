import Foundation

extension VaultStore {
  /// Lays out projects added from folders the way the folders are, so every app that imports one (Git, Dev) builds
  /// the same tree. Call it after adding the projects (`addProject`), with the folders the user dropped or picked.
  ///
  /// - A dropped folder that holds two or more of them becomes a group named after it (the folder above it as its
  ///   note), and a folder inside it that holds two or more becomes a group inside that one. A folder with a single
  ///   project adds no group: the project joins the nearest group above it.
  /// - The group a folder made before is used again: one with the folder's path on this device, or, for the dropped
  ///   folder, one in the same place with its name (and note) and no path here, which takes the path. Others like
  ///   it there are merged into it.
  /// - Projects outside every root are grouped by the folder they are in (two or more, or a group that folder made).
  /// - Only projects at the top level move: one another app or device put in a group stays there. New groups, and
  ///   projects in none, go into `destination` (nil: the top level) before `before`, or at the end; with neither
  ///   given, projects already at the top level stay where they are.
  ///
  /// ```swift
  /// for repository in found.repositories { try store.addProject(path: repository.path) }
  /// try store.arrangeProjects(found.repositories.map(\.path), roots: [found.root.path])
  /// ```
  public func arrangeProjects(
    _ paths: [String], roots: [String] = [], into destination: String? = nil, before: String? = nil
  ) throws {
    var arranger = try ProjectArranger(store: self, destination: destination, before: before)
    try arranger.arrange(paths, roots: roots)
  }
}

/// `VaultStore.arrangeProjects`: the folders between each root and its projects, cut down to the ones that hold
/// two or more items, made into groups.
private struct ProjectArranger {
  let store: VaultStore
  let destination: String?
  let before: String?
  let device: String
  var tree: VaultProjectTree
  /// This device's project folders → project ids.
  var projects: [String: String] = [:]
  /// This device's group folders → group ids.
  var groups: [String: String] = [:]

  init(store: VaultStore, destination: String?, before: String?) throws {
    self.store = store
    self.destination = destination
    self.before = before
    device = store.deviceID
    tree = try store.projectTree()
    for project in tree.projects() {
      if let path = project.paths[device] { projects[path] = project.id }
    }
    for group in tree.groups {
      if let path = group.paths[device], groups[path] == nil { groups[path] = group.id }
    }
  }

  /// A folder between a root and its projects.
  final class Folder {
    let path: String
    var projects: [String] = []
    var children: [String: Folder] = [:]
    init(path: String) { self.path = path }
    var name: String { (path as NSString).lastPathComponent }
  }

  enum Item {
    case project(String)
    case folder(Folder)
  }

  mutating func arrange(_ paths: [String], roots: [String]) throws {
    let paths = paths.map(Self.clean).filter { path in
      projects[path].map { tree.parent(of: $0) == nil } ?? false
    }
    let roots = Set(roots.map(Self.clean)).sorted { $0.count > $1.count }
    var members: [String: [String]] = [:]
    var leftover: [String] = []
    for path in paths {
      // A dropped repository is placed by the folder it is in, as one outside every root.
      if let root = roots.first(where: { path.hasPrefix($0 + "/") }) {
        members[root, default: []].append(path)
      } else {
        leftover.append(path)
      }
    }
    // Outside every root: the folder each is in, when two or more are there or it made a group before.
    let byParent = Dictionary(grouping: leftover) { ($0 as NSString).deletingLastPathComponent }
    var loose: [String] = []
    for (parent, paths) in byParent {
      if paths.count >= 2 || groups[parent] != nil { members[parent, default: []] += paths } else { loose += paths }
    }
    // Outer roots first, so a folder's group is there before the groups inside it.
    for root in members.keys.sorted(by: { $0.count < $1.count }) {
      loose += try arrange(root: root, members: members[root] ?? [])
    }
    let ids = loose.compactMap { projects[$0] }.filter { tree.parent(of: $0) == nil }
    guard !ids.isEmpty, destination != nil || before != nil else { return }
    let names = ids.map { tree.node(id: $0)?.name ?? $0 }
    let order = zip(ids, names).sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }.map(\.0)
    try store.moveProjects(order, into: destination, before: before)
  }

  /// Groups one root's projects and returns those left for the destination.
  private mutating func arrange(root: String, members: [String]) throws -> [String] {
    let folder = Folder(path: root)
    for path in members where path != root {
      var current = folder
      let parent = (path as NSString).deletingLastPathComponent
      let relative = parent == root ? [] : parent.dropFirst(root.count + 1).split(separator: "/").map(String.init)
      for component in relative {
        let child = current.children[component] ?? Folder(path: current.path + "/" + component)
        current.children[component] = child
        current = child
      }
      current.projects.append(path)
    }
    // The root is a project itself (a repository dropped on its own): it has no group of its own.
    let own = members.contains(root) ? [root] : []
    let existing = try groupID(forRoot: folder)
    if existing != nil || items(of: folder).count >= 2 {
      try materialize(folder, existing: existing, in: destination, isRoot: true)
      return own
    }
    // Too few for a group: what it holds goes to the destination.
    var left = own
    for item in items(of: folder) {
      switch item {
      case .project(let path): left.append(path)
      case .folder(let child): try materialize(child, existing: groups[child.path], in: destination, isRoot: false)
      }
    }
    return left
  }

  /// What a folder's group holds: its projects, and its folders, each as a group of its own when it holds two or
  /// more items (or made a group before), else what it holds.
  private func items(of folder: Folder) -> [Item] {
    var items = folder.projects.map(Item.project)
    for child in folder.children.values {
      let inner = self.items(of: child)
      items += groups[child.path] != nil || inner.count >= 2 ? [.folder(child)] : inner
    }
    return items
  }

  /// The group a dropped folder made before: its path here, or one where it would go with its name and no path
  /// here (made on another device, or before groups kept paths), which takes the path. Others like it there are
  /// merged into it.
  private mutating func groupID(forRoot folder: Folder) throws -> String? {
    let note = Self.note(of: folder.path)
    let alike = tree.children(of: destination).compactMap(\.group).filter { group in
      group.name == folder.name && (group.note == nil || group.note == note)
        && (group.paths[device] == nil || group.paths[device] == folder.path)
    }
    var chosen = groups[folder.path].flatMap { id in tree.group(id: id) } ?? alike.first
    guard var group = chosen else { return nil }
    if group.paths[device] == nil {
      group.paths[device] = folder.path
      try store.save(group)
      groups[folder.path] = group.id
      chosen = group
    }
    for other in alike where other.id != group.id {
      let children = tree.node(id: other.id)?.children.map(\.id) ?? []
      try store.moveProjects(children, into: group.id)
    }
    if alike.count > 1 { tree = try store.projectTree() }
    return chosen?.id
  }

  /// Makes (or finds) a folder's group in `parent` and moves its items in, the groups inside it first made too.
  private mutating func materialize(_ folder: Folder, existing: String?, in parent: String?, isRoot: Bool) throws {
    let groupID: String
    if let existing, var group = tree.group(id: existing) {
      groupID = existing
      // A group inside another needs no note: the group above says where it is.
      if !isRoot, group.note != nil, parent != nil {
        group.note = nil
        try store.save(group)
      }
      // One a folder made before at the top level joins the folder above it.
      if !isRoot, let parent, tree.parent(of: existing) == nil {
        try store.moveProjects([existing], into: parent)
      }
    } else {
      let group = try store.addProjectGroup(
        name: folder.name, note: isRoot && parent == nil ? Self.note(of: folder.path) : nil, path: folder.path,
        in: parent, before: isRoot ? before : nil)
      groupID = group.id
      groups[folder.path] = group.id
    }
    let items = items(of: folder)
    var moving: [Item] = []
    for item in items {
      switch item {
      case .project(let path):
        if let id = projects[path], tree.parent(of: id) == nil { moving.append(item) }
      case .folder:
        moving.append(item)
      }
    }
    for item in sortedItems(moving) {
      switch item {
      case .project(let path):
        try store.moveProjects([projects[path]!], into: groupID)
      case .folder(let child):
        try materialize(child, existing: groups[child.path], in: groupID, isRoot: false)
      }
    }
    tree = try store.projectTree()
  }

  private func sortedItems(_ items: [Item]) -> [Item] {
    items.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
  }

  private func name(of item: Item) -> String {
    switch item {
    case .project(let path): projects[path].flatMap { tree.node(id: $0)?.name } ?? (path as NSString).lastPathComponent
    case .folder(let folder): folder.name
    }
  }

  /// The folder above, a group's note.
  static func note(of path: String) -> String? {
    let above = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    return above.isEmpty || above == "/" ? nil : above
  }

  static func clean(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
  }
}
