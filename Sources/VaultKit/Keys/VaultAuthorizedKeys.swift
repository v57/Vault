import Foundation

/// An `authorized_keys` file, and the lines in it that let the user's devices in (their `VaultDeviceKey`s).
///
/// The lines Vault adds carry `v57-device=<id>` in their comment, so it can take them out again when a device is
/// disallowed, removed or gets a new key; it never changes other lines, except that disallowing a device also drops
/// a line someone added by hand with the same key.
public struct VaultAuthorizedKeys: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  #if os(macOS)
    /// The user's `~/.ssh/authorized_keys`.
    public static var user: VaultAuthorizedKeys {
      VaultAuthorizedKeys(
        url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/authorized_keys"))
    }
  #endif

  static let marker = "v57-device="

  /// The devices among `keys` whose key is in the file, by any line.
  public func allowedDevices(among keys: [VaultDeviceKey]) throws -> Set<String> {
    let present = Set(try lines().compactMap(Self.keyMaterial(of:)))
    return Set(keys.filter { Self.keyMaterial(of: $0.publicKey).map(present.contains) ?? false }.map(\.id))
  }

  /// Adds the device's key, unless it's there already.
  public func allow(_ key: VaultDeviceKey) throws {
    guard let material = Self.keyMaterial(of: key.publicKey) else { throw AuthorizedKeysError.notAKey }
    var lines = try lines()
    guard !lines.contains(where: { Self.keyMaterial(of: $0) == material }) else { return }
    let name = key.deviceName.replacingOccurrences(of: "\n", with: " ")
    lines.append("\(material) \(Self.marker)\(key.id) \(name)")
    try write(lines)
  }

  /// Takes the device's key out: Vault's line for it and any other line with the same key.
  public func disallow(_ key: VaultDeviceKey) throws {
    let material = Self.keyMaterial(of: key.publicKey)
    let lines = try lines()
    let kept = lines.filter { line in
      Self.device(of: line) != key.id && (material == nil || Self.keyMaterial(of: line) != material)
    }
    if kept.count != lines.count { try write(kept) }
  }

  /// Takes out every line Vault added.
  public func disallowAll() throws {
    let lines = try lines()
    let kept = lines.filter { Self.device(of: $0) == nil }
    if kept.count != lines.count { try write(kept) }
  }

  /// Takes out Vault's lines for devices that are gone from `keys` or have another key now (a new key is allowed
  /// again by hand, never by following the vault). Returns whether it changed the file.
  @discardableResult
  public func removeStale(keeping keys: [VaultDeviceKey]) throws -> Bool {
    let current = Dictionary(keys.map { ($0.id, Self.keyMaterial(of: $0.publicKey)) }, uniquingKeysWith: { first, _ in first })
    let lines = try lines()
    let kept = lines.filter { line in
      guard let device = Self.device(of: line) else { return true }
      guard let material = current[device] ?? nil else { return false }
      return Self.keyMaterial(of: line) == material
    }
    guard kept.count != lines.count else { return false }
    try write(kept)
    return true
  }

  // MARK: The file

  func lines() throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let text = try String(contentsOf: url, encoding: .utf8)
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  /// Writes the file in place of the old one, readable by the user only, in a folder only the user can open, as sshd
  /// wants them.
  func write(_ lines: [String]) throws {
    let folder = url.deletingLastPathComponent()
    let files = FileManager.default
    if !files.fileExists(atPath: folder.path) {
      try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    try Data(text.utf8).write(to: url, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  // MARK: Lines

  /// "ecdsa-sha2-nistp256 AAAA…": the key's type and blob, after any options, without the comment.
  static func keyMaterial(of line: String) -> String? {
    let line = line.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
    let words = line.split(separator: " ", omittingEmptySubsequences: true)
    guard let index = words.firstIndex(where: isKeyType), index + 1 < words.count else { return nil }
    return "\(words[index]) \(words[index + 1])"
  }

  /// The device a line Vault added is for.
  static func device(of line: String) -> String? {
    guard let word = line.split(separator: " ").first(where: { $0.hasPrefix(marker) }) else { return nil }
    let id = word.dropFirst(marker.count)
    return id.isEmpty ? nil : String(id)
  }

  private static func isKeyType(_ word: Substring) -> Bool {
    word.hasPrefix("ssh-") || word.hasPrefix("ecdsa-sha2-") || word.hasPrefix("sk-")
  }

  public enum AuthorizedKeysError: LocalizedError {
    case notAKey

    public var errorDescription: String? { "The device’s key isn’t an SSH public key." }
  }
}
