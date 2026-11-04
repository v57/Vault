import CryptoKit
import Foundation

@testable import VaultKit

/// A store on memory keys in a test's folder, with the format's clock and stages in the test's hands.
func openStore(
  _ directory: URL = temporaryDirectory(), keys: VaultKeyProvider, device: String = "mac", fileName: String = VaultStore.fileName,
  account: String? = nil, testing: FormatTesting = FormatTesting()
) throws -> VaultStore {
  try VaultStore(
    directory: directory, fileName: fileName, accountID: account, keys: keys, deviceID: device, notifier: nil, owner: "test",
    formatTesting: testing)
}

/// Fields as a device wrote them, at a time the test picks.
func stampedFields(_ changes: [String: JSONValue], device: String = "pad", at date: Date = .now) -> ItemFields {
  var fields = ItemFields()
  _ = fields.apply(changes, clock: HybridClock.zero.next(now: date, device: device))
  return fields
}

/// A record as an old build sends it.
func format1Remote(
  _ id: String, tag: String = "t1", keys: VaultKeyProvider, device: String = "pad", kind: String = "host",
  changes: [String: JSONValue] = ["name": .string("from an old build")], at date: Date = .now
) throws -> RemoteRecord {
  let sealed = try OldBuildStore.format1(id: id, kind: kind, fields: stampedFields(changes, device: device, at: date), keys: keys)
  return RemoteRecord(id: id, keyID: sealed.keyID, payload: sealed.payload, changeTag: tag, systemFields: Data(tag.utf8))
}

/// A store's row as CloudKit would hand it to another device.
func sealedRemote(_ store: VaultStore, _ id: String, tag: String = "t") throws -> RemoteRecord {
  let row = try store.database.query("SELECT key_id, payload FROM items WHERE id = ?", [.text(id)])[0]
  return RemoteRecord(id: id, keyID: row[0].text ?? "", payload: row[1].blob ?? Data(), changeTag: tag, systemFields: nil)
}

/// Clears what a store has waiting to go up, as if it had all landed.
func markEverythingSent(_ store: VaultStore) throws {
  try store.database.query("DELETE FROM outbox")
}
