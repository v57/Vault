import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Findings X2 and U6 of the second review: what an old app on this device wrote after the migration.
struct OldFileImportTests {
  let keys = MemoryKeyProvider()

  private func oldStore() throws -> OldBuildStore {
    let old = try OldBuildStore(keys: keys, device: "mac")
    try old.save(id: "h", kind: "host", changes: ["name": .string("first")])
    return old
  }

  /// X2: a rotation retires a key on the server and in the old file alike.
  @Test func anOldAppsWriteUnderARetiredKeyDoesntComeOver() throws {
    let old = try oldStore()
    _ = try openStore(old.directory, keys: keys)
    try keys.rotate(kitCheck: nil)
    try old.save(id: "late", kind: "host", changes: ["a": .string("1")])
    try old.save(id: "h", kind: "host", changes: ["byOld": .string("1")])

    let again = try openStore(old.directory, keys: keys)
    #expect(try again.item(id: "late") == nil)
    #expect(try again.item(id: "h")?.fields["byOld"] == nil)
    #expect(again.formatStatus.refused == 2)
    // Once.
    let versions = try again.meta("format.imported")
    #expect(try openStore(old.directory, keys: keys).meta("format.imported") == versions)
  }
}
