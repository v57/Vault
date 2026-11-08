import Foundation

/// The copy of the vault keys that Get, Player and the Hub app read (security audit M4, V3): they list the records group
/// (`VaultConfiguration.recordsGroup`), not the shared one, so they read and write records but never see a password, the
/// device's SSH key or its Hub keys. Every app in the shared group keeps the copy current (`VaultKeychain.mirrorRecordKeys`,
/// from `Vault.startSync`):
///
/// - the synced key items (keys, rotations, id keys, synced marks such as revocations) go one way, shared → records, and
///   one gone from the shared group goes from the copy;
/// - this device's id goes whichever way it's missing, so an app that ran first on the device and made it in the records
///   group keeps the same id as the rest.
///
/// A records-only app never adds a synced item to the copy (`ReadOnlySyncedKeyItems`): it can't make a vault key, so it
/// waits for one rather than starting a vault of its own.
enum VaultRecordsMirror {
  static let syncedPrefixes = [VaultKeyRing.keyPrefix, VaultKeyRing.epochPrefix, VaultKeyRing.idKeyPrefix, VaultKeyRing.markPrefix]
  static let deviceID = "device-id"

  struct Report: Equatable {
    var written = 0
    var removed = 0
  }

  static func run(from shared: any VaultKeyItems, to records: any VaultKeyItems) throws -> Report {
    var report = Report()
    let source = try shared.all(synced: true).filter { item in syncedPrefixes.contains { item.name.hasPrefix($0) } }
    let names = Set(source.map(\.name))
    for item in source where try records.read(item.name, synced: true) != item.data {
      let label = try shared.label(of: item.name, synced: true) ?? "v57 Vault key"
      try records.replace(item.data, named: item.name, synced: true, label: label)
      report.written += 1
    }
    for item in try records.all(synced: true)
    where syncedPrefixes.contains(where: { item.name.hasPrefix($0) }) && !names.contains(item.name) {
      try records.delete(item.name, synced: true)
      report.removed += 1
    }
    switch (try shared.read(deviceID, synced: false), try records.read(deviceID, synced: false)) {
    case (let id?, let copy) where copy != id:
      try records.replace(id, named: deviceID, synced: false, label: "v57 device id")
      report.written += 1
    case (nil, let id?):
      _ = try shared.add(id, named: deviceID, synced: false, label: "v57 device id")
      report.written += 1
    default: break
    }
    return report
  }
}

/// The records group as a records-only app sees it: it reads everything, and writes only this device's items.
struct ReadOnlySyncedKeyItems: VaultKeyItems {
  let items: any VaultKeyItems

  struct ReadOnly: LocalizedError {
    var errorDescription: String? {
      "This app gets the vault’s keys from Vault or another v57 app on this device. Open one of them once."
    }
  }

  func all(synced: Bool) throws -> [(name: String, data: Data)] { try items.all(synced: synced) }
  func read(_ name: String, synced: Bool) throws -> Data? { try items.read(name, synced: synced) }
  func label(of name: String, synced: Bool) throws -> String? { try items.label(of: name, synced: synced) }

  func add(_ data: Data, named name: String, synced: Bool, label: String) throws -> Bool {
    guard !synced else { throw ReadOnly() }
    return try items.add(data, named: name, synced: synced, label: label)
  }

  func replace(_ data: Data, named name: String, synced: Bool, label: String) throws {
    guard !synced else { throw ReadOnly() }
    try items.replace(data, named: name, synced: synced, label: label)
  }

  func delete(_ name: String, synced: Bool) throws {
    guard !synced else { throw ReadOnly() }
    try items.delete(name, synced: synced)
  }
}

#if canImport(Security)
  extension VaultKeychain {
    /// Brings the records group's copy of the vault keys up to date (`VaultRecordsMirror`). Only an app in both the shared
    /// and the records group does anything; it's cheap when nothing changed.
    @discardableResult
    public static func mirrorRecordKeys() -> Bool {
      guard isShared, isEntitled(to: VaultConfiguration.recordsGroup), !VaultSecrets.isInMemory else { return false }
      let shared = KeychainKeyItems(keychain: VaultKeychain())
      let records = KeychainKeyItems(keychain: VaultKeychain(accessGroup: VaultConfiguration.recordsGroup))
      return (try? VaultRecordsMirror.run(from: shared, to: records)) != nil
    }
  }
#endif
