import Foundation
import Testing

@testable import VaultKit

/// Security audit M5: the Windows Credential Manager caps an item at 2,560 bytes. The pieces logic, over a capped store in
/// memory (the Windows backend runs it in `PortableKeychainTests` on Windows).
struct CredentialChunksTests {
  final class Capped: CredentialBlobs, @unchecked Sendable {
    let limit: Int
    var items: [String: Data] = [:]
    var failWrites = false
    init(limit: Int) { self.limit = limit }

    struct TooBig: Error {}
    struct Failed: Error {}

    func read(_ target: String) throws -> Data? { items[target] }
    func write(_ target: String, _ data: Data, label: String?) throws {
      guard data.count <= limit else { throw TooBig() }
      guard !failWrites else { throw Failed() }
      items[target] = data
    }
    func delete(_ target: String) throws { items[target] = nil }
    func all(_ prefix: String) throws -> [(target: String, data: Data)] {
      items.filter { $0.key.hasPrefix(prefix) }.map { ($0.key, $0.value) }
    }
  }

  private func bytes(_ count: Int, seed: UInt8 = 3) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &* seed }) }

  @Test func anItemPastTheCapComesBackWhole() throws {
    let store = Capped(limit: 2_560)
    let chunked = ChunkedCredentials(blobs: store, limit: store.limit)
    // About 70 logins' worth of an account's secrets list, which stopped being recorded before.
    let list = Data((0..<80).map { _ in "login.\(UUID().uuidString)" }.joined(separator: "\n").utf8)
    #expect(list.count > 2_560)
    try chunked.write("svc|device|account-secrets.a", list, label: "list")
    #expect(try chunked.read("svc|device|account-secrets.a") == list)
    // Listing the group shows the item once, whole, and none of its pieces.
    let all = try chunked.all("svc|device|")
    #expect(all.count == 1 && all[0].data == list)
    #expect(store.items.keys.filter { $0.hasPrefix("svc|") }.count == 1)

    // Exactly at the cap stays one item; one byte more is pieces.
    try chunked.write("svc|device|edge", bytes(2_560), label: nil)
    #expect(store.items["svc|device|edge"] == bytes(2_560))
    try chunked.write("svc|device|edge", bytes(2_561), label: nil)
    #expect(try chunked.read("svc|device|edge") == bytes(2_561))
  }

  @Test func rewritesAndDeletesLeaveNoPieces() throws {
    let store = Capped(limit: 100)
    let chunked = ChunkedCredentials(blobs: store, limit: store.limit)
    try chunked.write("t", bytes(1_000), label: nil)
    #expect(store.items.count == 11)
    try chunked.write("t", bytes(250, seed: 5), label: nil)
    #expect(store.items.count == 4)
    #expect(try chunked.read("t") == bytes(250, seed: 5))
    try chunked.write("t", Data("small".utf8), label: nil)
    #expect(store.items == ["t": Data("small".utf8)])
    try chunked.write("t", bytes(300), label: nil)
    try chunked.delete("t")
    #expect(store.items.isEmpty)
  }

  /// A write that fails halfway leaves the old value readable.
  @Test func aFailedWriteKeepsTheOldValue() throws {
    final class FailAfter: CredentialBlobs, @unchecked Sendable {
      let inner: Capped
      var writesLeft: Int
      init(_ inner: Capped, writesLeft: Int) { self.inner = inner; self.writesLeft = writesLeft }
      func read(_ target: String) throws -> Data? { try inner.read(target) }
      func write(_ target: String, _ data: Data, label: String?) throws {
        guard writesLeft > 0 else { throw Capped.Failed() }
        writesLeft -= 1
        try inner.write(target, data, label: label)
      }
      func delete(_ target: String) throws { try inner.delete(target) }
      func all(_ prefix: String) throws -> [(target: String, data: Data)] { try inner.all(prefix) }
    }
    let store = Capped(limit: 100)
    try ChunkedCredentials(blobs: store, limit: 100).write("t", bytes(500), label: nil)
    let failing = FailAfter(store, writesLeft: 3)
    #expect(throws: Capped.Failed.self) { try ChunkedCredentials(blobs: failing, limit: 100).write("t", bytes(900, seed: 7), label: nil) }
    #expect(try ChunkedCredentials(blobs: store, limit: 100).read("t") == bytes(500))
  }

  /// A value that happens to start like a header is kept in pieces too, so it reads back as itself.
  @Test func aValueThatLooksLikeAHeaderRoundTrips() throws {
    let store = Capped(limit: 2_560)
    let chunked = ChunkedCredentials(blobs: store, limit: store.limit)
    let tricky = ChunkedCredentials<Capped>.magic + Data(repeating: 1, count: 70)
    try chunked.write("t", tricky, label: nil)
    #expect(try chunked.read("t") == tricky)
    // A piece gone shows as damage, not as a wrong value.
    let piece = try #require(store.items.keys.first { $0.hasPrefix("v57-piece|") })
    store.items[piece] = nil
    #expect(throws: (any Error).self) { try chunked.read("t") }
  }
}
