import CryptoKit
import Foundation
import Testing

@testable import VaultFiles

struct EncryptedNameTests {
  let keys = FolderSubkeys(folderKey: SymmetricKey(size: .bits256))
  var cipher: NameCipher { NameCipher(keys: keys) }
  let root = Data(repeating: 1, count: 16)
  let other = Data(repeating: 2, count: 16)

  @Test func subkeysDiffer() {
    let raw = { (key: SymmetricKey) in key.withUnsafeBytes { Data($0) } }
    let all = [raw(keys.content), raw(keys.nameEncryption), raw(keys.nameNonce)]
    #expect(Set(all).count == 3)
    let again = FolderSubkeys(folderKey: SymmetricKey(data: Data(repeating: 7, count: 32)))
    let same = FolderSubkeys(folderKey: SymmetricKey(data: Data(repeating: 7, count: 32)))
    #expect(raw(again.content) == raw(same.content))
  }

  @Test func namesRoundTripDeterministically() throws {
    for name in ["a", "README.md", "Ünïcödé 名前 🚀.txt", ".hidden", "with space", String(repeating: "x", count: 255)] {
      let encrypted = try cipher.encrypt(name, directoryID: root)
      #expect(try cipher.encrypt(name, directoryID: root) == encrypted)
      #expect(try cipher.decrypt(encrypted, directoryID: root) == name)
      #expect(!encrypted.contains("."))
      #expect(!encrypted.contains("/"))
      #expect(!encrypted.contains("="))
      #expect(encrypted.allSatisfy { $0.isASCII })
    }
  }

  @Test func differentNamesFoldersAndKeysDiffer() throws {
    let a = try cipher.encrypt("notes.txt", directoryID: root)
    #expect(try cipher.encrypt("notes.txt", directoryID: other) != a)
    #expect(try cipher.encrypt("Notes.txt", directoryID: root) != a)
    let otherCipher = NameCipher(keys: FolderSubkeys(folderKey: SymmetricKey(size: .bits256)))
    #expect(try otherCipher.encrypt("notes.txt", directoryID: root) != a)
    // A name doesn't open in another folder or with another key.
    #expect(throws: VaultFilesError.damaged) { try cipher.decrypt(a, directoryID: other) }
    #expect(throws: VaultFilesError.damaged) { try otherCipher.decrypt(a, directoryID: root) }
  }

  @Test func unicodeFormsAreOneName() throws {
    let composed = "caf\u{e9}"
    let decomposed = "cafe\u{301}"
    #expect(try cipher.encrypt(composed, directoryID: root) == cipher.encrypt(decomposed, directoryID: root))
    #expect(try cipher.decrypt(cipher.encrypt(decomposed, directoryID: root), directoryID: root) == composed)
  }

  @Test func invalidNamesAreRejected() {
    for name in ["", ".", "..", "a/b", "nul\0"] {
      #expect(throws: VaultFilesError.self) { try cipher.encrypt(name, directoryID: root) }
    }
  }

  @Test func tamperedNamesFail() throws {
    let encrypted = try cipher.encrypt("secret plans.pdf", directoryID: root)
    var characters = Array(encrypted)
    for index in characters.indices {
      let original = characters[index]
      characters[index] = original == "A" ? "B" : "A"
      #expect(throws: VaultFilesError.damaged) { try cipher.decrypt(String(characters), directoryID: root) }
      characters[index] = original
    }
    #expect(throws: VaultFilesError.damaged) { try cipher.decrypt("not base64!", directoryID: root) }
    #expect(throws: VaultFilesError.damaged) { try cipher.decrypt("AAAA", directoryID: root) }
  }

  @Test func longNamesAreShortenedWithASidecar() throws {
    let short = try cipher.encrypt("short.txt", directoryID: root)
    #expect(DiskName.forEncrypted(short) == (short, nil))
    #expect(DiskName.kind(of: short) == .encrypted(short))

    let long = try cipher.encrypt(String(repeating: "long name ", count: 20), directoryID: root)
    #expect(long.count > NameCipher.maxEncodedLength)
    let disk = DiskName.forEncrypted(long)
    #expect(disk.entry.hasSuffix(".long"))
    #expect(disk.entry.utf8.count < 64)
    #expect(disk.sidecar == String(disk.entry.dropLast(5)) + ".name")
    #expect(DiskName.forEncrypted(long) == disk)
    #expect(DiskName.kind(of: disk.entry) == .long(sidecar: disk.sidecar!))

    for other in ["dir.v57", "folder.v57", "x.name", ".DS_Store", ".v57tmp-1.long"] {
      #expect(DiskName.kind(of: other) == .other)
    }
  }

  @Test func base64URL() {
    for count in 0..<40 {
      let data = pseudoRandomData(count, seed: UInt64(count))
      let encoded = Base64URL.encode(data)
      #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
      #expect(Base64URL.decode(encoded) == data)
    }
    #expect(Base64URL.decode("a+b") == nil)
  }
}
