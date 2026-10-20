import CryptoKit
import Foundation

/// The encrypted file format: `EncryptedNote`'s single AES-GCM box generalized to any size, the way age and Tink's
/// streaming AEAD do it, so files stream in and out and can be read at any offset.
///
/// ```
/// header   "V57FILE1" · version (1) · chunk size (UInt32 BE) · file id (16) · nonce prefix (7) · key id length (1) · key id
/// chunks   AES-256-GCM(chunk of `chunkSize` plaintext bytes) + 16-byte tag, the last one shorter (possibly empty)
/// ```
///
/// Each file gets its own key, derived with HKDF from the content key and the random file id, so nonces only
/// need to be unique within a file. A chunk's nonce is the file's nonce prefix, the chunk index (UInt32 BE) and a
/// last-chunk flag byte; every chunk authenticates the header. Reordered chunks fail (wrong index), a file cut at a
/// chunk boundary fails (its new last chunk wasn't sealed as last), and a changed header fails every chunk. Every
/// file has at least one chunk, so an empty file is a header and a 16-byte tag.
public enum EncryptedFile {
  public static let magic = Data("V57FILE1".utf8)
  public static let version: UInt8 = 1
  /// Plaintext bytes per chunk.
  public static let defaultChunkSize = 64 * 1024
  /// The AES-GCM tag after each chunk.
  public static let tagSize = 16
  static let fileIDSize = 16
  static let noncePrefixSize = 7
  /// A header larger chunk sizes than this claim is damaged (and would make readers allocate too much).
  static let maxChunkSize = 16 * 1024 * 1024
  static let fixedHeaderSize = 8 + 1 + 4 + fileIDSize + noncePrefixSize + 1
  static let maxHeaderSize = fixedHeaderSize + 255

  /// A file's header: its chunk size, its random id and nonce prefix, and the id of the key that sealed it.
  public struct Header: Sendable, Equatable {
    public let version: UInt8
    public let chunkSize: Int
    public let fileID: Data
    public let noncePrefix: Data
    public let keyID: String
    /// The header's bytes, authenticated by every chunk.
    public let encoded: Data

    /// The header's length in bytes; the first chunk starts here.
    public var size: Int { encoded.count }

    /// A new header with a random file id and nonce prefix.
    public init(keyID: String, chunkSize: Int = EncryptedFile.defaultChunkSize) throws {
      let keyIDData = Data(keyID.utf8)
      guard keyIDData.count <= 255, chunkSize > 0, chunkSize <= EncryptedFile.maxChunkSize else {
        throw VaultFilesError.invalidName(keyID)
      }
      self.version = EncryptedFile.version
      self.chunkSize = chunkSize
      self.fileID = randomBytes(EncryptedFile.fileIDSize)
      self.noncePrefix = randomBytes(EncryptedFile.noncePrefixSize)
      self.keyID = keyID
      var encoded = EncryptedFile.magic
      encoded.append(version)
      encoded.append(contentsOf: bigEndianBytes(UInt32(chunkSize)))
      encoded.append(fileID)
      encoded.append(noncePrefix)
      encoded.append(UInt8(keyIDData.count))
      encoded.append(keyIDData)
      self.encoded = encoded
    }

    /// Reads the header at the start of `data` (which may hold more after it).
    public init(parsing data: Data) throws {
      let bytes = [UInt8](data.prefix(EncryptedFile.maxHeaderSize))
      guard bytes.count >= EncryptedFile.magic.count, Data(bytes.prefix(8)) == EncryptedFile.magic else {
        throw VaultFilesError.notEncrypted
      }
      guard bytes.count >= EncryptedFile.fixedHeaderSize else { throw VaultFilesError.damaged }
      guard bytes[8] == EncryptedFile.version else { throw VaultFilesError.unsupportedVersion(Int(bytes[8])) }
      let chunkSize = Int(bytes[9]) << 24 | Int(bytes[10]) << 16 | Int(bytes[11]) << 8 | Int(bytes[12])
      guard chunkSize > 0, chunkSize <= EncryptedFile.maxChunkSize else { throw VaultFilesError.damaged }
      var offset = 13
      let fileID = Data(bytes[offset..<offset + EncryptedFile.fileIDSize])
      offset += EncryptedFile.fileIDSize
      let prefix = Data(bytes[offset..<offset + EncryptedFile.noncePrefixSize])
      offset += EncryptedFile.noncePrefixSize
      let keyIDLength = Int(bytes[offset])
      offset += 1
      guard bytes.count >= offset + keyIDLength,
        let keyID = String(bytes: bytes[offset..<offset + keyIDLength], encoding: .utf8)
      else { throw VaultFilesError.damaged }
      self.version = bytes[8]
      self.chunkSize = chunkSize
      self.fileID = fileID
      self.noncePrefix = prefix
      self.keyID = keyID
      self.encoded = Data(bytes[0..<offset + keyIDLength])
    }

    /// The size of a header for this key id.
    public static func size(keyID: String) -> Int { EncryptedFile.fixedHeaderSize + Data(keyID.utf8).count }
  }

  // MARK: Sizes

  /// The number of chunks a plaintext of `size` bytes takes (at least one).
  public static func chunkCount(plaintextSize size: Int64, chunkSize: Int = defaultChunkSize) -> Int64 {
    max(1, (size + Int64(chunkSize) - 1) / Int64(chunkSize))
  }

  /// The encrypted size of a plaintext of `size` bytes.
  public static func ciphertextSize(plaintextSize size: Int64, headerSize: Int, chunkSize: Int = defaultChunkSize)
    -> Int64
  {
    Int64(headerSize) + size + chunkCount(plaintextSize: size, chunkSize: chunkSize) * Int64(tagSize)
  }

  /// The plaintext size of an encrypted file of `size` bytes, or nil when no plaintext has that encrypted size.
  public static func plaintextSize(ciphertextSize size: Int64, headerSize: Int, chunkSize: Int = defaultChunkSize)
    -> Int64?
  {
    let body = size - Int64(headerSize)
    let fullChunk = Int64(chunkSize + tagSize)
    guard body >= Int64(tagSize) else { return nil }
    let chunks = (body + fullChunk - 1) / fullChunk
    let lastChunk = body - (chunks - 1) * fullChunk
    // Only the empty file has an empty last chunk.
    guard lastChunk > Int64(tagSize) || chunks == 1 else { return nil }
    return body - chunks * Int64(tagSize)
  }

  /// The plaintext size of the encrypted file at `url`, from its header and length (nothing is decrypted).
  public static func plaintextSize(of url: URL) throws -> Int64 {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let header = try Header(parsing: try handle.read(upToCount: maxHeaderSize) ?? Data())
    let length = Int64(try handle.seekToEnd())
    guard let size = plaintextSize(ciphertextSize: length, headerSize: header.size, chunkSize: header.chunkSize)
    else { throw VaultFilesError.damaged }
    return size
  }

  // MARK: Whole data

  /// Seals `data` with `key`, naming `keyID` in the header.
  public static func seal(_ data: Data, key: SymmetricKey, keyID: String, chunkSize: Int = defaultChunkSize) throws
    -> Data
  {
    let cipher = try ChunkCipher(header: Header(keyID: keyID, chunkSize: chunkSize), contentKey: key)
    var output = cipher.header.encoded
    output.reserveCapacity(Int(ciphertextSize(plaintextSize: Int64(data.count), headerSize: cipher.header.size, chunkSize: chunkSize)))
    let count = chunkCount(plaintextSize: Int64(data.count), chunkSize: chunkSize)
    guard count <= Int64(UInt32.max) else { throw VaultFilesError.tooLarge }
    for index in 0..<Int(count) {
      let start = data.startIndex + index * chunkSize
      let chunk = data[start..<min(start + chunkSize, data.endIndex)]
      output.append(try cipher.seal(chunk, index: UInt32(index), last: index == Int(count) - 1))
    }
    return output
  }

  /// Opens data sealed by `seal`.
  public static func open(_ data: Data, key: SymmetricKey) throws -> Data {
    let header = try Header(parsing: data)
    guard let size = plaintextSize(ciphertextSize: Int64(data.count), headerSize: header.size, chunkSize: header.chunkSize)
    else { throw VaultFilesError.damaged }
    let cipher = ChunkCipher(header: header, contentKey: key)
    let count = Int(chunkCount(plaintextSize: size, chunkSize: header.chunkSize))
    let fullChunk = header.chunkSize + tagSize
    var output = Data(capacity: Int(size))
    for index in 0..<count {
      let start = data.startIndex + header.size + index * fullChunk
      let chunk = data[start..<min(start + fullChunk, data.endIndex)]
      output.append(try cipher.open(chunk, index: UInt32(index), last: index == count - 1))
    }
    return output
  }

  // MARK: Streaming

  /// Seals the file at `source` into `destination` (replaced if present), one chunk at a time.
  public static func seal(
    contentsOf source: URL, to destination: URL, key: SymmetricKey, keyID: String, chunkSize: Int = defaultChunkSize
  ) throws {
    _ = try sealFile(source, to: destination, key: key, keyID: keyID, chunkSize: chunkSize)
  }

  /// Opens the encrypted file at `source` into `destination` (replaced if present), one chunk at a time.
  public static func open(contentsOf source: URL, to destination: URL, key: SymmetricKey) throws {
    _ = try openFile(source, to: destination, key: key)
  }

  /// Seals `source` into `destination` and returns the plaintext's SHA-256, computed on the bytes it sealed.
  @discardableResult
  static func sealFile(
    _ source: URL, to destination: URL, key: SymmetricKey, keyID: String, chunkSize: Int = defaultChunkSize,
    progress: ((Int64) -> Void)? = nil
  ) throws -> SHA256.Digest {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try createForWriting(destination)
    var finished = false
    defer {
      try? output.close()
      if !finished { try? FileManager.default.removeItem(at: destination) }
    }
    let cipher = try ChunkCipher(header: Header(keyID: keyID, chunkSize: chunkSize), contentKey: key)
    try output.write(contentsOf: cipher.header.encoded)
    var hash = SHA256()
    var index: UInt32 = 0
    var done: Int64 = 0
    var chunk = try input.read(upToCount: chunkSize) ?? Data()
    while true {
      // Read one chunk ahead: the current chunk is the last when nothing follows it.
      let next = chunk.count == chunkSize ? try input.read(upToCount: chunkSize) ?? Data() : Data()
      let last = next.isEmpty
      hash.update(data: chunk)
      try output.write(contentsOf: cipher.seal(chunk, index: index, last: last))
      done += Int64(chunk.count)
      progress?(done)
      if last { break }
      guard index < UInt32.max else { throw VaultFilesError.tooLarge }
      index += 1
      chunk = next
    }
    finished = true
    return hash.finalize()
  }

  /// Opens `source` into `destination` and returns the plaintext's SHA-256.
  @discardableResult
  static func openFile(_ source: URL, to destination: URL, key: SymmetricKey, progress: ((Int64) -> Void)? = nil)
    throws -> SHA256.Digest
  {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let header = try Header(parsing: try input.read(upToCount: maxHeaderSize) ?? Data())
    let length = Int64(try input.seekToEnd())
    guard let size = plaintextSize(ciphertextSize: length, headerSize: header.size, chunkSize: header.chunkSize)
    else { throw VaultFilesError.damaged }
    try input.seek(toOffset: UInt64(header.size))
    let output = try createForWriting(destination)
    var finished = false
    defer {
      try? output.close()
      if !finished { try? FileManager.default.removeItem(at: destination) }
    }
    let cipher = ChunkCipher(header: header, contentKey: key)
    let count = chunkCount(plaintextSize: size, chunkSize: header.chunkSize)
    var hash = SHA256()
    var done: Int64 = 0
    for index in 0..<count {
      let chunk = try input.read(upToCount: header.chunkSize + tagSize) ?? Data()
      let plaintext = try cipher.open(chunk, index: UInt32(index), last: index == count - 1)
      hash.update(data: plaintext)
      try output.write(contentsOf: plaintext)
      done += Int64(plaintext.count)
      progress?(done)
    }
    finished = true
    return hash.finalize()
  }

  private static func createForWriting(_ url: URL) throws -> FileHandle {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    return try FileHandle(forWritingTo: url)
  }
}

/// Reads any range of an encrypted file, decrypting only the chunks it covers.
public final class EncryptedFileReader: @unchecked Sendable {
  public let header: EncryptedFile.Header
  /// The plaintext size.
  public let size: Int64
  private let handle: FileHandle
  private let cipher: ChunkCipher
  private let chunkCount: Int64
  private let lock = NSLock()

  public init(url: URL, key: SymmetricKey) throws {
    handle = try FileHandle(forReadingFrom: url)
    do {
      header = try EncryptedFile.Header(parsing: try handle.read(upToCount: EncryptedFile.maxHeaderSize) ?? Data())
      let length = Int64(try handle.seekToEnd())
      guard
        let size = EncryptedFile.plaintextSize(
          ciphertextSize: length, headerSize: header.size, chunkSize: header.chunkSize)
      else { throw VaultFilesError.damaged }
      self.size = size
    } catch {
      try? handle.close()
      throw error
    }
    cipher = ChunkCipher(header: header, contentKey: key)
    chunkCount = EncryptedFile.chunkCount(plaintextSize: size, chunkSize: header.chunkSize)
  }

  deinit { try? handle.close() }

  /// The plaintext bytes in `range`, clamped to the file's size.
  public func read(range: Range<Int64>) throws -> Data {
    let lower = max(0, min(range.lowerBound, size))
    let upper = max(lower, min(range.upperBound, size))
    let chunkSize = Int64(header.chunkSize)
    // An empty range still checks the chunk it falls in (an empty file's only chunk included).
    let first = min(lower / chunkSize, chunkCount - 1)
    let last = upper > lower ? (upper - 1) / chunkSize : first
    lock.lock()
    defer { lock.unlock() }
    var output = Data(capacity: Int(upper - lower))
    for index in first...last {
      try handle.seek(toOffset: UInt64(Int64(header.size) + index * (chunkSize + Int64(EncryptedFile.tagSize))))
      let chunk = try handle.read(upToCount: header.chunkSize + EncryptedFile.tagSize) ?? Data()
      let plaintext = try cipher.open(chunk, index: UInt32(index), last: index == chunkCount - 1)
      let chunkStart = index * chunkSize
      let from = Int(max(lower, chunkStart) - chunkStart)
      let to = Int(min(upper, chunkStart + Int64(plaintext.count)) - chunkStart)
      if to > from { output.append(plaintext[plaintext.startIndex + from..<plaintext.startIndex + to]) }
    }
    return output
  }

  /// The whole plaintext.
  public func readAll() throws -> Data { try read(range: 0..<size) }
}

/// Seals and opens the chunks of one file.
struct ChunkCipher: Sendable {
  let header: EncryptedFile.Header
  let key: SymmetricKey

  init(header: EncryptedFile.Header, contentKey: SymmetricKey) {
    self.header = header
    key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: contentKey, salt: header.fileID, info: Data("dev.v57.files.chunk".utf8),
      outputByteCount: 32)
  }

  func nonce(index: UInt32, last: Bool) throws -> AES.GCM.Nonce {
    var bytes = header.noncePrefix
    bytes.append(contentsOf: bigEndianBytes(index))
    bytes.append(last ? 1 : 0)
    return try AES.GCM.Nonce(data: bytes)
  }

  func seal(_ chunk: Data, index: UInt32, last: Bool) throws -> Data {
    let box = try AES.GCM.seal(chunk, using: key, nonce: nonce(index: index, last: last), authenticating: header.encoded)
    return box.ciphertext + box.tag
  }

  func open(_ chunk: Data, index: UInt32, last: Bool) throws -> Data {
    let chunk = Data(chunk)
    guard chunk.count >= EncryptedFile.tagSize, chunk.count <= header.chunkSize + EncryptedFile.tagSize,
      last || chunk.count == header.chunkSize + EncryptedFile.tagSize
    else { throw VaultFilesError.damaged }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: nonce(index: index, last: last), ciphertext: chunk.prefix(chunk.count - EncryptedFile.tagSize),
        tag: chunk.suffix(EncryptedFile.tagSize))
      return try AES.GCM.open(box, using: key, authenticating: header.encoded)
    } catch {
      throw VaultFilesError.damaged
    }
  }
}

func bigEndianBytes(_ value: UInt32) -> [UInt8] {
  [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
}

func randomBytes(_ count: Int) -> Data {
  var generator = SystemRandomNumberGenerator()
  return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
}
