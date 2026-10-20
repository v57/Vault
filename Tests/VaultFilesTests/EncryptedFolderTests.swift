import CryptoKit
import Foundation
import Testing
import VaultKit

@testable import VaultFiles

struct FolderKeyTests {
  @Test func wrapsAndUnwrapsWithTheVaultKey() throws {
    let vaultKeys = MemoryKeyProvider()
    let key = FolderKey()
    #expect(key.id.count == 16)
    let wrapped = try key.wrapped(with: vaultKeys)
    #expect(Data(base64Encoded: wrapped) != nil)
    #expect(try FolderKey(wrapped: wrapped, keys: vaultKeys) == key)
    #expect(try key.wrapped(with: vaultKeys) != wrapped)  // a fresh nonce each time
    #expect(FolderKey() != key)
  }

  @Test func unwrappingNeedsTheVaultKey() throws {
    let wrapped = try FolderKey().wrapped(with: MemoryKeyProvider())
    #expect(throws: VaultCrypto.CryptoError.self) { try FolderKey(wrapped: wrapped, keys: MemoryKeyProvider()) }
    let empty = MemoryKeyProvider(keys: ["other": SymmetricKey(size: .bits256)])
    #expect(throws: VaultCrypto.CryptoError.self) { try FolderKey(wrapped: wrapped, keys: empty) }
    #expect(throws: VaultFilesError.damaged) { try FolderKey(wrapped: "not base64", keys: empty) }
    var bytes = [UInt8](Data(base64Encoded: wrapped)!)
    bytes[bytes.count - 1] ^= 1
    let vaultKeys = MemoryKeyProvider()
    #expect(throws: (any Error).self) { try FolderKey(wrapped: Data(bytes).base64EncodedString(), keys: vaultKeys) }
  }
}

struct EncryptedFolderTests {
  let key = FolderKey()

  /// Every name on disk under `url`, relative.
  func diskPaths(_ url: URL) -> [String] {
    let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)!
    return enumerator.compactMap { ($0 as? URL)?.path.replacingOccurrences(of: url.path + "/", with: "") }
  }

  @Test func createsAndReopens() throws {
    let directory = try TemporaryDirectory()
    let url = directory.file("Secret")
    let folder = try EncryptedFolder(url: url, key: key)
    #expect(EncryptedFolder.isEncryptedFolder(url))
    #expect(try EncryptedFolder.keyID(at: url) == key.id)
    #expect(folder.folderID.count == 32)
    #expect(try folder.list().isEmpty)
    try folder.write(Data("hello".utf8), to: "a.txt")
    let reopened = try EncryptedFolder(url: url, key: key)
    #expect(reopened.folderID == folder.folderID)
    #expect(try reopened.read("a.txt") == Data("hello".utf8))
    #expect(throws: VaultFilesError.wrongKey) { try EncryptedFolder(url: url, key: FolderKey()) }
  }

  @Test func refusesFoldersWithOtherFiles() throws {
    let directory = try TemporaryDirectory()
    let plain = directory.file("Plain")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: plain.appendingPathComponent("file.txt"))
    #expect(throws: VaultFilesError.notEncrypted) { try EncryptedFolder(url: plain, key: key) }
  }

  @Test func writesReadsAndListsWithEverythingEncryptedOnDisk() throws {
    let directory = try TemporaryDirectory()
    let folder = try EncryptedFolder(url: directory.file("F"), key: key)
    let big = pseudoRandomData(300_000)
    try folder.write(Data("one".utf8), to: "notes/one.txt")
    try folder.write(big, to: "notes/deep/big.bin")
    try folder.write(Data(), to: "empty")
    try folder.createDirectory("photos/2026")

    #expect(try folder.list().map(\.name) == ["empty", "notes", "photos"])
    let notes = try folder.list("notes")
    #expect(notes.map(\.name) == ["deep", "one.txt"])
    #expect(notes[0].isDirectory && notes[0].path == "notes/deep")
    #expect(!notes[1].isDirectory && notes[1].size == 3)
    #expect(try folder.stat("notes/deep/big.bin")?.size == Int64(big.count))
    #expect(try folder.stat("missing") == nil)
    #expect(try folder.stat("")?.isDirectory == true)
    #expect(try folder.read("notes/deep/big.bin") == big)
    #expect(try folder.reader("notes/deep/big.bin").read(range: 70_000..<70_010) == big[70_000..<70_010])
    #expect(try folder.walk().map(\.path) == [
      "empty", "notes", "notes/deep", "notes/deep/big.bin", "notes/one.txt", "photos", "photos/2026",
    ])

    // Overwriting replaces.
    try folder.write(Data("ONE".utf8), to: "notes/one.txt")
    #expect(try folder.read("notes/one.txt") == Data("ONE".utf8))

    // Nothing readable on disk: no plaintext names, no plaintext contents.
    let paths = diskPaths(folder.url)
    for name in ["notes", "one", "deep", "big", "photos", "2026", "empty"] {
      #expect(!paths.contains { $0.contains(name) }, "\(name) in \(paths)")
    }
    #expect(!paths.contains { $0.contains(".v57tmp-") })
    for path in paths {
      let url = folder.url.appendingPathComponent(path)
      if let data = try? Data(contentsOf: url) {
        #expect(data.range(of: Data("ONE".utf8)) == nil)
      }
    }
  }

  @Test func streamingWritesAndReads() throws {
    let directory = try TemporaryDirectory()
    let folder = try EncryptedFolder(url: directory.file("F"), key: key)
    let data = pseudoRandomData(200_000)
    try data.write(to: directory.file("source"))
    try folder.writeFile(from: directory.file("source"), to: "a/b.bin")
    try folder.readFile("a/b.bin", to: directory.file("out"))
    #expect(try Data(contentsOf: directory.file("out")) == data)
  }

  @Test func pathErrors() throws {
    let directory = try TemporaryDirectory()
    let folder = try EncryptedFolder(url: directory.file("F"), key: key)
    try folder.write(Data("x".utf8), to: "file")
    try folder.createDirectory("dir")
    #expect(throws: VaultFilesError.notFound("nope")) { try folder.read("nope") }
    #expect(throws: VaultFilesError.notFound("nope")) { try folder.list("nope") }
    #expect(throws: VaultFilesError.isADirectory("dir")) { try folder.read("dir") }
    #expect(throws: VaultFilesError.isADirectory("dir")) { try folder.write(Data(), to: "dir") }
    #expect(throws: VaultFilesError.notADirectory("file")) { try folder.write(Data(), to: "file/inner") }
    #expect(throws: VaultFilesError.invalidName("..")) { try folder.read("../escape") }
    #expect(throws: VaultFilesError.notFound("nope")) { try folder.remove("nope") }
    #expect(throws: VaultFilesError.invalidName("")) { try folder.remove("") }
    // `.` and doubled slashes are ignored.
    #expect(try folder.read("./file") == Data("x".utf8))
    #expect(try folder.read("//file") == Data("x".utf8))
  }

  @Test func movesAndRemoves() throws {
    let directory = try TemporaryDirectory()
    let folder = try EncryptedFolder(url: directory.file("F"), key: key)
    try folder.write(Data("a".utf8), to: "src/a.txt")
    try folder.write(Data("b".utf8), to: "src/sub/b.txt")
    try folder.write(Data("c".utf8), to: "c.txt")

    // Renaming a folder keeps its contents readable (names are tied to its directory id, not its path).
    try folder.move("src", to: "moved/renamed")
    #expect(try folder.read("moved/renamed/sub/b.txt") == Data("b".utf8))
    #expect(!folder.exists("src"))
    try folder.move("c.txt", to: "moved/c2.txt")
    #expect(try folder.read("moved/c2.txt") == Data("c".utf8))
    #expect(throws: VaultFilesError.exists("moved/c2.txt")) { try folder.move("moved/renamed/a.txt", to: "moved/c2.txt") }
    #expect(throws: VaultFilesError.notFound("c.txt")) { try folder.move("c.txt", to: "d.txt") }
    #expect(throws: VaultFilesError.self) { try folder.move("moved", to: "moved/inside") }

    try folder.remove("moved/renamed")
    #expect(try folder.walk().map(\.path) == ["moved", "moved/c2.txt"])
    try folder.remove("moved/c2.txt")
    #expect(try folder.list("moved").isEmpty)
  }

  @Test func longNamesUseSidecars() throws {
    let directory = try TemporaryDirectory()
    let folder = try EncryptedFolder(url: directory.file("F"), key: key)
    let longFile = String(repeating: "a very long file name ", count: 10) + ".txt"
    let longFolder = String(repeating: "folder ", count: 30)
    try folder.write(Data("long".utf8), to: "\(longFolder)/\(longFile)")
    #expect(try folder.list().map(\.name) == [longFolder])
    #expect(try folder.list(longFolder).map(\.name) == [longFile])
    #expect(try folder.read("\(longFolder)/\(longFile)") == Data("long".utf8))
    let disk = diskPaths(folder.url)
    #expect(disk.contains { $0.hasSuffix(".long") } && disk.contains { $0.hasSuffix(".name") })
    #expect(disk.allSatisfy { $0.split(separator: "/").allSatisfy { $0.utf8.count <= 200 } })

    // Renaming to a short name drops the sidecar; removing a long one removes its sidecar.
    try folder.move(longFolder, to: "short")
    #expect(try folder.read("short/\(longFile)") == Data("long".utf8))
    try folder.remove("short/\(longFile)")
    #expect(!diskPaths(folder.url).contains { $0.hasSuffix(".name") || $0.hasSuffix(".long") })
  }

  @Test func foreignFilesAreSkipped() throws {
    let directory = try TemporaryDirectory()
    let folder = try EncryptedFolder(url: directory.file("F"), key: key)
    try folder.write(Data("x".utf8), to: "real")
    try Data().write(to: folder.url.appendingPathComponent(".DS_Store"))
    try Data().write(to: folder.url.appendingPathComponent("NotAnEncryptedName"))
    #expect(try folder.list().map(\.name) == ["real"])
  }

  @Test func exportsDecrypted() throws {
    let directory = try TemporaryDirectory()
    let folder = try EncryptedFolder(url: directory.file("F"), key: key)
    try folder.write(Data("1".utf8), to: "a/one.txt")
    try folder.createDirectory("empty")
    try folder.write(pseudoRandomData(70_000), to: "b.bin")
    let export = directory.file("Export")
    try folder.exportDecrypted(to: export)
    #expect(try Data(contentsOf: export.appendingPathComponent("a/one.txt")) == Data("1".utf8))
    #expect(try Data(contentsOf: export.appendingPathComponent("b.bin")) == pseudoRandomData(70_000))
    #expect(FileManager.default.fileExists(atPath: export.appendingPathComponent("empty").path))
    #expect(throws: VaultFilesError.exists(export.path)) { try folder.exportDecrypted(to: export) }
  }
}
