import Foundation

/// When and where one field of an item was last written: what an item's "Changes" list shows
/// ("Password · Oct 12 · Studio Mac"). Read from the field's clock (`HybridClock`).
public struct VaultFieldChange: Sendable, Hashable {
  public var field: String
  public var date: Date
  /// The id of the device that wrote it; `Vault.deviceName(for:)` names it.
  public var device: String
  /// Whether the value came from merging two devices' edits of a text field (`TextMerge`); `device` is then
  /// the one whose edit was later.
  public var merged: Bool
  public var clock: HybridClock

  public init(field: String, clock: HybridClock) {
    self.field = field
    self.clock = clock
    date = Date(timeIntervalSince1970: Double(clock.millis) / 1000)
    var device = clock.device
    merged = false
    while device.hasSuffix("+merge") {
      device.removeLast("+merge".count)
      merged = true
    }
    self.device = device
  }
}

extension VaultStore {
  /// Each field's last write, by field name, bookkeeping fields (`_deleted`) left out. Empty when there is
  /// no such item.
  public func fieldChanges(id: String) throws -> [String: VaultFieldChange] {
    guard let item = try item(id: id) else { return [:] }
    var changes: [String: VaultFieldChange] = [:]
    for (key, stamped) in item.fields.stamped where !key.hasPrefix("_") {
      changes[key] = VaultFieldChange(field: key, clock: stamped.clock)
    }
    return changes
  }
}

extension Vault {
  /// The name of a device that published its key (`VaultDeviceKey`), nil for one that hasn't.
  public func deviceName(for deviceID: String) -> String? {
    deviceKeys.first { $0.id == deviceID }?.deviceName.nilIfEmpty
  }

  /// Each field's last write for an item (`VaultStore.fieldChanges(id:)`).
  public func fieldChanges(id: String) -> [String: VaultFieldChange] {
    (try? store?.fieldChanges(id: id)) ?? [:]
  }
}
