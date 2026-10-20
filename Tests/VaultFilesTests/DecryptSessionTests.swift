import Foundation
import Testing

@testable import VaultFiles

struct DecryptSessionTests {
  let key = FolderKey()

  /// A folder with a few files, and the parent for working copies.
  func makeFolder(_ directory: TemporaryDirectory) throws -> (EncryptedFolder, URL) {
    let folder = try EncryptedFolder(url: directory.file("Project"), key: key)
    try folder.write(Data("readme".utf8), to: "README.md")
    try folder.write(Data("main".utf8), to: "Sources/main.swift")
    try folder.write(Data("old".utf8), to: "Sources/old.swift")
    try folder.write(pseudoRandomData(150_000), to: "Assets/big.bin")
    try folder.createDirectory("Empty")
    return (folder, directory.file("Decrypted"))
  }

  func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  @Test func startDecryptsAPlainCopyHiddenFromSpotlightAndBackups() throws {
    let directory = try TemporaryDirectory()
    let (folder, parent) = try makeFolder(directory)
    let session = try DecryptSession.start(folder, in: parent, duration: 60)
    #expect(session.copyURL.lastPathComponent == "Project")
    let copy = session.copyURL
    #expect(try String(contentsOf: copy.appendingPathComponent("README.md"), encoding: .utf8) == "readme")
    #expect(try String(contentsOf: copy.appendingPathComponent("Sources/main.swift"), encoding: .utf8) == "main")
    #expect(try Data(contentsOf: copy.appendingPathComponent("Assets/big.bin")) == pseudoRandomData(150_000))
    #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("Empty").path))
    #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent(".metadata_never_index").path))
    #if canImport(Darwin)
      #expect(try copy.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #endif
    #expect(session.lockDate > Date() && session.lockDate < Date().addingTimeInterval(61))
    #expect(!session.isExpired)
    // Nothing changed yet.
    #expect(try session.sealChanges() == .init())
    // The session is live, so it isn't a leftover.
    #expect(DecryptSession.leftovers(in: parent).isEmpty)

    // A second session of the same folder gets its own copy.
    let second = try DecryptSession.start(folder, in: parent)
    #expect(second.copyURL.lastPathComponent == "Project 2")
    try second.lock()
    try session.lock()
  }

  @Test func sealsEditsAdditionsAndDeletions() throws {
    let directory = try TemporaryDirectory()
    let (folder, parent) = try makeFolder(directory)
    let session = try DecryptSession.start(folder, in: parent)
    let copy = session.copyURL
    let fileManager = FileManager.default

    try write("main, edited", copy.appendingPathComponent("Sources/main.swift"))
    try write("new", copy.appendingPathComponent("Sources/new.swift"))
    try write("deep", copy.appendingPathComponent("New Folder/Inner/deep.txt"))
    try fileManager.removeItem(at: copy.appendingPathComponent("Sources/old.swift"))
    try fileManager.removeItem(at: copy.appendingPathComponent("Empty"))
    try Data().write(to: copy.appendingPathComponent(".DS_Store"))

    let report = try session.sealChanges()
    #expect(report == .init(edited: 1, added: 4, deleted: 2))
    #expect(report.summary == "1 edited · 4 added · 2 deleted")
    #expect(try folder.read("Sources/main.swift") == Data("main, edited".utf8))
    #expect(try folder.read("Sources/new.swift") == Data("new".utf8))
    #expect(try folder.read("New Folder/Inner/deep.txt") == Data("deep".utf8))
    #expect(!folder.exists("Sources/old.swift"))
    #expect(!folder.exists("Empty"))
    #expect(!folder.exists(".DS_Store"))
    #expect(!folder.exists(".metadata_never_index"))
    #expect(try session.sealChanges().isEmpty)

    // A touched file with the same contents isn't sealed again; a same-size edit is.
    let readme = copy.appendingPathComponent("README.md")
    try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: readme.path)
    #expect(try session.sealChanges().isEmpty)
    try write("README", readme)
    try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: readme.path)
    #expect(try session.sealChanges() == .init(edited: 1))
    #expect(try folder.read("README.md") == Data("README".utf8))

    // A file replaced by a folder, and a folder by a file.
    try fileManager.removeItem(at: readme)
    try write("inside", readme.appendingPathComponent("inside.txt"))
    try fileManager.removeItem(at: copy.appendingPathComponent("Assets"))
    try write("assets file", copy.appendingPathComponent("Assets"))
    _ = try session.sealChanges()
    #expect(try folder.read("README.md/inside.txt") == Data("inside".utf8))
    #expect(try folder.read("Assets") == Data("assets file".utf8))
    #expect(try folder.walk().map(\.path) == [
      "Assets", "New Folder", "New Folder/Inner", "New Folder/Inner/deep.txt", "README.md", "README.md/inside.txt",
      "Sources", "Sources/main.swift", "Sources/new.swift",
    ])
    try session.lock()
  }

  @Test func lockSealsAndRemovesTheCopy() throws {
    let directory = try TemporaryDirectory()
    let (folder, parent) = try makeFolder(directory)
    let session = try DecryptSession.start(folder, in: parent)
    try write("last edit", session.copyURL.appendingPathComponent("README.md"))
    #expect(try session.lock() == .init(edited: 1))
    #expect(session.isLocked)
    #expect(!FileManager.default.fileExists(atPath: session.copyURL.path))
    #expect(try folder.read("README.md") == Data("last edit".utf8))
    let sessions = parent.appendingPathComponent(DecryptSession.sessionsDirectoryName)
    #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty)
    #expect(try session.lock().isEmpty)
    #expect(try session.sealChanges().isEmpty)
  }

  @Test func extendMovesTheLockTime() throws {
    let directory = try TemporaryDirectory()
    let (folder, parent) = try makeFolder(directory)
    let session = try DecryptSession.start(folder, in: parent, duration: -1)
    #expect(session.isExpired)
    try session.extend(by: 600)
    #expect(!session.isExpired)
    let before = session.lockDate
    try session.extend(by: 60)
    #expect(abs(session.lockDate.timeIntervalSince(before) - 60) < 0.001)
    try session.lock()
  }

  @Test func recoversAfterACrash() throws {
    let directory = try TemporaryDirectory()
    let (folder, parent) = try makeFolder(directory)
    var copy: URL
    do {
      // A session that edits and then "crashes": dropped without locking, its lock released as a dead process's is.
      let session = try DecryptSession.start(folder, in: parent)
      copy = session.copyURL
      try write("unsaved", copy.appendingPathComponent("README.md"))
      try write("new", copy.appendingPathComponent("added.txt"))
    }
    let leftovers = DecryptSession.leftovers(in: parent)
    #expect(leftovers.count == 1)
    #expect(leftovers.first?.folderID == folder.folderID)
    #expect(leftovers.first?.folderPath == folder.url.path)

    // Without the folder (no key yet), the copy is left alone.
    let skipped = DecryptSession.recoverLeftovers(in: parent) { _ in nil }
    guard case .skipped = skipped.first?.outcome else { Issue.record("not skipped"); return }
    #expect(FileManager.default.fileExists(atPath: copy.path))

    let recovered = DecryptSession.recoverLeftovers(in: parent) { record in
      try EncryptedFolder(url: URL(fileURLWithPath: record.folderPath), key: key)
    }
    guard case .sealed(let report) = recovered.first?.outcome else { Issue.record("not sealed"); return }
    #expect(report == .init(edited: 1, added: 1))
    #expect(try folder.read("README.md") == Data("unsaved".utf8))
    #expect(try folder.read("added.txt") == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: copy.path))
    #expect(DecryptSession.leftovers(in: parent).isEmpty)
  }

  @Test func crashWhileDecryptingDiscardsTheCopy() throws {
    let directory = try TemporaryDirectory()
    let (folder, parent) = try makeFolder(directory)
    do {
      let session = try DecryptSession.start(folder, in: parent)
      // As if it died before the snapshot was written.
      try FileManager.default.removeItem(
        at: parent.appendingPathComponent(DecryptSession.sessionsDirectoryName + "/\(session.id).snapshot"))
    }
    let recovered = DecryptSession.recoverLeftovers(in: parent) { _ in folder }
    guard case .discarded = recovered.first?.outcome else { Issue.record("not discarded"); return }
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == [DecryptSession.sessionsDirectoryName])
    #expect(try folder.read("README.md") == Data("readme".utf8))
  }

  @Test func exportIsAPlainCopyNothingTracks() throws {
    let directory = try TemporaryDirectory()
    let (folder, _) = try makeFolder(directory)
    let export = directory.file("Export")
    try folder.exportDecrypted(to: export)
    #expect(try String(contentsOf: export.appendingPathComponent("Sources/main.swift"), encoding: .utf8) == "main")
    #expect(!FileManager.default.fileExists(atPath: export.appendingPathComponent(".metadata_never_index").path))
  }
}

/// Collects values from other threads.
final class Collector<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Value] = []

  func append(_ value: Value) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [Value] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  /// Waits up to `timeout` seconds for `condition`.
  func wait(timeout: TimeInterval, until condition: ([Value]) -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition(values) { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return condition(values)
  }
}

struct FolderActivityTests {
  let key = FolderKey()

  @Test func summaries() {
    #expect(FolderActivity.idle.summary == "Idle")
    let sealing = FolderActivity(
      phase: .sealing, file: "Sources/main.swift", fileBytes: 10, fileSize: 20, completed: 1, total: 5, bytesDone: 50,
      bytesTotal: 200)
    #expect(sealing.summary == "Sealing main.swift · 2 of 5")
    #expect(sealing.fraction == 0.25)
    #expect(FolderActivity(phase: .decrypting, completed: 1, total: 4).fraction == 0.25)
  }

  @Test func decryptingAndSealingReportActivity() throws {
    let directory = try TemporaryDirectory()
    let folder = try EncryptedFolder(url: directory.file("F"), key: key)
    try folder.write(pseudoRandomData(200_000), to: "big.bin")
    try folder.write(Data("small".utf8), to: "small.txt")
    let decrypting = Collector<FolderActivity>()
    let session = try DecryptSession.start(folder, in: directory.file("D")) { decrypting.append($0) }
    let decryptValues = decrypting.values
    #expect(decryptValues.first?.phase == .decrypting)
    #expect(decryptValues.first?.total == 2)
    #expect(decryptValues.first?.bytesTotal == 200_005)
    #expect(decryptValues.contains { $0.file == "big.bin" && $0.fileBytes == 200_000 && $0.bytesDone == 200_000 })
    #expect(decryptValues.contains { $0.file == "small.txt" && $0.completed == 1 })
    #expect(decryptValues.last == .idle)
    #expect(session.activity == .idle)

    let sealing = Collector<FolderActivity>()
    session.onActivity = { sealing.append($0) }
    try pseudoRandomData(100_000, seed: 9).write(to: session.copyURL.appendingPathComponent("new.bin"))
    try session.sealChanges()
    #expect(sealing.values.first?.phase == .sealing)
    #expect(sealing.values.first?.total == 1)
    #expect(sealing.values.contains { $0.fileBytes == 100_000 && $0.fraction == 1 })
    #expect(sealing.values.last == .idle)
    // A pass with nothing to seal reports nothing.
    let count = sealing.values.count
    try session.sealChanges()
    #expect(sealing.values.count == count)
    try session.lock()
  }

  #if os(macOS)
    @Test func watcherSealsChangesAsTheyHappen() throws {
      let directory = try TemporaryDirectory()
      let folder = try EncryptedFolder(url: directory.file("F"), key: key)
      try folder.write(Data("one".utf8), to: "one.txt")
      let session = try DecryptSession.start(folder, in: directory.file("D"))
      let reports = Collector<DecryptSession.Report>()
      let watcher = session.watch(latency: 0.1) { result in
        if case .success(let report) = result { reports.append(report) }
      }
      Thread.sleep(forTimeInterval: 0.3)  // FSEvents starts listening asynchronously.
      try Data("two".utf8).write(to: session.copyURL.appendingPathComponent("two.txt"))
      #expect(reports.wait(timeout: 10) { $0.reduce(0) { $0 + $1.added } >= 1 })
      #expect(try folder.read("two.txt") == Data("two".utf8))
      watcher.stop()
      try session.lock()
    }
  #endif
}
