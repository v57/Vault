import Foundation

/// The projects arranged in groups that nest, as every app's sidebar shows them.
///
/// A project's place is its `groupID` (nil: the top level) and its `order` among the items there; a group's is
/// its `parentID` and `order`. Groups and projects share one order, so they mix. The tree is built from the
/// records alone, so every app and device shows the same one: an item whose group is gone sits at the top
/// level, and a loop (two devices moving two groups into each other at once) is broken at the group with the
/// smallest id.
///
/// Read it from `Vault.projectTree` (or `VaultStore.projectTree()`), and change it with the store's
/// `moveProjects`, `addProjectGroup`, `groupProjects` and `ungroupProjects`, which keep the order consistent.
public struct VaultProjectTree: Sendable, Equatable {
  public enum Node: Identifiable, Sendable, Equatable {
    case group(VaultProjectGroup, children: [Node])
    case project(VaultProject)

    public var id: String {
      switch self {
      case .group(let group, _): group.id
      case .project(let project): project.id
      }
    }

    public var name: String {
      switch self {
      case .group(let group, _): group.name
      case .project(let project): project.name
      }
    }

    public var order: Int {
      switch self {
      case .group(let group, _): group.order
      case .project(let project): project.order
      }
    }

    public var children: [Node] {
      if case .group(_, let children) = self { children } else { [] }
    }

    public var group: VaultProjectGroup? {
      if case .group(let group, _) = self { group } else { nil }
    }

    public var project: VaultProject? {
      if case .project(let project) = self { project } else { nil }
    }

    /// The projects in it and in the groups inside it, in tree order (itself for a project).
    public var projects: [VaultProject] {
      switch self {
      case .group(_, let children): children.flatMap(\.projects)
      case .project(let project): [project]
      }
    }
  }

  /// The top-level items, in order.
  public let roots: [Node]
  private let nodes: [String: Node]
  /// Where each item is in the tree: its group, absent at the top level.
  private let parents: [String: String]

  public init(projects: [VaultProject], groups: [VaultProjectGroup]) {
    let groupsByID = Dictionary(groups.map { ($0.id, $0) }) { first, _ in first }
    var parents: [String: String] = [:]
    for group in groups {
      if let parent = group.parentID, parent != group.id, groupsByID[parent] != nil { parents[group.id] = parent }
    }
    Self.breakLoops(&parents)
    for project in projects {
      if let group = project.groupID, groupsByID[group] != nil { parents[project.id] = group }
    }

    var children: [String: [String]] = [:]
    let top = ""
    for id in groupsByID.keys { children[parents[id] ?? top, default: []].append(id) }
    let projectsByID = Dictionary(projects.map { ($0.id, $0) }) { first, _ in first }
    for id in projectsByID.keys { children[parents[id] ?? top, default: []].append(id) }

    var nodes: [String: Node] = [:]
    func build(_ parent: String) -> [Node] {
      let built: [Node] = (children[parent] ?? []).map { id in
        if let group = groupsByID[id] {
          return .group(group, children: build(id))
        }
        return .project(projectsByID[id]!)
      }
      let sorted = built.sorted(by: Self.precedes)
      for node in sorted { nodes[node.id] = node }
      return sorted
    }
    roots = build(top)
    self.nodes = nodes
    self.parents = parents
  }

  /// No projects or groups.
  public var isEmpty: Bool { roots.isEmpty }

  public func node(id: String) -> Node? { nodes[id] }

  public func group(id: String) -> VaultProjectGroup? { nodes[id]?.group }

  /// The items in a group, or at the top level when `groupID` is nil.
  public func children(of groupID: String?) -> [Node] {
    guard let groupID else { return roots }
    return nodes[groupID]?.children ?? []
  }

  /// The group an item is in, as the tree places it; nil at the top level.
  public func parent(of id: String) -> String? { parents[id] }

  /// The groups an item is in, the top-level one first.
  public func ancestors(of id: String) -> [VaultProjectGroup] {
    var groups: [VaultProjectGroup] = []
    var current = parents[id]
    while let id = current, let group = group(id: id) {
      groups.insert(group, at: 0)
      current = parents[id]
    }
    return groups
  }

  /// How many groups an item is in.
  public func depth(of id: String) -> Int { ancestors(of: id).count }

  /// Whether `id` is `groupID` or inside it, at any depth.
  public func isWithin(_ id: String, _ groupID: String) -> Bool {
    var current: String? = id
    while let id = current {
      if id == groupID { return true }
      current = parents[id]
    }
    return false
  }

  /// Every project in tree order, or the ones in a group (and the groups inside it).
  public func projects(in groupID: String? = nil) -> [VaultProject] {
    children(of: groupID).flatMap(\.projects)
  }

  /// Every group in tree order (a group before the groups inside it).
  public var groups: [VaultProjectGroup] {
    func walk(_ nodes: [Node]) -> [VaultProjectGroup] {
      nodes.flatMap { node in node.group.map { [$0] + walk(node.children) } ?? [] }
    }
    return walk(roots)
  }

  /// The tree with only the projects `isIncluded` keeps, and only the groups that still hold one: what a
  /// sidebar shows, e.g. the projects on this device.
  public func filter(_ isIncluded: (VaultProject) -> Bool) -> VaultProjectTree {
    let projects = projects().filter(isIncluded)
    var kept = Set<String>()
    for project in projects {
      var current = parents[project.id]
      while let id = current, kept.insert(id).inserted { current = parents[id] }
    }
    return VaultProjectTree(projects: projects, groups: groups.filter { kept.contains($0.id) })
  }

  /// Sibling order: `order`, then name, then id, so every device sorts ties the same way.
  static func precedes(_ a: Node, _ b: Node) -> Bool {
    if a.order != b.order { return a.order < b.order }
    switch a.name.localizedStandardCompare(b.name) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return a.id < b.id
    }
  }

  /// Takes each loop of parents apart at the group with the smallest id, which moves to the top level.
  private static func breakLoops(_ parents: inout [String: String]) {
    for start in parents.keys.sorted() {
      while true {
        var path: [String] = []
        var current: String? = start
        while let id = current, !path.contains(id) {
          path.append(id)
          current = parents[id]
        }
        guard let repeated = current, let index = path.firstIndex(of: repeated) else { break }
        parents[path[index...].min()!] = nil
      }
    }
  }
}

extension VaultStore {
  /// The projects and groups as a tree.
  public func projectTree() throws -> VaultProjectTree {
    VaultProjectTree(projects: try records(VaultProject.self), groups: try records(VaultProjectGroup.self))
  }

  /// Moves projects and groups (by id, in the order given) into a group, or the top level when `groupID` is
  /// nil, before the item `before` there or at the end. A group never moves into itself or a group inside it.
  /// Groups the move leaves without projects are deleted.
  public func moveProjects(_ ids: [String], into groupID: String?, before: String? = nil) throws {
    let tree = try projectTree()
    if let groupID, tree.group(id: groupID) == nil { return }
    var seen = Set<String>()
    let moving = ids.filter { id in
      guard tree.node(id: id) != nil, seen.insert(id).inserted else { return false }
      return groupID.map { !tree.isWithin($0, id) } ?? true
    }
    guard !moving.isEmpty else { return }
    let movingSet = Set(moving)
    let former = Set(moving.compactMap(tree.parent(of:)))

    let siblings = tree.children(of: groupID).map(\.id)
    var arranged = siblings.filter { !movingSet.contains($0) }
    let anchor = before.flatMap { before in
      siblings.firstIndex(of: before).flatMap { start in siblings[start...].first { !movingSet.contains($0) } }
    }
    let index = anchor.flatMap { arranged.firstIndex(of: $0) } ?? arranged.count
    arranged.insert(contentsOf: moving, at: index)
    for (order, id) in arranged.enumerated() { try place(id, in: groupID, order: order) }
    try removeEmptyProjectGroups(former.subtracting(groupID.map { [$0] } ?? []))
  }

  /// Adds a group in `parentID` (nil: the top level), before the item `before` there or at the end.
  @discardableResult
  public func addProjectGroup(
    name: String, note: String? = nil, path: String? = nil, in parentID: String? = nil, before: String? = nil
  ) throws -> VaultProjectGroup {
    let group = VaultProjectGroup(
      name: name, note: note, parentID: parentID, paths: path.map { [deviceID: $0] } ?? [:])
    try save(group)
    try moveProjects([group.id], into: parentID, before: before)
    return try record(VaultProjectGroup.self, id: group.id) ?? group
  }

  /// Makes a group of projects and groups where the first of them is, and moves them into it.
  @discardableResult
  public func groupProjects(_ ids: [String], name: String, note: String? = nil) throws -> VaultProjectGroup? {
    let tree = try projectTree()
    guard let first = ids.first(where: { tree.node(id: $0) != nil }) else { return nil }
    let group = try addProjectGroup(name: name, note: note, in: tree.parent(of: first), before: first)
    try moveProjects(ids, into: group.id)
    return try record(VaultProjectGroup.self, id: group.id)
  }

  /// Deletes a group and puts what it holds, projects and groups, where it was.
  public func ungroupProjects(_ groupID: String) throws {
    let tree = try projectTree()
    guard let node = tree.node(id: groupID), node.group != nil else { return }
    let parent = tree.parent(of: groupID)
    var arranged = tree.children(of: parent).map(\.id)
    let index = arranged.firstIndex(of: groupID) ?? arranged.count
    arranged.remove(at: index)
    arranged.insert(contentsOf: node.children.map(\.id), at: index)
    for (order, id) in arranged.enumerated() { try place(id, in: parent, order: order) }
    try delete(id: groupID)
  }

  /// Deletes the given groups that hold no project (at any depth), with the groups inside them, and then
  /// the groups holding them that are left empty.
  public func removeEmptyProjectGroups(_ ids: some Sequence<String>) throws {
    var pending = Array(ids)
    while let id = pending.popLast() {
      let tree = try projectTree()
      guard let node = tree.node(id: id), node.group != nil, node.projects.isEmpty else { continue }
      func remove(_ node: VaultProjectTree.Node) throws {
        for child in node.children { try remove(child) }
        if node.group != nil { try delete(id: node.id) }
      }
      try remove(node)
      if let parent = tree.parent(of: id) { pending.append(parent) }
    }
  }

  /// The order for an item added at the end of a group (or the top level).
  func endOrder(in groupID: String?) throws -> Int {
    ((try projectTree().children(of: groupID).map(\.order).max()) ?? -1) + 1
  }

  /// Saves an item's group and order (each only if it changed).
  private func place(_ id: String, in groupID: String?, order: Int) throws {
    if var project = try record(VaultProject.self, id: id) {
      guard project.groupID != groupID || project.order != order else { return }
      project.groupID = groupID
      project.order = order
      try save(project)
    } else if var group = try record(VaultProjectGroup.self, id: id) {
      guard group.parentID != groupID || group.order != order else { return }
      group.parentID = groupID
      group.order = order
      try save(group)
    }
  }
}
