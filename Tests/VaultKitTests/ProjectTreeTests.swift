import Foundation
import Testing

@testable import VaultKit

struct ProjectTreeTests {
  let keys = MemoryKeyProvider()

  func store(device: String = "mac") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  /// Adds projects named after their folders under `/src`.
  @discardableResult
  func add(_ names: [String], to store: VaultStore) throws -> [String: String] {
    var ids: [String: String] = [:]
    for name in names { ids[name] = try store.addProject(path: "/src/\(name)").id }
    return ids
  }

  /// The tree as text: `Group[child, child]`, top level first.
  func outline(_ nodes: [VaultProjectTree.Node]) -> String {
    nodes.map { node in
      node.group == nil ? node.name : "\(node.name)[\(outline(node.children))]"
    }.joined(separator: ", ")
  }

  func outline(_ store: VaultStore) throws -> String { outline(try store.projectTree().roots) }

  @Test func newProjectsGoToTheEndOfTheTopLevel() throws {
    let store = try store()
    try add(["b", "a", "c"], to: store)
    #expect(try outline(store) == "b, a, c")
  }

  @Test func groupsNestAndMixWithProjects() throws {
    let store = try store()
    let ids = try add(["shell", "git", "agentus", "server"], to: store)
    let v57 = try store.addProjectGroup(name: "v57")
    try store.moveProjects([ids["shell"]!, ids["git"]!], into: v57.id)
    let agentus = try store.addProjectGroup(name: "Agentus", in: v57.id, before: ids["git"])
    try store.moveProjects([ids["agentus"]!, ids["server"]!], into: agentus.id)
    #expect(try outline(store) == "v57[shell, Agentus[agentus, server], git]")

    let tree = try store.projectTree()
    #expect(tree.ancestors(of: ids["server"]!).map(\.name) == ["v57", "Agentus"])
    #expect(tree.depth(of: ids["server"]!) == 2)
    #expect(tree.projects(in: v57.id).map(\.name) == ["shell", "agentus", "server", "git"])
    #expect(tree.groups.map(\.name) == ["v57", "Agentus"])
    #expect(tree.isWithin(agentus.id, v57.id))
    #expect(!tree.isWithin(v57.id, agentus.id))
  }

  @Test func movesPlaceItemsBeforeAnotherOrAtTheEnd() throws {
    let store = try store()
    let ids = try add(["a", "b", "c", "d"], to: store)
    try store.moveProjects([ids["d"]!, ids["c"]!], into: nil, before: ids["a"])
    #expect(try outline(store) == "d, c, a, b")
    // Dropping on an item that moves too lands before the next one that doesn't.
    try store.moveProjects([ids["a"]!], into: nil, before: ids["a"])
    #expect(try outline(store) == "d, c, a, b")
    try store.moveProjects([ids["d"]!], into: nil)
    #expect(try outline(store) == "c, a, b, d")
  }

  @Test func aGroupNeverMovesIntoItself() throws {
    let store = try store()
    let ids = try add(["a", "b"], to: store)
    let outer = try #require(try store.groupProjects([ids["a"]!, ids["b"]!], name: "Outer"))
    let inner = try #require(try store.groupProjects([ids["b"]!], name: "Inner"))
    try store.moveProjects([outer.id], into: inner.id)
    try store.moveProjects([outer.id], into: outer.id)
    #expect(try outline(store) == "Outer[a, Inner[b]]")
  }

  @Test func groupingMakesTheGroupWhereTheFirstItemIs() throws {
    let store = try store()
    let ids = try add(["a", "b", "c", "d"], to: store)
    let outer = try #require(try store.groupProjects([ids["b"]!, ids["c"]!, ids["d"]!], name: "Outer"))
    #expect(try outline(store) == "a, Outer[b, c, d]")
    // Grouping items inside a group makes a sub group there.
    let inner = try #require(try store.groupProjects([ids["c"]!, ids["d"]!], name: "Inner"))
    #expect(inner.parentID == outer.id)
    #expect(try outline(store) == "a, Outer[b, Inner[c, d]]")
  }

  @Test func ungroupingPutsWhatTheGroupHeldWhereItWas() throws {
    let store = try store()
    let ids = try add(["a", "b", "c", "d"], to: store)
    let outer = try #require(try store.groupProjects([ids["b"]!, ids["c"]!, ids["d"]!], name: "Outer"))
    try store.groupProjects([ids["c"]!], name: "Inner")
    try store.ungroupProjects(outer.id)
    #expect(try outline(store) == "a, b, Inner[c], d")
    #expect(try store.record(VaultProjectGroup.self, id: outer.id) == nil)
  }

  @Test func groupsLeftEmptyGo() throws {
    let store = try store()
    let ids = try add(["a", "b", "c"], to: store)
    let outer = try #require(try store.groupProjects([ids["a"]!, ids["b"]!], name: "Outer"))
    let inner = try #require(try store.groupProjects([ids["b"]!], name: "Inner"))
    // Outer still holds a: only Inner goes.
    try store.moveProjects([ids["b"]!], into: nil)
    #expect(try outline(store) == "Outer[a], c, b")
    #expect(try store.record(VaultProjectGroup.self, id: inner.id) == nil)

    // A group holding only an empty group is empty.
    let nested = try #require(try store.groupProjects([ids["a"]!], name: "Nested"))
    #expect(nested.parentID == outer.id)
    try store.moveProjects([ids["a"]!], into: nil, before: ids["c"])
    #expect(try outline(store) == "a, c, b")
    #expect(try store.records(VaultProjectGroup.self).isEmpty)
  }

  @Test func removingTheLastProjectRemovesItsGroup() throws {
    let store = try store()
    let ids = try add(["a", "b"], to: store)
    try store.groupProjects([ids["a"]!], name: "Group")
    try store.removeProject(path: "/src/a")
    #expect(try outline(store) == "b")
  }

  @Test func itemsWhoseGroupIsGoneSitAtTheTopLevel() {
    let tree = VaultProjectTree(
      projects: [VaultProject(id: "p", name: "p", groupID: "gone", order: 1)],
      groups: [VaultProjectGroup(id: "g", name: "g", parentID: "gone", order: 0)])
    #expect(outline(tree.roots) == "g[], p")
    #expect(tree.parent(of: "p") == nil)
  }

  @Test func filteringKeepsOnlyGroupsThatStillHoldAProject() throws {
    let store = try store()
    let ids = try add(["a", "b", "c"], to: store)
    try store.groupProjects([ids["a"]!], name: "A")
    let b = try #require(try store.groupProjects([ids["b"]!], name: "B"))
    try store.groupProjects([ids["c"]!], name: "C")
    try store.moveProjects([try #require(try store.projectTree().parent(of: ids["c"]!))], into: b.id)
    let tree = try store.projectTree().filter { $0.name != "a" && $0.name != "c" }
    #expect(outline(tree.roots) == "B[b]")
  }

  @Test func aLoopFromTwoDevicesBreaksTheSameWayOnBoth() throws {
    let cloud = FakeCloud()
    let mac = try FakeApp(directory: temporaryDirectory(), keys: keys, device: "mac", name: "mac.git")
    let other = try FakeApp(directory: temporaryDirectory(), keys: keys, device: "other", name: "other.git")
    let ids = try add(["a", "b"], to: mac.store)
    let one = try #require(try mac.store.groupProjects([ids["a"]!], name: "One"))
    let two = try #require(try mac.store.groupProjects([ids["b"]!], name: "Two"))
    mac.sync(cloud)
    other.sync(cloud)

    // Offline, each device moves one group into the other.
    try mac.store.moveProjects([one.id], into: two.id)
    try other.store.moveProjects([two.id], into: one.id)
    mac.sync(cloud)
    other.sync(cloud)
    mac.sync(cloud)

    let onMac = try outline(mac.store)
    #expect(onMac == (try outline(other.store)))
    let top = min(one.id, two.id) == one.id ? "One[a, Two[b]]" : "Two[b, One[a]]"
    #expect(onMac == top)
  }

  @Test func fieldsOfOlderBuildsAreKept() throws {
    let store = try store()
    let project = try store.addProject(path: "/src/a")
    try store.save(id: project.id, kind: VaultProject.kind, changes: ["group": "Apps"])
    try store.groupProjects([project.id], name: "Apps")
    #expect(try store.item(id: project.id)?.values["group"] == "Apps")
  }
}
