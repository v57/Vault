import CryptoKit
import Foundation
import Testing

@testable import VaultKit

struct TextMergeTests {
  let base = "# Title\none\ntwo\nthree\nfour\n"

  @Test func editsToDifferentLinesMerge() {
    let ours = "# Title\nONE\ntwo\nthree\nfour\n"
    let theirs = "# Title\none\ntwo\nthree\nFOUR\nfive\n"
    let result = TextMerge.merge(base: base, ours: ours, theirs: theirs)
    #expect(!result.hasConflicts)
    #expect(result.text == "# Title\nONE\ntwo\nthree\nFOUR\nfive\n")
  }

  @Test func theSameEditOnBothSidesIsKeptOnce() {
    let edit = "# Title\none\n2\nthree\nfour\n"
    #expect(TextMerge.merge(base: base, ours: edit, theirs: edit).text == edit)
    let ours = "# Title\none\n2\nthree\nfour\nmine\n"
    let result = TextMerge.merge(base: base, ours: ours, theirs: edit)
    #expect(!result.hasConflicts)
    #expect(result.text == ours)
  }

  @Test func differentEditsOfOneLineKeepBoth() {
    let ours = "# Title\none\nmine\nthree\nfour\n"
    let theirs = "# Title\none\ntheirs\nthree\nfour\n"
    let result = TextMerge.merge(base: base, ours: ours, theirs: theirs, oursLabel: "Mac", theirsLabel: "iPhone")
    #expect(result.hasConflicts)
    #expect(result.text == "# Title\none\n<<<<<<< Mac\nmine\n=======\ntheirs\n>>>>>>> iPhone\nthree\nfour\n")
  }

  @Test func insertionsAtDifferentPlacesMerge() {
    let ours = "# Title\nzero\none\ntwo\nthree\nfour\n"
    let theirs = "# Title\none\ntwo\nthree\nthree and a half\nfour\n"
    let result = TextMerge.merge(base: base, ours: ours, theirs: theirs)
    #expect(!result.hasConflicts)
    #expect(result.text == "# Title\nzero\none\ntwo\nthree\nthree and a half\nfour\n")
  }

  @Test func deletionOnOneSideAndEditElsewhere() {
    let ours = "# Title\none\nthree\nfour\n"
    let theirs = "# Title\none\ntwo\nthree\nfour!\n"
    #expect(TextMerge.merge(base: base, ours: ours, theirs: theirs).text == "# Title\none\nthree\nfour!\n")
  }

  @Test func diffFindsTheChangedRegions() {
    let a = TextMerge.lines("a\nb\nc\nd")
    let b = TextMerge.lines("a\nx\nc\nd\ne")
    #expect(TextMerge.diff(a, b) == [.init(base: 1..<2, side: 1..<2), .init(base: 4..<4, side: 4..<5)])
  }

  @Test func randomEditsAlwaysContainBothSides() {
    // Property: edits only one side made always come through.
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<200 {
      let lines = (0..<Int.random(in: 1...30, using: &generator)).map { "line \($0)" }
      var ours = lines
      var theirs = lines
      let oursIndex = Int.random(in: 0..<lines.count, using: &generator)
      ours[oursIndex] = "ours"
      let candidates = (0..<lines.count).filter { abs($0 - oursIndex) > 1 }
      guard let theirsIndex = candidates.randomElement(using: &generator) else { continue }
      theirs[theirsIndex] = "theirs"
      let result = TextMerge.merge(
        base: lines.joined(separator: "\n"), ours: ours.joined(separator: "\n"), theirs: theirs.joined(separator: "\n"))
      var expected = lines
      expected[oursIndex] = "ours"
      expected[theirsIndex] = "theirs"
      #expect(!result.hasConflicts)
      #expect(result.text == expected.joined(separator: "\n"))
    }
  }
}

struct EncryptedNoteTests {
  @Test func sealedNotesOpenWithTheVaultKeys() throws {
    let keys = MemoryKeyProvider()
    let data = try EncryptedNote.seal("# Secret\nbody", keys: keys)
    #expect(EncryptedNote.isEncrypted(data))
    #expect(!String(decoding: data, as: UTF8.self).contains("Secret"))
    #expect(try EncryptedNote.open(data, keys: keys) == "# Secret\nbody")
    #expect(throws: (any Error).self) { try EncryptedNote.open(data, keys: MemoryKeyProvider()) }
  }

  @Test func plainNotesReadAsThey() throws {
    #expect(try EncryptedNote.text(of: Data("plain".utf8), keys: MemoryKeyProvider()) == "plain")
  }

  @Test func encryptionTogglesTheExtension() {
    let note = URL(fileURLWithPath: "/notes/Ideas.md")
    #expect(EncryptedNote.url(for: note, encrypted: true).lastPathComponent == "Ideas.mdenc")
    #expect(EncryptedNote.url(for: note.deletingPathExtension().appendingPathExtension("mdenc"), encrypted: false).lastPathComponent == "Ideas.md")
  }

  @Test func baseCacheKeepsTextEncrypted() throws {
    let keys = MemoryKeyProvider()
    let directory = temporaryDirectory()
    let cache = NoteBaseCache(directory: directory, keys: keys)
    let note = URL(fileURLWithPath: "/notes/a.mdenc")
    cache.setBase("hidden text", for: note)
    #expect(cache.base(for: note) == "hidden text")
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(try files.allSatisfy { !String(decoding: try Data(contentsOf: $0), as: UTF8.self).contains("hidden") })
  }
}

struct RecordTests {
  let keys = MemoryKeyProvider()

  func store(device: String = "mac") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  @Test func remoteURLsNormalize() {
    for url in [
      "git@github.com:v57/Shell.git", "https://github.com/v57/shell", "ssh://git@github.com/v57/Shell.git",
      "https://user@github.com/v57/Shell/",
    ] {
      #expect(VaultProject.normalizedRemote(url) == "github.com/v57/shell")
    }
    #expect(VaultProject.normalizedRemote("ssh://git@host:2222/team/app.git") == "host:2222/team/app")
  }

  @Test func theSameCheckoutOnTwoDevicesIsOneProject() throws {
    let mac = try store(device: "mac")
    let other = try store(device: "imac")
    let a = try mac.addProject(path: "/Users/a/Shell", remoteURL: "git@github.com:v57/Shell.git")
    let b = try other.addProject(path: "/Volumes/Work/Shell", remoteURL: "https://github.com/v57/shell")
    #expect(a.id == b.id)
    // A second clone of the same repository on the Mac is its own project.
    let clone = try mac.addProject(path: "/Users/a/Shell-fork", remoteURL: "git@github.com:v57/Shell.git")
    #expect(clone.id != a.id)
    #expect(try mac.records(VaultProject.self).count == 2)
  }

  @Test func addingTheSameFolderTwiceKeepsOneProject() throws {
    let mac = try store()
    let first = try mac.addProject(path: "/x/Notes")
    let second = try mac.addProject(path: "/x/Notes", name: "Other name")
    #expect(first.id == second.id)
    #expect(try mac.records(VaultProject.self).count == 1)
  }

  @Test func removingTheLastPathDeletesTheProject() throws {
    let mac = try store()
    let project = try mac.addProject(path: "/x/App", remoteURL: "https://example.com/app.git")
    try mac.save(id: project.id, kind: VaultProject.kind, changes: ["path.imac": "/y/App"])
    try mac.removeProject(path: "/x/App")
    let left = try #require(try mac.record(VaultProject.self, id: project.id))
    #expect(left.paths == ["imac": "/y/App"])
    var other = left
    other.paths = [:]
    try mac.save(other)
    #expect(try mac.record(VaultProject.self, id: project.id)?.paths.isEmpty == true)
  }

  @Test func databasesKeepOptionsAsSeparateFields() throws {
    let mac = try store()
    var database = VaultDatabase(
      name: "Atlas", engine: VaultDatabase.Engine.mongodb, host: "db.example.com", port: 27017,
      options: ["authSource": "admin", "replicaSet": "rs0"])
    try mac.save(database)
    database.options["replicaSet"] = nil
    database.options["authMechanism"] = "SCRAM-SHA-256"
    try mac.save(database)
    let saved = try #require(try mac.record(VaultDatabase.self, id: database.id))
    #expect(saved.options == ["authSource": "admin", "authMechanism": "SCRAM-SHA-256"])
  }

  @Test func databasesAttachToTheSSHHostTheyRunOn() {
    let host = VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy")
    let other = VaultHost(name: "build", hostname: "10.0.0.5")
    let onHost = VaultDatabase(engine: VaultDatabase.Engine.postgres, host: "prod.example.com", port: 5432)
    #expect(onHost.tunnelHost(in: [other, host]) == host)
    #expect(onHost.tunnelTarget(through: host) == "127.0.0.1")
    #expect(VaultDatabase(engine: VaultDatabase.Engine.redis, host: "localhost", port: 6379).tunnelHost(in: [host]) == nil)
    var explicit = VaultDatabase(engine: VaultDatabase.Engine.mysql, host: "db.internal", port: 3306)
    explicit.sshHostID = other.id
    #expect(explicit.tunnelHost(in: [host, other]) == other)
    #expect(explicit.tunnelTarget(through: other) == "db.internal")
  }

  @Test func knownHostsAreSharedByAddress() throws {
    let mac = try store()
    try mac.trust(fingerprint: "SHA256:abc", host: "Prod.Example.com", port: 22)
    #expect(try mac.knownFingerprint(host: "prod.example.com", port: 22) == "SHA256:abc")
    #expect(try mac.knownFingerprint(host: "prod.example.com", port: 2222) == nil)
  }

  @Test func mpintKeepsValuesPositive() {
    #expect(SSHWire.mpint(Data([0x00, 0x00, 0x7f])) == Data([0, 0, 0, 1, 0x7f]))
    #expect(SSHWire.mpint(Data([0x80, 0x01])) == Data([0, 0, 0, 3, 0x00, 0x80, 0x01]))
    #expect(SSHWire.mpint(Data([0x00])) == Data([0, 0, 0, 1, 0x00]))
  }
}
