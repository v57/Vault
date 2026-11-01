import Foundation
import Testing

@testable import VaultKit

struct ProjectImportTests {
  let keys = MemoryKeyProvider()

  func store() throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
  }

  func outline(_ nodes: [VaultProjectTree.Node]) -> String {
    nodes.map { node in
      node.group == nil ? node.name : "\(node.name)[\(outline(node.children))]"
    }.joined(separator: ", ")
  }

  func outline(_ store: VaultStore) throws -> String { outline(try store.projectTree().roots) }

  /// Adds the paths as projects, then arranges them as a drop of `root` would.
  func importFolder(_ root: String, _ relative: [String], into store: VaultStore) throws {
    let paths = relative.map { $0.isEmpty ? root : "\(root)/\($0)" }
    for path in paths { try store.addProject(path: path) }
    try store.arrangeProjects(paths, roots: [root])
  }

  @Test func aDroppedFolderMirrorsItsTree() throws {
    let store = try store()
    try importFolder(
      "/dev/v57", ["Code", "Git", "Website/site", "Agentus/Agentus", "Agentus/AgentusServer", "Demos/Parsing"],
      into: store)
    // One-project folders add no group; Agentus holds two.
    #expect(try outline(store) == "v57[Agentus[Agentus, AgentusServer], Code, Git, Parsing, site]")
    let v57 = try #require(try store.projectTree().roots.first?.group)
    #expect(v57.note == "dev")
    #expect(v57.paths["mac"] == "/dev/v57")
    let agentus = try #require(try store.projectTree().roots.first?.children.first?.group)
    #expect(agentus.note == nil)
  }

  @Test func droppingAgainJoinsTheGroupItMade() throws {
    let store = try store()
    try importFolder("/dev/v57", ["Code", "Git"], into: store)
    try importFolder("/dev/v57", ["Component", "SSH"], into: store)
    #expect(try outline(store) == "v57[Code, Git, Component, SSH]")
  }

  @Test func aGroupWithoutAPathHereIsUsedAndDuplicatesMerge() throws {
    let store = try store()
    // Made before groups kept paths, and a second one by an import that missed it.
    let old = try store.addProjectGroup(name: "v57", note: "dev")
    let shell = try store.addProject(path: "/dev/v57/Shell")
    try store.moveProjects([shell.id], into: old.id)
    let copy = try store.addProjectGroup(name: "v57", note: "dev", path: "/dev/v57")
    let remote = try store.addProject(path: "/dev/v57/Remote")
    try store.moveProjects([remote.id], into: copy.id)
    try importFolder("/dev/v57", ["Traffic"], into: store)
    let text = try outline(store)
    #expect(text == "v57[Remote, Shell, Traffic]")
    #expect(try store.projectTree().groups.count == 1)
  }

  @Test func aLoneRepositoryStaysUngrouped() throws {
    let store = try store()
    try importFolder("/dev/tools", ["one"], into: store)
    try importFolder("/dev/solo", [""], into: store)
    #expect(try outline(store) == "one, solo")
  }

  @Test func projectsSomeoneGroupedStayThere() throws {
    let store = try store()
    let mine = try store.addProjectGroup(name: "Mine")
    let code = try store.addProject(path: "/dev/v57/Code")
    try store.moveProjects([code.id], into: mine.id)
    try importFolder("/dev/v57", ["Code", "Git", "Shell"], into: store)
    #expect(try outline(store) == "Mine[Code], v57[Git, Shell]")
  }

  @Test func theSameCheckoutLeavesAnotherDevicesGroup() throws {
    let store = try store()
    // hub-web in another Mac's Hub group; this Mac has a clone of it in v57/Website/reference.
    let hub = VaultProjectGroup(name: "Hub", note: "Hub", paths: ["ipad": "/hub/Hub"])
    try store.save(hub)
    let remote = "https://github.com/v57/hub-web.git"
    try store.save(
      VaultProject(
        id: VaultProject.newID(remoteURL: remote, path: "/hub/Hub/hub-web", in: store), name: "hub-web",
        remoteURL: remote, groupID: hub.id, paths: ["ipad": "/hub/Hub/hub-web"]))
    try store.addProject(path: "/dev/v57/Website/reference/hub-web", remoteURL: remote)
    for path in ["/dev/v57/Code", "/dev/v57/Website/site"] { try store.addProject(path: path) }
    try store.arrangeProjects(
      ["/dev/v57/Code", "/dev/v57/Website/site", "/dev/v57/Website/reference/hub-web"], roots: ["/dev/v57"])
    #expect(try outline(store) == "v57[Code, Website[hub-web, site]]")
  }

  @Test func withoutRootsSiblingsGroupByFolder() throws {
    let store = try store()
    for path in ["/a/x/one", "/a/x/two", "/b/three"] { try store.addProject(path: path) }
    try store.arrangeProjects(["/a/x/one", "/a/x/two", "/b/three"])
    #expect(try outline(store) == "three, x[one, two]")
  }

  @Test func discoveryFindsRepositoriesAndWhatItSkipped() throws {
    let root = temporaryDirectory().appendingPathComponent("v57")
    let fileManager = FileManager.default
    func make(_ path: String, files: [String] = []) throws {
      let url = root.appendingPathComponent(path)
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      for file in files { try Data().write(to: url.appendingPathComponent(file)) }
    }
    try make("Code/.git")
    try make("Agentus/Server/.git")
    try make("Ideas/Remote", files: ["Plan.md"])
    try make("Demos/Parsing", files: ["Package.swift"])
    try make("node_modules/x/.git")
    let result = VaultProjectDiscovery.scan(root)
    #expect(result.repositories.map(\.lastPathComponent) == ["Server", "Code"])
    #expect(result.skipped.map(\.url.lastPathComponent) == ["Demos", "Ideas"])
    let ideas = try #require(result.skipped.first { $0.url.lastPathComponent == "Ideas" })
    #expect(ideas.contents == .notes)
    #expect(!ideas.looksLikeProject)
    let demos = try #require(result.skipped.first { $0.url.lastPathComponent == "Demos" })
    #expect(demos.contents.contains(.swiftPackage))
    #expect(VaultProjectDiscovery.scan(root.appendingPathComponent("Code")).repositories.count == 1)
    let plain = VaultProjectDiscovery.scan(root.appendingPathComponent("Ideas"))
    #expect(plain.repositories.isEmpty)
    #expect(plain.skipped.map(\.url.lastPathComponent) == ["Ideas"])
  }

  @Test func foldersAddedFromTheOfferJoinTheDropsGroups() throws {
    let store = try store()
    try importFolder("/dev/v57", ["Code", "Git", "Agentus/Agentus", "Agentus/Server"], into: store)
    // What the suggestions sheet does with Ideas and Agentus/Docs.
    let added = ["/dev/v57/Ideas", "/dev/v57/Agentus/Docs"]
    for path in added { try store.addProject(path: path) }
    try store.arrangeProjects(added, roots: ["/dev/v57"])
    #expect(try outline(store) == "v57[Agentus[Agentus, Server, Docs], Code, Git, Ideas]")
  }

  @Test func aDroppedRepositoryJoinsItsFoldersGroup() throws {
    let store = try store()
    try importFolder("/dev/v57", ["Code", "Git"], into: store)
    try importFolder("/dev/v57/SSH", [""], into: store)
    #expect(try outline(store) == "v57[Code, Git, SSH]")
  }

  @Test func discoverySkipsHiddenDependencyAndDeepFolders() throws {
    let root = temporaryDirectory().appendingPathComponent("tree")
    let fileManager = FileManager.default
    for path in [
      "a/.git", "group/b/.git", "group/b/nested/.git", "node_modules/c/.git", ".hidden/d/.git",
      "deep/1/2/3/4/5/6/7/.git", "wt",
    ] {
      try fileManager.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    // A worktree has a .git file.
    try "gitdir: /elsewhere".write(to: root.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
    let found = VaultProjectDiscovery.scan(root).repositories.map {
      $0.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
    }
    #expect(found == ["a", "group/b", "wt"])
  }

  @Test func discoveryFindsDatabasesByTheirHeader() throws {
    let root = temporaryDirectory().appendingPathComponent("data")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root.appendingPathComponent("app/.git"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: root.appendingPathComponent("dumps"), withIntermediateDirectories: true)
    var sqlite = Data("SQLite format 3".utf8) + [0]
    sqlite += Data(count: 100)
    try sqlite.write(to: root.appendingPathComponent("dumps/orders.sqlite"))
    var duck = Data(count: 8) + Data("DUCK".utf8)
    duck += Data(count: 100)
    try duck.write(to: root.appendingPathComponent("dumps/events.duckdb"))
    try Data("not a database at all".utf8).write(to: root.appendingPathComponent("dumps/Thumbs.db"))
    // Inside a repository: the repository's, not offered.
    try sqlite.write(to: root.appendingPathComponent("app/fixture.sqlite"))

    let result = VaultProjectDiscovery.scan(root)
    #expect(result.databases.map(\.url.lastPathComponent) == ["events.duckdb", "orders.sqlite"])
    #expect(result.databases.map(\.engine) == [VaultDatabase.Engine.duckdb, VaultDatabase.Engine.sqlite])
    let file = VaultProjectDiscovery.scan(root.appendingPathComponent("dumps/orders.sqlite"))
    #expect(file.databases.count == 1 && file.repositories.isEmpty && file.skipped.isEmpty)

    let store = try store()
    let offer = try #require(VaultImportOffer([result], store: store))
    #expect(offer.repositories.map(\.lastPathComponent) == ["app"])
    #expect(offer.databases.count == 2)
    // The dumps folder holds databases only: they are offered, not it.
    #expect(offer.folders.isEmpty)
    let saved = try store.addDatabaseFile(offer.databases[1])
    #expect(saved.name == "orders" && saved.engine == VaultDatabase.Engine.sqlite)
    #expect(try store.addDatabaseFile(offer.databases[1]).id == saved.id)
    try store.addProject(path: offer.repositories[0].path)
    let rest = try #require(VaultImportOffer([result], store: store))
    #expect(rest.repositories.isEmpty && rest.databases.map(\.url.lastPathComponent) == ["events.duckdb"])
  }
}
