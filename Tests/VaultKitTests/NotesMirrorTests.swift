import Foundation
import Testing

@testable import VaultKit

struct NotesMirrorTests {
  let keys = MemoryKeyProvider()

  func make() throws -> (NotesMirror, VaultStore, URL) {
    let root = temporaryDirectory()
    let store = try VaultStore(directory: root.appendingPathComponent("vault"), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
    let folder = root.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let mirror = NotesMirror(folder: folder, store: store, keys: keys, stateDirectory: root.appendingPathComponent("state"))
    mirror.usesTrash = false
    return (mirror, store, folder)
  }

  func notes(_ store: VaultStore) throws -> [VaultNote] {
    try store.records(VaultNote.self).sorted { $0.path < $1.path }
  }

  func write(_ text: String, _ path: String, in folder: URL) throws {
    let url = folder.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func read(_ path: String, in folder: URL) throws -> String {
    try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
  }

  @Test func filesBecomeNotesAndNotesBecomeFiles() throws {
    let (mirror, store, folder) = try make()
    try write("# Ideas\nfirst", "Ideas.md", in: folder)
    try write("in a folder", "Work/Plan.md", in: folder)
    mirror.reconcileNow()
    #expect(try notes(store).map(\.path) == ["Ideas.md", "Work/Plan.md"])
    #expect(try notes(store).first?.encrypted == false)
    #expect(NotesMirror.id(of: folder.appendingPathComponent("Ideas.md")) == (try notes(store).first?.id))

    // A note made elsewhere (Shell) appears as a file: encrypted ones as .mdenc only the vault key opens.
    try store.save(VaultNote(name: "From Shell", encrypted: true, text: "secret text"))
    mirror.reconcileNow()
    let sealed = try Data(contentsOf: folder.appendingPathComponent("From Shell.mdenc"))
    #expect(!String(decoding: sealed, as: UTF8.self).contains("secret"))
    #expect(try EncryptedNote.open(sealed, keys: keys) == "secret text")
  }

  @Test func editsGoBothWays() throws {
    let (mirror, store, folder) = try make()
    try write("one", "Note.md", in: folder)
    mirror.reconcileNow()
    try write("one, edited in another editor", "Note.md", in: folder)
    mirror.reconcileNow()
    var note = try #require(try notes(store).first)
    #expect(note.text == "one, edited in another editor")

    note.text = "edited on the iPhone"
    try store.save(note)
    let report = mirror.reconcileNow()
    #expect(report.written == 1)
    #expect(try read("Note.md", in: folder) == "edited on the iPhone")
    // Nothing changed since: a quiet pass.
    #expect(mirror.reconcileNow() == NotesMirror.Report())
  }

  @Test func renamesMovesAndEncryptionFollowTheFile() throws {
    let (mirror, store, folder) = try make()
    try write("text", "Draft.md", in: folder)
    mirror.reconcileNow()
    let id = try #require(try notes(store).first?.id)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("Archive"), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: folder.appendingPathComponent("Draft.md"), to: folder.appendingPathComponent("Archive/Final.md"))
    mirror.reconcileNow()
    let moved = try #require(try notes(store).first)
    #expect(moved.id == id)
    #expect(moved.path == "Archive/Final.md")

    // Renamed in the vault (another device): the file moves.
    var renamed = moved
    renamed.name = "Published"
    try store.save(renamed)
    mirror.reconcileNow()
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Archive/Published.md").path))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Archive/Final.md").path))

    // Encrypted in the vault: the file becomes .mdenc.
    var encrypted = try #require(try notes(store).first)
    encrypted.encrypted = true
    try store.save(encrypted)
    mirror.reconcileNow()
    let sealed = try Data(contentsOf: folder.appendingPathComponent("Archive/Published.mdenc"))
    #expect(try EncryptedNote.open(sealed, keys: keys) == "text")
    #expect(try notes(store).count == 1)
  }

  @Test func anEditorThatReplacesTheFileKeepsItsNote() throws {
    let (mirror, store, folder) = try make()
    try write("v1", "Note.md", in: folder)
    mirror.reconcileNow()
    let id = try #require(try notes(store).first?.id)
    // Saved by writing a new file over it: the extended attribute is gone.
    try FileManager.default.removeItem(at: folder.appendingPathComponent("Note.md"))
    try write("v2", "Note.md", in: folder)
    #expect(NotesMirror.id(of: folder.appendingPathComponent("Note.md")) == nil)
    mirror.reconcileNow()
    #expect(try notes(store).map(\.id) == [id])
    #expect(try notes(store).first?.text == "v2")
    #expect(NotesMirror.id(of: folder.appendingPathComponent("Note.md")) == id)
  }

  @Test func oneMirrorOfAFolderRunsAtATime() throws {
    // Two windows (or two copies of the app) mirror the same folder with the same state.
    let (first, store, folder) = try make()
    let state = folder.deletingLastPathComponent().appendingPathComponent("state")
    let second = NotesMirror(folder: folder, store: store, keys: keys, stateDirectory: state)
    try write("v1", "Untitled.md", in: folder)
    first.reconcileNow()
    let id = try #require(try notes(store).first?.id)
    // The editor saves by replacing the file: its id goes with the old one.
    try FileManager.default.removeItem(at: folder.appendingPathComponent("Untitled.md"))
    try write("v2", "Untitled.md", in: folder)
    // The other mirror waits instead of taking the file for a new note.
    #expect(second.reconcileNow() == NotesMirror.Report())
    #expect(try notes(store).map(\.id) == [id])

    // Once the first stops, the second takes over from where it left off.
    first.stop()
    second.reconcileNow()
    #expect(try notes(store).map(\.id) == [id])
    #expect(try notes(store).first?.text == "v2")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") } == ["Untitled.md"])
  }

  @Test func deletionsGoBothWays() throws {
    let (mirror, store, folder) = try make()
    try write("a", "A.md", in: folder)
    try write("b", "B.md", in: folder)
    mirror.reconcileNow()
    try FileManager.default.removeItem(at: folder.appendingPathComponent("A.md"))
    mirror.reconcileNow()
    #expect(try notes(store).map(\.name) == ["B"])

    let b = try #require(try notes(store).first)
    try store.delete(id: b.id)
    let report = mirror.reconcileNow()
    #expect(report.removedFiles == 1)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("B.md").path))
  }

  @Test func editsOnBothSidesMerge() throws {
    let (mirror, store, folder) = try make()
    try write("one\ntwo\nthree", "Note.md", in: folder)
    mirror.reconcileNow()
    try write("ONE\ntwo\nthree", "Note.md", in: folder)
    var note = try #require(try notes(store).first)
    note.text = "one\ntwo\nTHREE"
    try store.save(note)
    let report = mirror.reconcileNow()
    #expect(report.merged == 1)
    #expect(try read("Note.md", in: folder) == "ONE\ntwo\nTHREE")
    #expect(try notes(store).first?.text == "ONE\ntwo\nTHREE")
  }

  @Test func aVanishedFolderDeletesNothing() throws {
    let (mirror, store, folder) = try make()
    for name in ["a", "b", "c", "d"] { try write(name, "\(name).md", in: folder) }
    mirror.reconcileNow()
    for name in ["a", "b", "c", "d"] { try FileManager.default.removeItem(at: folder.appendingPathComponent("\(name).md")) }
    mirror.reconcileNow()
    #expect(try notes(store).count == 4)
    #expect(try read("a.md", in: folder) == "a")
  }

  @Test func otherFilesSyncAsAttachments() throws {
    let (mirror, store, folder) = try make()
    let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
    try image.write(to: folder.appendingPathComponent("images/chart.png"))
    mirror.reconcileNow()
    let file = try #require(try store.records(VaultNoteFile.self).first)
    #expect(file.path == "images/chart.png")
    #expect(file.data == image)
    try store.save(VaultNoteFile(path: "images/photo.jpg", data: Data([9, 9])))
    mirror.reconcileNow()
    #expect(try Data(contentsOf: folder.appendingPathComponent("images/photo.jpg")) == Data([9, 9]))
  }

  @Test func aNewFolderIsFilledWithoutDeletingNotes() throws {
    let (mirror, store, folder) = try make()
    try write("kept", "Kept.md", in: folder)
    mirror.reconcileNow()
    // The user picks another notes folder: the mirror stops, and a new one starts with a new index.
    mirror.stop()
    let other = folder.deletingLastPathComponent().appendingPathComponent("Moved")
    let moved = NotesMirror(folder: other, store: store, keys: keys, stateDirectory: folder.deletingLastPathComponent().appendingPathComponent("state"))
    moved.usesTrash = false
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    moved.reconcileNow()
    #expect(try read("Kept.md", in: other) == "kept")
    #expect(try notes(store).count == 1)
  }
}

struct NoteTextSyncTests {
  let keys = MemoryKeyProvider()
  let cloud = FakeCloud()

  @Test func notesEditedOnTwoDevicesAtOnceKeepBothEdits() throws {
    let mac = try FakeApp(directory: temporaryDirectory(), keys: keys, device: "mac", name: "mac")
    let phone = try FakeApp(directory: temporaryDirectory(), keys: keys, device: "phone", name: "phone")
    try mac.store.save(VaultNote(id: "n", name: "List", text: "milk\nbread\neggs"))
    mac.sync(cloud)
    phone.sync(cloud)

    var onMac = try #require(try mac.store.record(VaultNote.self, id: "n"))
    onMac.text = "milk\nbread\neggs\ncheese"
    try mac.store.save(onMac)
    var onPhone = try #require(try phone.store.record(VaultNote.self, id: "n"))
    onPhone.text = "oat milk\nbread\neggs"
    try phone.store.save(onPhone)

    mac.sync(cloud)
    phone.sync(cloud)
    mac.sync(cloud)
    let expected = "oat milk\nbread\neggs\ncheese"
    #expect(try mac.store.record(VaultNote.self, id: "n")?.text == expected)
    #expect(try phone.store.record(VaultNote.self, id: "n")?.text == expected)
  }

  @Test func otherFieldsStillTakeTheLaterWrite() throws {
    let a = ItemFields(["name": StampedValue("a", clock: HybridClock(millis: 1, counter: 0, device: "x"))])
    let b = ItemFields(["name": StampedValue("b", clock: HybridClock(millis: 2, counter: 0, device: "y"))])
    #expect(a.merged(with: b, base: nil, textKeys: ["text"]).values["name"] == "b")
  }
}
