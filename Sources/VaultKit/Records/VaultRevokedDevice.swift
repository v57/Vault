import Foundation

/// A device taken out through Lost Device. Removing a device only deletes its records, and one still running a v57 app
/// publishes itself again; this is what keeps a revoked one out, in the record store of each vault.
///
/// The device itself stops publishing when it reads this. One that doesn't (an old build, or someone holding it) can
/// still write a device key while it's in the Apple account, so readers leave it out by id and by key: it shows as not
/// trusted, Macs drop its `authorized_keys` line (`removeStale`), and its host is hidden.
///
/// The record is what shows in the list. What counts is a mark in the synced keychain (`revocationMarkPrefix`), as a
/// CloudKit deletion isn't authenticated and the mark is out of its reach: deleting the record un-revokes nothing. A
/// revocation an old build made after this store's migration has only the record.
public struct VaultRevokedDevice: VaultRecord, Hashable {
  public static let kind = "revokedDevice"

  public var id: String
  public var deviceID: String
  public var name: String
  /// Its `authorized_keys` line as it was, so the sweep finds it and a new id with this key is no way back.
  public var publicKey: String
  public var revoked: Date?

  public init(id: String, deviceID: String, name: String, publicKey: String, revoked: Date? = .now) {
    self.id = id
    self.deviceID = deviceID
    self.name = name
    self.publicKey = publicKey
    self.revoked = revoked?.wholeSeconds
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    deviceID = read.string("deviceID", default: "")
    name = read.string("name", default: "")
    publicKey = read.string("publicKey", default: "")
    revoked = read.date("revoked")
  }

  public var values: [String: JSONValue] {
    [
      "deviceID": .string(deviceID), "name": .string(name), "publicKey": .string(publicKey), "revoked": .init(revoked),
    ]
  }
}

extension VaultStore {
  func revokedDeviceID(_ device: String) throws -> String { try derivedID("revokedDevice|\(device)") }

  /// One per store, as a device is revoked in a vault, not everywhere: `revoked.<store>.<device id>`.
  private var revocationMarkPrefix: String { "revoked.\(accountBinding)." }

  private struct RevocationMark: Codable {
    var name: String
    var publicKey: String
    var revoked: Date?
  }

  private func revocationMarks() throws -> [VaultRevokedDevice] {
    let prefix = revocationMarkPrefix
    return try keys.marks(prefix: prefix, synced: true).compactMap { mark in
      guard let content = try? JSONDecoder().decode(RevocationMark.self, from: mark.data) else { return nil }
      let device = String(mark.name.dropFirst(prefix.count))
      return VaultRevokedDevice(
        id: (try? revokedDeviceID(device)) ?? "revoked.\(device)", deviceID: device, name: content.name,
        publicKey: content.publicKey, revoked: content.revoked)
    }
  }

  private func setRevocationMark(_ device: VaultRevokedDevice) throws {
    let content = RevocationMark(name: device.name, publicKey: device.publicKey, revoked: device.revoked)
    try keys.setMark(revocationMarkPrefix + device.deviceID, data: try JSONEncoder().encode(content), synced: true)
  }

  /// Every revoked device: the marks, and any record with no mark.
  public func revokedDevices() throws -> [VaultRevokedDevice] {
    let marks = try revocationMarks()
    let marked = Set(marks.map(\.deviceID))
    return try marks + records(VaultRevokedDevice.self).filter { !marked.contains($0.deviceID) }
  }

  /// Revocations from before the marks get one, once.
  func markRevocationsOnce() throws {
    guard try meta("format.revocations") == nil else { return }
    let existing = Set(try revocationMarks().map(\.deviceID))
    for device in try records(VaultRevokedDevice.self) where !existing.contains(device.deviceID) {
      try setRevocationMark(device)
    }
    try setMeta("format.revocations", "1")
  }

  public func isRevoked(device: String) throws -> Bool {
    if try !keys.marks(prefix: revocationMarkPrefix + device, synced: true).filter({ $0.name == revocationMarkPrefix + device }).isEmpty {
      return true
    }
    return try record(VaultRevokedDevice.self, id: try revokedDeviceID(device)) != nil
  }

  /// Takes a lost device out: remembers it so that it can't come back by itself, then `removeDevice`. Not its keys or
  /// passwords: those are the other steps of Lost Device.
  public func revokeDevice(_ key: VaultDeviceKey, folderIsHere: (String) -> Bool = { _ in false }) throws {
    guard key.id != deviceID else { throw VaultDeviceError.thisDevice }
    let revoked = VaultRevokedDevice(
      id: try revokedDeviceID(key.id), deviceID: key.id, name: key.deviceName, publicKey: key.publicKey)
    try setRevocationMark(revoked)
    try save(revoked)
    try removeDevice(key.id, folderIsHere: folderIsHere)
  }

  /// Takes a revoked device off the list: it publishes itself again the next time it runs.
  public func trustAgain(device: String) throws {
    try delete(id: try revokedDeviceID(device))
    try keys.removeMark(revocationMarkPrefix + device, synced: true)
  }

  /// Device keys, without those of revoked devices (by id, and by key under another id).
  public func deviceKeysByTrust() throws -> (trusted: [VaultDeviceKey], revoked: [VaultDeviceKey]) {
    let revoked = try revokedDevices()
    let ids = Set(revoked.map(\.deviceID))
    let materials = Set(revoked.compactMap { VaultAuthorizedKeys.keyMaterial(of: $0.publicKey) })
    var result: (trusted: [VaultDeviceKey], revoked: [VaultDeviceKey]) = ([], [])
    for key in try records(VaultDeviceKey.self) {
      let isOut = ids.contains(key.id) || VaultAuthorizedKeys.keyMaterial(of: key.publicKey).map(materials.contains) == true
      if isOut { result.revoked.append(key) } else { result.trusted.append(key) }
    }
    return result
  }

  /// Device keys that may be trusted, for code outside `Vault`.
  public func trustedDeviceKeys() throws -> [VaultDeviceKey] { try deviceKeysByTrust().trusted }
}

extension VaultAuthorizedKeys {
  /// A shell command that takes a device's lines out of another machine's `~/.ssh/authorized_keys`: lines with its key,
  /// and lines Vault added for it. Keeps the file's owner and mode, keeps every other line, and prints
  /// `v57-sweep <lines removed>`, which `sweptLines(from:)` reads. The id and the key come from synced records, so
  /// they're quoted, and anything that isn't a plain value yields no pattern.
  public static func sweepCommand(device id: String, publicKey: String) -> String? {
    var patterns: [String] = []
    if let material = keyMaterial(of: publicKey), isKeyLine(publicKey), !material.contains("\n") { patterns.append(material) }
    if !id.isEmpty, !id.contains(where: \.isNewline) { patterns.append("\(marker)\(id) ") }
    guard !patterns.isEmpty else { return nil }
    let arguments = patterns.map { "-e \(shellQuoted($0))" }.joined(separator: " ")
    return """
      f="$HOME/.ssh/authorized_keys"; if [ ! -f "$f" ]; then echo "v57-sweep 0"; exit 0; fi; \
      t="$(mktemp "$f.XXXXXX")" || exit 1; \
      grep -vF \(arguments) "$f" > "$t"; c=$?; \
      if [ "$c" -gt 1 ]; then rm -f "$t"; exit 1; fi; \
      n=$(( $(wc -l < "$f") - $(wc -l < "$t") )); \
      if [ "$n" -gt 0 ]; then cat "$t" > "$f" || { rm -f "$t"; exit 1; }; fi; \
      rm -f "$t"; echo "v57-sweep $n"
      """
  }

  /// The number of lines `sweepCommand` took out, from what it printed; nil when it didn't finish.
  public static func sweptLines(from output: String) -> Int? {
    for line in output.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix("v57-sweep ") {
      return Int(line.dropFirst("v57-sweep ".count).trimmingCharacters(in: .whitespaces))
    }
    return nil
  }

  private static func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
