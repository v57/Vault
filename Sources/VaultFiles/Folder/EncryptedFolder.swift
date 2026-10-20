import CryptoKit
import Foundation

/// A folder whose files and names are all encrypted with its `FolderKey`. It can sit anywhere a folder can (local
/// disk, iCloud Drive, a synced or mounted remote): everything on disk is ciphertext.
///
/// On disk the tree keeps its shape, with every name encrypted (`NameCipher`) and every file in the chunked format
/// (`EncryptedFile`):
///
/// ```
/// folder.v57            the manifest: format version and folder id, sealed with the content key
/// <encrypted name>      a file
/// <encrypted name>/     a folder, with
///   dir.v57             its random directory id (16 bytes), which its children's names are encrypted with
/// <hash>.long, .name    an entry whose encrypted name is too long, and the sidecar holding that name
/// ```
///
/// A name is encrypted with its parent's directory id, not its path, so moving or renaming a folder rewrites one
/// name, not its whole subtree. The root's directory id is the folder id.
///
/// Paths are relative, `/`-separated plaintext paths (`"docs/notes.txt"`); `""` is the root.
public final class EncryptedFolder: Sendable {
  public static let manifestName = "folder.v57"
  public static let directoryIDName = "dir.v57"
  public static let formatVersion = 1
  static let temporaryPrefix = ".v57tmp-"

  /// One file or folder, decrypted.
  public struct Entry: Sendable, Hashable, Identifiable {
    /// The last path component.
    public let name: String
    /// The path from the folder's root.
    public let path: String
    public let isDirectory: Bool
    /// The plaintext size (0 for folders).
    public let size: Int64
    public let modified: Date

    public var id: String { path }
  }

  /// The encrypted folder's location.
  public let url: URL
  public let key: FolderKey
  /// The folder's random id (32 hex digits), from its manifest.
  public let folderID: String

  let subkeys: FolderSubkeys
  let names: NameCipher
  let rootID: Data

  private struct Manifest: Codable {
    var format: Int
    var id: String
  }

  /// Opens the encrypted folder at `url`, or makes a new one there when nothing (or an empty folder) is there.
  /// Throws `wrongKey` when the folder was made with another key, and `notEncrypted` for a folder with other files.
  public init(url: URL, key: FolderKey) throws {
    self.url = url
    self.key = key
    subkeys = key.subkeys
    names = NameCipher(keys: subkeys)
    let manifestURL = url.appendingPathComponent(Self.manifestName)
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: manifestURL.path) {
      let data = try Data(contentsOf: manifestURL)
      let header = try EncryptedFile.Header(parsing: data)
      let manifest: Manifest
      do {
        manifest = try JSONDecoder().decode(Manifest.self, from: EncryptedFile.open(data, key: subkeys.content))
      } catch VaultFilesError.damaged {
        throw header.keyID == key.id ? VaultFilesError.damaged : VaultFilesError.wrongKey
      }
      guard manifest.format <= Self.formatVersion else { throw VaultFilesError.unsupportedVersion(manifest.format) }
      guard let rootID = Data(hex: manifest.id), rootID.count == 16 else { throw VaultFilesError.damaged }
      folderID = manifest.id
      self.rootID = rootID
    } else {
      let existing = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
      guard existing.allSatisfy({ $0 == ".DS_Store" }) else { throw VaultFilesError.notEncrypted }
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      rootID = randomBytes(16)
      folderID = rootID.hexString
      let manifest = try JSONEncoder().encode(Manifest(format: Self.formatVersion, id: folderID))
      try EncryptedFile.seal(manifest, key: subkeys.content, keyID: key.id).write(to: manifestURL, options: .atomic)
    }
  }

  /// Whether `url` holds an encrypted folder.
  public static func isEncryptedFolder(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestName).path)
  }

  /// The id of the key the folder at `url` was made with, read without a key.
  public static func keyID(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url.appendingPathComponent(manifestName))
    defer { try? handle.close() }
    return try EncryptedFile.Header(parsing: handle.read(upToCount: EncryptedFile.maxHeaderSize) ?? Data()).keyID
  }

  // MARK: Reading

  /// The files and folders in the folder at `path`, sorted by name. Entries whose names don't decrypt (files other
  /// apps put there, or damage) are skipped.
  public func list(_ path: String = "") throws -> [Entry] {
    let components = try Self.components(path)
    let directory = try resolveDirectory(components, create: false)
    let fileManager = FileManager.default
    var entries: [Entry] = []
    for diskName in try fileManager.contentsOfDirectory(atPath: directory.url.path) {
      let encrypted: String
      switch DiskName.kind(of: diskName) {
      case .encrypted(let name): encrypted = name
      case .long(let sidecar):
        guard let data = try? Data(contentsOf: directory.url.appendingPathComponent(sidecar)) else { continue }
        encrypted = String(decoding: data, as: UTF8.self)
      case .other: continue
      }
      guard let name = try? names.decrypt(encrypted, directoryID: directory.id),
        let entry = entry(at: directory.url.appendingPathComponent(diskName), path: components + [name])
      else { continue }
      entries.append(entry)
    }
    return entries.sorted { $0.name < $1.name }
  }

  /// Every file and folder under `path`, each folder before its contents.
  public func walk(_ path: String = "") throws -> [Entry] {
    var result: [Entry] = []
    for entry in try list(path) {
      result.append(entry)
      if entry.isDirectory { result += try walk(entry.path) }
    }
    return result
  }

  /// The file or folder at `path`, or nil when there is none.
  public func stat(_ path: String) throws -> Entry? {
    let components = try Self.components(path)
    guard !components.isEmpty else { return entry(at: url, path: []) }
    guard let location = try? locate(components), location.exists else { return nil }
    return entry(at: location.url, path: components)
  }

  /// Whether something is at `path`.
  public func exists(_ path: String) -> Bool { (try? stat(path)) != nil }

  /// The contents of the file at `path`.
  public func read(_ path: String) throws -> Data {
    try EncryptedFile.open(Data(contentsOf: fileLocation(path).url), key: subkeys.content)
  }

  /// Decrypts the file at `path` into `destination` without holding it all in memory.
  public func readFile(_ path: String, to destination: URL) throws {
    _ = try readFile(path, to: destination, progress: nil)
  }

  @discardableResult
  func readFile(_ path: String, to destination: URL, progress: ((Int64) -> Void)?) throws -> SHA256.Digest {
    try EncryptedFile.openFile(fileLocation(path).url, to: destination, key: subkeys.content, progress: progress)
  }

  /// A reader for any range of the file at `path`.
  public func reader(_ path: String) throws -> EncryptedFileReader {
    try EncryptedFileReader(url: fileLocation(path).url, key: subkeys.content)
  }

  // MARK: Writing

  /// Writes `data` to the file at `path`, replacing it, and makes the folders above it as needed.
  public func write(_ data: Data, to path: String) throws {
    let sealed = try EncryptedFile.seal(data, key: subkeys.content, keyID: key.id)
    try replaceFile(at: path) { temporary in try sealed.write(to: temporary) }
  }

  /// Encrypts the file at `source` into the file at `path` without holding it all in memory.
  public func writeFile(from source: URL, to path: String) throws {
    _ = try writeFile(from: source, to: path, progress: nil)
  }

  @discardableResult
  func writeFile(from source: URL, to path: String, progress: ((Int64) -> Void)?) throws -> SHA256.Digest {
    var digest: SHA256.Digest?
    try replaceFile(at: path) { temporary in
      digest = try EncryptedFile.sealFile(
        source, to: temporary, key: subkeys.content, keyID: key.id, progress: progress)
    }
    return digest!
  }

  /// Makes the folder at `path` and any above it; nothing happens when it exists.
  public func createDirectory(_ path: String) throws {
    _ = try resolveDirectory(Self.components(path), create: true)
  }

  /// Moves or renames the file or folder at `source` to `destination`, making the folders above it as needed.
  /// Fails when something is at `destination`.
  public func move(_ source: String, to destination: String) throws {
    let from = try Self.components(source)
    let to = try Self.components(destination)
    guard !from.isEmpty, !to.isEmpty, from != to else { throw VaultFilesError.invalidName(destination) }
    guard !to.starts(with: from) else { throw VaultFilesError.invalidName(destination) }
    let sourceLocation = try locate(from)
    guard sourceLocation.exists else { throw VaultFilesError.notFound(source) }
    let parent = try resolveDirectory(Array(to.dropLast()), create: true)
    let target = try location(of: to.last!, in: parent)
    guard !target.exists else { throw VaultFilesError.exists(destination) }
    try target.writeSidecar()
    do {
      try FileManager.default.moveItem(at: sourceLocation.url, to: target.url)
    } catch {
      target.removeSidecar()
      throw error
    }
    sourceLocation.removeSidecar()
  }

  /// Removes the file or folder (with its contents) at `path`.
  public func remove(_ path: String) throws {
    let components = try Self.components(path)
    guard !components.isEmpty else { throw VaultFilesError.invalidName(path) }
    let location = try locate(components)
    guard location.exists else { throw VaultFilesError.notFound(path) }
    try FileManager.default.removeItem(at: location.url)
    location.removeSidecar()
  }

  /// Decrypts the whole folder into a new plain folder at `destination`: a one-shot export, which nothing seals
  /// back or deletes.
  public func exportDecrypted(to destination: URL) throws {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: destination.path) else { throw VaultFilesError.exists(destination.path) }
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    for entry in try walk() {
      let target = destination.appendingPathComponent(entry.path, isDirectory: entry.isDirectory)
      if entry.isDirectory {
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
      } else {
        try readFile(entry.path, to: target)
      }
    }
  }

  // MARK: Paths

  /// A path's components, each normalized; `.` and empty components are dropped, `..` is refused.
  static func components(_ path: String) throws -> [String] {
    try path.split(separator: "/", omittingEmptySubsequences: true)
      .filter { $0 != "." }
      .map { try NameCipher.normalized(String($0)) }
  }

  static func join(_ components: [String]) -> String { components.joined(separator: "/") }

  /// An entry on disk: where it is, and the sidecar its shortened name needs.
  struct Location {
    let url: URL
    let sidecar: URL?
    let encryptedName: String

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var isDirectory: Bool {
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func writeSidecar() throws {
      if let sidecar { try Data(encryptedName.utf8).write(to: sidecar, options: .atomic) }
    }

    func removeSidecar() {
      if let sidecar { try? FileManager.default.removeItem(at: sidecar) }
    }
  }

  func location(of name: String, in directory: (url: URL, id: Data)) throws -> Location {
    let encrypted = try names.encrypt(name, directoryID: directory.id)
    let disk = DiskName.forEncrypted(encrypted)
    return Location(
      url: directory.url.appendingPathComponent(disk.entry),
      sidecar: disk.sidecar.map { directory.url.appendingPathComponent($0) }, encryptedName: encrypted)
  }

  /// The location of the entry at `components` (whose parent folders must exist).
  func locate(_ components: [String]) throws -> Location {
    let parent = try resolveDirectory(Array(components.dropLast()), create: false)
    return try location(of: components.last!, in: parent)
  }

  private func fileLocation(_ path: String) throws -> Location {
    let components = try Self.components(path)
    guard !components.isEmpty else { throw VaultFilesError.isADirectory(path) }
    let location = try locate(components)
    guard location.exists else { throw VaultFilesError.notFound(path) }
    guard !location.isDirectory else { throw VaultFilesError.isADirectory(path) }
    return location
  }

  /// The folder at `components` on disk and its directory id, made (with the folders above it) when `create`.
  func resolveDirectory(_ components: [String], create: Bool) throws -> (url: URL, id: Data) {
    var directory = (url: url, id: rootID)
    for (index, name) in components.enumerated() {
      let location = try location(of: name, in: directory)
      let path = Self.join(Array(components[...index]))
      if !location.exists {
        guard create else { throw VaultFilesError.notFound(path) }
        try makeDirectory(location, in: directory.url)
      } else if !location.isDirectory {
        throw VaultFilesError.notADirectory(path)
      }
      let idData = try Data(contentsOf: location.url.appendingPathComponent(Self.directoryIDName))
      guard idData.count == 16 else { throw VaultFilesError.damaged }
      directory = (location.url, idData)
    }
    return directory
  }

  /// Makes a folder with a new directory id, complete before it appears under its name.
  private func makeDirectory(_ location: Location, in parent: URL) throws {
    let fileManager = FileManager.default
    let temporary = parent.appendingPathComponent(Self.temporaryPrefix + UUID().uuidString)
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: temporary) }
    try randomBytes(16).write(to: temporary.appendingPathComponent(Self.directoryIDName))
    try location.writeSidecar()
    do {
      try fileManager.moveItem(at: temporary, to: location.url)
    } catch where location.isDirectory {
      // Another writer made it first.
    }
  }

  /// Writes a file through a temporary file in the same folder, then puts it in place, so a reader never sees half
  /// a file.
  private func replaceFile(at path: String, write: (URL) throws -> Void) throws {
    let components = try Self.components(path)
    guard !components.isEmpty else { throw VaultFilesError.isADirectory(path) }
    let parent = try resolveDirectory(Array(components.dropLast()), create: true)
    let target = try location(of: components.last!, in: parent)
    if target.isDirectory { throw VaultFilesError.isADirectory(path) }
    let fileManager = FileManager.default
    let temporary = parent.url.appendingPathComponent(Self.temporaryPrefix + UUID().uuidString)
    defer { try? fileManager.removeItem(at: temporary) }
    try write(temporary)
    try target.writeSidecar()
    if target.exists {
      _ = try fileManager.replaceItemAt(target.url, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: target.url)
    }
  }

  private func entry(at diskURL: URL, path components: [String]) -> Entry? {
    guard let values = try? diskURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
    else { return nil }
    let isDirectory = values.isDirectory ?? false
    var size: Int64 = 0
    if !isDirectory {
      size =
        EncryptedFile.plaintextSize(
          ciphertextSize: Int64(values.fileSize ?? 0), headerSize: EncryptedFile.Header.size(keyID: key.id)) ?? 0
    }
    return Entry(
      name: components.last ?? "", path: Self.join(components), isDirectory: isDirectory, size: size,
      modified: values.contentModificationDate ?? .distantPast)
  }
}

extension Data {
  init?(hex: String) {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    self = data
  }

  var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
