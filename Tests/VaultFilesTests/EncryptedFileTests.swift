import CryptoKit
import Foundation
import Testing

@testable import VaultFiles

/// A temporary directory removed when the test ends.
final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("VaultFilesTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

func pseudoRandomData(_ count: Int, seed: UInt64 = 1) -> Data {
  var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
  var data = Data(count: count)
  data.withUnsafeMutableBytes { buffer in
    for index in 0..<count {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      buffer[index] = UInt8(truncatingIfNeeded: state)
    }
  }
  return data
}

struct EncryptedFileTests {
  let key = SymmetricKey(size: .bits256)
  let chunk = EncryptedFile.defaultChunkSize
  var sizes: [Int] { [0, 1, chunk - 1, chunk, chunk + 1, 2 * chunk, 3 * 1024 * 1024 + 17] }

  @Test func wholeDataRoundTrips() throws {
    for size in sizes {
      let plaintext = pseudoRandomData(size, seed: UInt64(size))
      let sealed = try EncryptedFile.seal(plaintext, key: key, keyID: "k1")
      #expect(sealed.starts(with: EncryptedFile.magic))
      #expect(Int64(sealed.count) == EncryptedFile.ciphertextSize(plaintextSize: Int64(size), headerSize: EncryptedFile.Header.size(keyID: "k1")))
      #expect(try EncryptedFile.open(sealed, key: key) == plaintext)
      #expect(EncryptedFile.plaintextSize(ciphertextSize: Int64(sealed.count), headerSize: EncryptedFile.Header.size(keyID: "k1")) == Int64(size))
      #expect(try EncryptedFile.Header(parsing: sealed).keyID == "k1")
    }
  }

  @Test func sealingTwiceDiffers() throws {
    let plaintext = Data("same".utf8)
    #expect(try EncryptedFile.seal(plaintext, key: key, keyID: "k") != EncryptedFile.seal(plaintext, key: key, keyID: "k"))
  }

  @Test func streamingRoundTripsAndMatchesWholeData() throws {
    let directory = try TemporaryDirectory()
    for size in sizes {
      let plaintext = pseudoRandomData(size, seed: UInt64(size) + 7)
      let source = directory.file("plain-\(size)")
      let sealed = directory.file("sealed-\(size)")
      let opened = directory.file("opened-\(size)")
      try plaintext.write(to: source)
      let digest = try EncryptedFile.sealFile(source, to: sealed, key: key, keyID: "k1")
      #expect(digest == SHA256.hash(data: plaintext))
      #expect(try EncryptedFile.open(Data(contentsOf: sealed), key: key) == plaintext)
      #expect(try EncryptedFile.plaintextSize(of: sealed) == Int64(size))
      try EncryptedFile.open(contentsOf: sealed, to: opened, key: key)
      #expect(try Data(contentsOf: opened) == plaintext)
      // The whole-data form reads what streaming wrote, and streaming reads what it wrote.
      try EncryptedFile.seal(plaintext, key: key, keyID: "k1").write(to: sealed)
      try EncryptedFile.open(contentsOf: sealed, to: opened, key: key)
      #expect(try Data(contentsOf: opened) == plaintext)
    }
  }

  @Test func plaintextSizesOfImpossibleLengthsAreNil() {
    let header = 40
    #expect(EncryptedFile.plaintextSize(ciphertextSize: Int64(header + 15), headerSize: header) == nil)
    #expect(EncryptedFile.plaintextSize(ciphertextSize: Int64(header + 16), headerSize: header) == 0)
    // A full chunk followed by an empty one is never written.
    #expect(EncryptedFile.plaintextSize(ciphertextSize: Int64(header + chunk + 32), headerSize: header) == nil)
    #expect(EncryptedFile.plaintextSize(ciphertextSize: Int64(header + chunk + 33), headerSize: header) == Int64(chunk + 1))
  }

  @Test func changingAnyByteFails() throws {
    let plaintext = pseudoRandomData(2 * chunk + 100)
    let sealed = try EncryptedFile.seal(plaintext, key: key, keyID: "k1")
    let header = EncryptedFile.Header.size(keyID: "k1")
    // Every header byte, and a spread of body bytes in every chunk and tag.
    let offsets = Array(0..<header) + stride(from: header, to: sealed.count, by: 997).map { $0 } + [sealed.count - 1]
    for offset in offsets {
      var damaged = sealed
      damaged[offset] ^= 0x01
      #expect(throws: (any Error).self, "byte \(offset)") { try EncryptedFile.open(damaged, key: key) }
    }
  }

  @Test func swappingChunksFails() throws {
    let plaintext = pseudoRandomData(3 * chunk)
    let sealed = try EncryptedFile.seal(plaintext, key: key, keyID: "k1")
    let header = EncryptedFile.Header.size(keyID: "k1")
    let full = chunk + EncryptedFile.tagSize
    let first = sealed[header..<header + full]
    let second = sealed[header + full..<header + 2 * full]
    var swapped = sealed.prefix(header)
    swapped.append(second)
    swapped.append(first)
    swapped.append(sealed[(header + 2 * full)...])
    #expect(swapped.count == sealed.count)
    #expect(throws: VaultFilesError.damaged) { try EncryptedFile.open(swapped, key: key) }
  }

  @Test func truncationFails() throws {
    let plaintext = pseudoRandomData(2 * chunk + 10)
    let sealed = try EncryptedFile.seal(plaintext, key: key, keyID: "k1")
    let header = EncryptedFile.Header.size(keyID: "k1")
    let full = chunk + EncryptedFile.tagSize
    // Cut at a chunk boundary: the remaining chunks parse, but the new last one wasn't sealed as last.
    #expect(throws: VaultFilesError.damaged) { try EncryptedFile.open(sealed.prefix(header + 2 * full), key: key) }
    #expect(throws: VaultFilesError.damaged) { try EncryptedFile.open(sealed.prefix(header + full), key: key) }
    #expect(throws: VaultFilesError.damaged) { try EncryptedFile.open(sealed.prefix(sealed.count - 1), key: key) }
    #expect(throws: VaultFilesError.damaged) { try EncryptedFile.open(sealed.prefix(header), key: key) }
    #expect(throws: (any Error).self) { try EncryptedFile.open(sealed.prefix(5), key: key) }
    // An appended chunk fails too.
    #expect(throws: VaultFilesError.damaged) { try EncryptedFile.open(sealed + sealed.suffix(full), key: key) }
  }

  @Test func wrongKeyFails() throws {
    for size in [0, 10, chunk + 1] {
      let sealed = try EncryptedFile.seal(pseudoRandomData(size), key: key, keyID: "k1")
      #expect(throws: VaultFilesError.damaged) { try EncryptedFile.open(sealed, key: SymmetricKey(size: .bits256)) }
    }
  }

  @Test func notEncryptedAndNewerVersions() throws {
    #expect(throws: VaultFilesError.notEncrypted) { try EncryptedFile.open(Data("hello world".utf8), key: key) }
    var sealed = try EncryptedFile.seal(Data("x".utf8), key: key, keyID: "k1")
    sealed[8] = 9
    #expect(throws: VaultFilesError.unsupportedVersion(9)) { try EncryptedFile.open(sealed, key: key) }
  }

  @Test func damagedStreamingLeavesNoOutput() throws {
    let directory = try TemporaryDirectory()
    var sealed = try EncryptedFile.seal(pseudoRandomData(chunk * 2), key: key, keyID: "k1")
    sealed[sealed.count - 3] ^= 0xff
    try sealed.write(to: directory.file("sealed"))
    #expect(throws: VaultFilesError.damaged) {
      try EncryptedFile.open(contentsOf: directory.file("sealed"), to: directory.file("out"), key: self.key)
    }
    #expect(!FileManager.default.fileExists(atPath: directory.file("out").path))
  }

  @Test func rangeReadsMatch() throws {
    let directory = try TemporaryDirectory()
    let small = 300
    let plaintext = pseudoRandomData(5 * chunk + 123)
    for chunkSize in [small, chunk] {
      let url = directory.file("sealed-\(chunkSize)")
      try EncryptedFile.seal(plaintext, key: key, keyID: "k1", chunkSize: chunkSize).write(to: url)
      let reader = try EncryptedFileReader(url: url, key: key)
      #expect(reader.size == Int64(plaintext.count))
      #expect(try reader.readAll() == plaintext)
      let count = Int64(plaintext.count)
      let c = Int64(chunkSize)
      let ranges: [Range<Int64>] = [
        0..<0, 0..<1, 0..<c, c - 1..<c + 1, c..<2 * c, 5..<3 * c + 7, count - 1..<count, count - 10..<count + 50,
        count..<count + 10, 12_345..<98_765,
      ]
      for range in ranges {
        let lower = Int(min(range.lowerBound, count))
        let upper = Int(min(range.upperBound, count))
        #expect(try reader.read(range: range) == plaintext[lower..<upper], "\(range)")
      }
    }
    // An empty file reads as empty.
    try EncryptedFile.seal(Data(), key: key, keyID: "k1").write(to: directory.file("empty"))
    let empty = try EncryptedFileReader(url: directory.file("empty"), key: key)
    #expect(empty.size == 0)
    #expect(try empty.read(range: 0..<10) == Data())
  }

  @Test func rangeReadsDetectDamageInTheirChunks() throws {
    let directory = try TemporaryDirectory()
    let plaintext = pseudoRandomData(3 * chunk)
    var sealed = try EncryptedFile.seal(plaintext, key: key, keyID: "k1")
    let header = EncryptedFile.Header.size(keyID: "k1")
    sealed[header + chunk + EncryptedFile.tagSize + 5] ^= 1  // in the second chunk
    try sealed.write(to: directory.file("sealed"))
    let reader = try EncryptedFileReader(url: directory.file("sealed"), key: key)
    #expect(try reader.read(range: 0..<100) == plaintext.prefix(100))
    #expect(throws: VaultFilesError.damaged) { try reader.read(range: Int64(chunk)..<Int64(chunk) + 10) }
    // Reading the end of a file cut at a chunk boundary fails.
    try EncryptedFile.seal(plaintext, key: key, keyID: "k1").prefix(header + 2 * (chunk + 16)).write(to: directory.file("cut"))
    let cut = try EncryptedFileReader(url: directory.file("cut"), key: key)
    #expect(throws: VaultFilesError.damaged) { try cut.read(range: cut.size - 1..<cut.size) }
  }
}
