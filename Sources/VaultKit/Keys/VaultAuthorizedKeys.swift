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
    lines.append(Self.line(material: material, for: key))
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
  /// again by hand, never by following the vault), and renames the rest's comment to the device's name now.
  /// Returns whether it changed the file.
  @discardableResult
  public func removeStale(keeping keys: [VaultDeviceKey]) throws -> Bool {
    let current = Dictionary(keys.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let lines = try lines()
    let kept = lines.compactMap { line -> String? in
      guard let device = Self.device(of: line) else { return line }
      guard let key = current[device], let material = Self.keyMaterial(of: key.publicKey),
        Self.keyMaterial(of: line) == material
      else { return nil }
      return Self.renamed(line, to: key.deviceName)
    }
    guard kept != lines else { return false }
    try write(kept)
    return true
  }

  // MARK: Any key

  /// A key in the file, as Settings lists it: a device's (`device`) or one added by hand or by another tool.
  public struct Entry: Identifiable, Hashable, Sendable {
    /// "ssh-ed25519 AAAA…": the key's type and blob, which say which key it is.
    public let material: String
    /// The first line with the key, as it is in the file.
    public let line: String
    /// What comes after the key ("name@laptop"), without Vault's marker; nil when there's nothing.
    public let comment: String?
    /// The device a line Vault added is for.
    public let device: String?

    public var id: String { material }
  }

  /// The keys in the file, in its order; a key that's there twice is listed once.
  public func entries() throws -> [Entry] {
    var seen = Set<String>()
    return try lines().compactMap { line in
      guard let material = Self.keyMaterial(of: line), seen.insert(material).inserted else { return nil }
      return Entry(material: material, line: line, comment: Self.comment(of: line), device: Self.device(of: line))
    }
  }

  /// Adds one public key line ("ssh-ed25519 AAAA… name@laptop"), unless its key is there already.
  public func add(line: String) throws {
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isKeyLine(line), let material = Self.keyMaterial(of: line) else { throw AuthorizedKeysError.notAKeyLine }
    var lines = try lines()
    guard !lines.contains(where: { Self.keyMaterial(of: $0) == material }) else { return }
    lines.append(line)
    try write(lines)
  }

  /// Takes out every line with the key `material` ("ssh-ed25519 AAAA…").
  public func remove(material: String) throws {
    let lines = try lines()
    let kept = lines.filter { Self.keyMaterial(of: $0) != material }
    if kept.count != lines.count { try write(kept) }
  }

  /// Whether `line` is one public key line: a key type and a base64 blob, any options before and a comment after.
  public static func isKeyLine(_ line: String) -> Bool {
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.contains("\n"), let material = keyMaterial(of: line) else { return false }
    let blob = material.split(separator: " ")[1]
    return Data(base64Encoded: String(blob)) != nil
  }

  /// What comes after a line's key, without Vault's marker.
  static func comment(of line: String) -> String? {
    let words = line.split(separator: " ", omittingEmptySubsequences: true)
    guard let index = words.firstIndex(where: isKeyType), index + 2 < words.count else { return nil }
    let comment = words[(index + 2)...].filter { !$0.hasPrefix(marker) }.joined(separator: " ")
    return comment.isEmpty ? nil : comment
  }

  /// Vault's line for a device: its key, the marker and its name.
  static func line(material: String, for key: VaultDeviceKey) -> String {
    // An app's own key signs in for what the app does (run a command, read files), never to forward ports or open a
    // terminal.
    "\(key.isAppKey ? "restrict " : "")\(material) \(marker)\(key.id) \(oneLine(key.deviceName))"
  }

  /// A name for a line's comment: names come from synced records, and a line break would start another line in the
  /// file, one sshd reads as a key with whatever options it says.
  static func oneLine(_ name: String) -> String {
    String(name.map { $0.isNewline || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } ? " " : $0 })
  }

  /// A line Vault added with `name` after its marker; what comes before (options, the key) stays.
  static func renamed(_ line: String, to name: String) -> String {
    guard let marker = line.range(of: " \(marker)") else { return line }
    let end = line[marker.upperBound...].firstIndex(of: " ") ?? line.endIndex
    return "\(line[..<end]) \(oneLine(name))"
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

  /// "ecdsa-sha2-nistp256 AAAA…": the key's type and blob, after any options, without the comment. Nil for text of
  /// more than one line: what a synced record calls a key must not put a second line in the file.
  public static func keyMaterial(of line: String) -> String? {
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty, !line.hasPrefix("#"), !line.contains(where: \.isNewline) else { return nil }
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
    case notAKeyLine

    public var errorDescription: String? {
      switch self {
      case .notAKey: "The device’s key isn’t an SSH public key."
      case .notAKeyLine: "That isn’t one SSH public key line, like the contents of ~/.ssh/id_ed25519.pub."
      }
    }
  }
}
