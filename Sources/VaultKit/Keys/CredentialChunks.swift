import Foundation

import CryptoKit

/// A store of raw blobs with a size cap, as the Windows Credential Manager is (2,560 bytes an item:
/// `CRED_MAX_CREDENTIAL_BLOB_SIZE`).
protocol CredentialBlobs {
  func read(_ target: String) throws -> Data?
  func write(_ target: String, _ data: Data, label: String?) throws
  func delete(_ target: String) throws
  /// Every target starting with `prefix`, with its blob.
  func all(_ prefix: String) throws -> [(target: String, data: Data)]
}

/// Items of any size over a capped store (security audit M5: an account's secrets list passes 2,560 bytes at about 70
/// logins, and a passkey or an identity can too). An item that fits is kept as it is, as before; a larger one becomes a
/// header under its own name and its pieces under names outside every prefix, so listing an item's group never shows
/// them. The pieces of each write have a generation of their own and the header names it and the whole value's hash: the
/// header is written last, so a reader sees the old value or the new one, never a mix, and a failed write leaves the old
/// one.
struct ChunkedCredentials<Blobs: CredentialBlobs> {
  let blobs: Blobs
  /// The store's cap.
  let limit: Int

  /// Starts a header: a value that starts with it is always kept in pieces, so a stored value is never mistaken for one.
  static var magic: Data { Data([0, 0x76, 0x35, 0x37, 0x63, 0x68, 0x75, 0x6E, 0x6B, 0x73, 0, 1]) }  // \0 "v57chunks" \0 1

  struct Header {
    var generation: String
    var count: Int
    var length: Int
    var hash: Data

    var data: Data {
      var data = ChunkedCredentials.magic
      data += Data(generation.utf8)
      for value in [UInt32(count), UInt32(length)] { withUnsafeBytes(of: value.bigEndian) { data += Data($0) } }
      return data + hash
    }

    init(generation: String, count: Int, length: Int, hash: Data) {
      self.generation = generation
      self.count = count
      self.length = length
      self.hash = hash
    }

    init?(_ data: Data) {
      let magic = ChunkedCredentials.magic
      let bytes = [UInt8](data)
      guard bytes.count == magic.count + 32 + 8 + 32, Data(bytes.prefix(magic.count)) == magic else { return nil }
      var index = magic.count
      generation = String(decoding: bytes[index..<(index + 32)], as: UTF8.self)
      index += 32
      func number() -> Int {
        defer { index += 4 }
        return bytes[index..<(index + 4)].reduce(0) { $0 << 8 | Int($1) }
      }
      count = number()
      length = number()
      hash = Data(bytes[index...])
    }
  }

  struct Damaged: Error {}

  /// Where piece `index` of a write is kept.
  static func piece(_ target: String, generation: String, _ index: Int) -> String {
    "v57-piece|\(generation)|\(index)|\(target)"
  }

  func read(_ target: String) throws -> Data? {
    guard let stored = try blobs.read(target) else { return nil }
    guard let header = Header(stored) else { return stored }
    return try assemble(target, header)
  }

  private func assemble(_ target: String, _ header: Header) throws -> Data {
    var data = Data()
    for index in 0..<header.count {
      guard let piece = try blobs.read(Self.piece(target, generation: header.generation, index)) else { throw Damaged() }
      data += piece
    }
    guard data.count == header.length, Data(SHA256.hash(data: data)) == header.hash else { throw Damaged() }
    return data
  }

  func write(_ target: String, _ data: Data, label: String?) throws {
    let old = try blobs.read(target).flatMap(Header.init)
    if data.count <= limit, !data.starts(with: Self.magic) {
      try blobs.write(target, data, label: label)
    } else {
      let generation = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      var count = 0
      var offset = data.startIndex
      repeat {
        let end = min(offset + limit, data.endIndex)
        try blobs.write(Self.piece(target, generation: generation, count), Data(data[offset..<end]), label: nil)
        offset = end
        count += 1
      } while offset < data.endIndex
      let header = Header(generation: generation, count: count, length: data.count, hash: Data(SHA256.hash(data: data)))
      try blobs.write(target, header.data, label: label)
    }
    if let old { removePieces(target, old) }
  }

  func delete(_ target: String) throws {
    let old = try blobs.read(target).flatMap(Header.init)
    try blobs.delete(target)
    if let old { removePieces(target, old) }
  }

  func all(_ prefix: String) throws -> [(target: String, data: Data)] {
    try blobs.all(prefix).map { item in
      guard let header = Header(item.data) else { return item }
      return (item.target, try assemble(item.target, header))
    }
  }

  private func removePieces(_ target: String, _ header: Header) {
    for index in 0..<header.count { try? blobs.delete(Self.piece(target, generation: header.generation, index)) }
  }
}
