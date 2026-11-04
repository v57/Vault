import CryptoKit
import Foundation

@testable import VaultKit

/// A keychain that can be out of reach, as it is before first unlock, and that counts how often it's read.
final class FlakyKeys: VaultKeyProvider, @unchecked Sendable {
  let base: MemoryKeyProvider
  var failing = false
  /// Keys that can't be read while the rest can.
  var failingIDs: Set<String> = []
  var reads = 0

  init(_ base: MemoryKeyProvider) { self.base = base }

  private func check() throws { if failing { throw VaultKeychain.KeychainError.status(-25308) } }
  func primary() throws -> (id: String, key: SymmetricKey) { try check(); return try base.primary() }
  func key(id: String) throws -> SymmetricKey? {
    try check()
    if failingIDs.contains(id) { throw VaultKeychain.KeychainError.status(-25308) }
    reads += 1
    return try base.key(id: id)
  }
  var allKeys: [String: SymmetricKey] { get throws { try check(); reads += 1; return base.allKeys } }
  var keyEpochs: [VaultKeyEpoch] { get throws { try check(); return try base.keyEpochs } }
  func rotate(kitCheck: String?) throws -> VaultKeyEpoch { try check(); return try base.rotate(kitCheck: kitCheck) }
  func kitCheck(forKey id: String) throws -> String? { try check(); return try base.kitCheck(forKey: id) }
  func isRetired(_ id: String) throws -> Bool { try check(); return try base.isRetired(id) }
  func addKeys(_ keys: [String: SymmetricKey]) throws { try check(); try base.addKeys(keys) }
  func stableIDKey() throws -> SymmetricKey { try check(); return try base.stableIDKey() }
  func stableIDKeySource() throws -> String? { try check(); return try base.stableIDKeySource() }
  func restoreStableIDKey(_ key: SymmetricKey) throws { try check(); try base.restoreStableIDKey(key) }
  func marks(prefix: String, synced: Bool) throws -> [(name: String, data: Data)] {
    try check()
    return try base.marks(prefix: prefix, synced: synced)
  }
  func setMark(_ name: String, data: Data, synced: Bool) throws { try check(); try base.setMark(name, data: data, synced: synced) }
  func removeMark(_ name: String, synced: Bool) throws { try check(); try base.removeMark(name, synced: synced) }
}
