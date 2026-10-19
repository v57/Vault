import Foundation
import Testing

@testable import VaultKit

struct ProjectKindTests {
  let keys = MemoryKeyProvider()

  func store(device: String = "mac") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  /// A folder holding the given files and folders (paths relative to it; a trailing `/` makes a folder).
  func folder(_ entries: [String]) throws -> URL {
    let root = temporaryDirectory()
    for entry in entries {
      let url = root.appendingPathComponent(entry)
      if entry.hasSuffix("/") {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      } else {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
      }
    }
    return root
  }

  @Test func detectsXcodeProjectsAtTheTopAndOneLevelDown() throws {
    #expect(VaultProject.Kind.detect(in: try folder(["App.xcodeproj/"])) == [.xcode])
    #expect(VaultProject.Kind.detect(in: try folder(["App/App.xcodeproj/", "README.md"])) == [.xcode])
    #expect(VaultProject.Kind.detect(in: try folder(["Package.swift", "Sources/"])) == [.swiftPackage])
    #expect(VaultProject.Kind.detect(in: try folder(["Package.swift", "Demo.xcodeproj/"])) == [.swiftPackage, .xcode])
    // Deeper, hidden or in build output: not the project's own.
    #expect(VaultProject.Kind.detect(in: try folder(["Ports/App/App.xcodeproj/"])) == [])
    #expect(VaultProject.Kind.detect(in: try folder([".build/checkouts/X.xcodeproj/"])) == [])
    #expect(VaultProject.Kind.detect(in: try folder(["node_modules/X.xcodeproj/"])) == [])
    #expect(VaultProject.Kind.detect(in: URL(fileURLWithPath: "/nonexistent-\(UUID())")) == nil)
  }

  @Test func addingAProjectNotesItsKinds() throws {
    let mac = try store()
    let app = try folder(["App.xcodeproj/"])
    let project = try mac.addProject(path: app.path)
    #expect(try mac.record(VaultProject.self, id: project.id)?.kinds == [.xcode])
    let item = try #require(try mac.item(id: project.id))
    #expect(item.values["kind.xcode"] == .bool(true))
  }

  @Test func refreshingSavesOnlyChangedKinds() throws {
    let mac = try store()
    let root = try folder(["Package.swift"])
    let project = try mac.addProject(path: root.path)
    #expect(try mac.record(VaultProject.self, id: project.id)?.kinds == [.swiftPackage])

    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: root.appendingPathComponent("Package.swift"))
    try mac.refreshProjectKinds()
    #expect(try mac.record(VaultProject.self, id: project.id)?.kinds == [.xcode])
    #expect(try mac.item(id: project.id)?.values["kind.swiftPackage"] == .null)

    let revision = mac.revision
    try mac.refreshProjectKinds()
    #expect(mac.revision == revision)
  }

  @Test func kindsANewerAppWroteSurvive() throws {
    let mac = try store()
    let project = try mac.addProject(path: try folder(["App.xcodeproj/"]).path)
    try mac.save(id: project.id, kind: VaultProject.kind, changes: ["kind.android": .bool(true)])
    var read = try #require(try mac.record(VaultProject.self, id: project.id))
    #expect(read.kinds == [.xcode, VaultProject.Kind(rawValue: "android")])
    read.name = "Renamed"
    try mac.save(read)
    #expect(try mac.item(id: project.id)?.values["kind.android"] == .bool(true))
  }

  @Test func aMissingFolderKeepsItsKinds() throws {
    let mac = try store()
    let root = try folder(["App.xcodeproj/"])
    let project = try mac.addProject(path: root.path)
    try FileManager.default.removeItem(at: root)
    try mac.refreshProjectKinds()
    #expect(try mac.record(VaultProject.self, id: project.id)?.kinds == [.xcode])
  }
}

struct ProjectIconTests {
  let keys = MemoryKeyProvider()

  @Test func iconsAreMadeAgainOnlyWhenTheirFileChanges() throws {
    let mac = try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
    let root = temporaryDirectory()
    let file = root.appendingPathComponent("icon.png")
    try Data("first".utf8).write(to: file)
    let project = try mac.addProject(path: root.path)
    var made = 0
    let refresh = {
      try mac.refreshProjectIcons(find: { _ in file }) { url in
        made += 1
        return try? Data(contentsOf: url)
      }
    }
    try refresh()
    try refresh()
    #expect(made == 1)
    #expect(try mac.record(VaultProject.self, id: project.id)?.icon == Data("first".utf8))

    try Data("second".utf8).write(to: file)
    try refresh()
    #expect(made == 2)
    #expect(try mac.record(VaultProject.self, id: project.id)?.icon == Data("second".utf8))

    // Nothing found here: the icon stays.
    try mac.refreshProjectIcons(find: { _ in nil }) { _ in nil }
    #expect(try mac.record(VaultProject.self, id: project.id)?.icon == Data("second".utf8))
  }

  @MainActor @Test func theVaultLooksForIconsOfProjectsAsTheyArrive() async throws {
    let store = try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: VaultDevice.id, notifier: nil, owner: "mac")
    let vault = Vault(store: store)
    let first = temporaryDirectory()
    try Data("a".utf8).write(to: first.appendingPathComponent("icon.png"))
    let a = try store.addProject(path: first.path)
    vault.reload()
    vault.findProjectIcons(with: { $0.appendingPathComponent("icon.png") }) { try? Data(contentsOf: $0) }
    let second = temporaryDirectory()
    try Data("b".utf8).write(to: second.appendingPathComponent("icon.png"))
    let b = try store.addProject(path: second.path)
    vault.reload()
    for _ in 0..<100 where try store.record(VaultProject.self, id: b.id)?.icon == nil {
      try await Task.sleep(for: .milliseconds(20))
      vault.reload()
    }
    #expect(try store.record(VaultProject.self, id: a.id)?.icon == Data("a".utf8))
    #expect(try store.record(VaultProject.self, id: b.id)?.icon == Data("b".utf8))
  }
}
