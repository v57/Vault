import CryptoKit
import Foundation
import VaultFiles

/// A file in a device's copy of a synced folder.
public struct LocalFile: Sendable, Hashable {
  /// Relative, `/`-separated.
  public var path: String
  /// Plaintext bytes.
  public var size: Int64
  public var modified: Date

  public init(path: String, size: Int64, modified: Date) {
    self.path = path
    self.size = size
    self.modified = modified
  }
}

/// Reads a local file in ranges.
public protocol LocalFileReader {
  var size: Int64 { get }
  func read(range: Range<Int64>) throws -> Data
}

/// Writes a local file piece by piece; nothing changes at its path until `commit`.
public protocol LocalFileWriter: AnyObject {
  func append(_ data: Data) throws
  /// Puts the file in place and returns it as it is now.
  func commit() throws -> LocalFile
  func cancel()
}

/// A device's copy of a synced folder: plain files (`PlainSyncFolder`) or an encrypted folder
/// (`EncryptedSyncFolder`). The engine finds local changes by scanning against its last index, so it needs no file
/// system events; an app can still call `FolderSync.sync()` when it sees some.
public protocol SyncLocalFolder: Sendable {
  /// Every file (not folders), with sizes and modification dates. Names the sync ignores are left out.
  func scan() throws -> [LocalFile]
  func stat(_ path: String) throws -> LocalFile?
  func reader(_ path: String) throws -> any LocalFileReader
  /// Starts writing the file at `path`, making the folders above it.
  func beginWrite(_ path: String) throws -> any LocalFileWriter
  /// Removes the file at `path` and the folders above it that it leaves empty. Nothing happens when it's missing.
  func remove(_ path: String) throws
}

enum SyncNames {
  /// Names folder sync never sends: system clutter and its own temporary files.
  static func isIgnored(_ name: String) -> Bool {
    name == ".DS_Store" || name == "Icon\r" || name.hasPrefix(".v57sync") || name.hasPrefix(".v57tmp-")
      || name == ".localized"
  }

  /// A path from a change log, checked before it touches the disk: relative, no `..`, no empty or ignored
  /// components.
  static func validated(_ path: String) -> String? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty,
      parts.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\") && !isIgnored($0)
      })
    else { return nil }
    let normalized = parts.map { $0.precomposedStringWithCanonicalMapping }.joined(separator: "/")
    return normalized == path ? path : nil
  }
}

// MARK: - Plain files

/// A synced folder kept as ordinary files, which every app can open.
public struct PlainSyncFolder: SyncLocalFolder {
  public let url: URL

  public init(url: URL) throws {
    self.url = url.standardizedFileURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func fileURL(_ path: String) -> URL { url.appendingPathComponent(path, isDirectory: false) }

  public func scan() throws -> [LocalFile] {
    var files: [LocalFile] = []
    try scan(url, prefix: "", into: &files)
    return files.sorted { $0.path < $1.path }
  }

  private func scan(_ directory: URL, prefix: String, into files: inout [LocalFile]) throws {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
      .contentModificationDateKey]
    for child in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: keys, options: [])
    {
      let name = child.lastPathComponent
      guard !SyncNames.isIgnored(name) else { continue }
      let values = try child.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true { continue }
      let path = prefix.isEmpty ? name : prefix + "/" + name
      if values.isDirectory == true {
        try scan(child, prefix: path, into: &files)
      } else if values.isRegularFile == true {
        files.append(
          LocalFile(
            path: path.precomposedStringWithCanonicalMapping, size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? .distantPast))
      }
    }
  }

  public func stat(_ path: String) throws -> LocalFile? {
    let values = try? fileURL(path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
    guard let values, values.isRegularFile == true else { return nil }
    return LocalFile(path: path, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
  }

  public func reader(_ path: String) throws -> any LocalFileReader { try PlainFileReader(url: fileURL(path)) }

  public func beginWrite(_ path: String) throws -> any LocalFileWriter {
    let temporary = url.appendingPathComponent(".v57sync-tmp-" + UUID().uuidString)
    return try PlainFileWriter(path: path, target: fileURL(path), temporary: temporary, folder: self)
  }

  public func remove(_ path: String) throws {
    let file = fileURL(path)
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    try FileManager.default.removeItem(at: file)
    removeEmptyParents(of: path)
  }

  /// Removes the folders above `path` that are empty (or hold only clutter like `.DS_Store`).
  func removeEmptyParents(of path: String) {
    var parts = path.split(separator: "/").map(String.init)
    parts.removeLast()
    while !parts.isEmpty {
      let directory = url.appendingPathComponent(parts.joined(separator: "/"), isDirectory: true)
      guard let children = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
        children.allSatisfy({ $0 == ".DS_Store" })
      else { return }
      try? FileManager.default.removeItem(at: directory)
      parts.removeLast()
    }
  }
}

final class PlainFileReader: LocalFileReader {
  let handle: FileHandle
  let size: Int64

  init(url: URL) throws {
    handle = try FileHandle(forReadingFrom: url)
    size = Int64(try handle.seekToEnd())
  }

  deinit { try? handle.close() }

  func read(range: Range<Int64>) throws -> Data {
    let lower = max(0, min(range.lowerBound, size))
    let upper = max(lower, min(range.upperBound, size))
    try handle.seek(toOffset: UInt64(lower))
    return try handle.read(upToCount: Int(upper - lower)) ?? Data()
  }
}

final class PlainFileWriter: LocalFileWriter {
  let path: String
  let target: URL
  let temporary: URL
  let folder: PlainSyncFolder
  let handle: FileHandle
  var done = false

  init(path: String, target: URL, temporary: URL, folder: PlainSyncFolder) throws {
    self.path = path
    self.target = target
    self.temporary = temporary
    self.folder = folder
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
    }
    handle = try FileHandle(forWritingTo: temporary)
  }

  deinit { cancel() }

  func append(_ data: Data) throws { try handle.write(contentsOf: data) }

  func commit() throws -> LocalFile {
    precondition(!done, "PlainFileWriter used after commit or cancel")
    defer { cancel() }
    try handle.close()
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: target.path) {
      _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: target)
    }
    guard let file = try folder.stat(path) else { throw CocoaError(.fileNoSuchFile) }
    return file
  }

  func cancel() {
    guard !done else { return }
    done = true
    try? handle.close()
    try? FileManager.default.removeItem(at: temporary)
  }
}

// MARK: - Encrypted

/// A synced folder kept encrypted on this device (`EncryptedFolder`): the same remote format, ciphertext on disk.
public struct EncryptedSyncFolder: SyncLocalFolder {
  public let folder: EncryptedFolder

  public init(_ folder: EncryptedFolder) { self.folder = folder }

  public func scan() throws -> [LocalFile] {
    try folder.walk().compactMap { entry in
      guard !entry.isDirectory, !entry.path.split(separator: "/").contains(where: { SyncNames.isIgnored(String($0)) })
      else { return nil }
      return LocalFile(path: entry.path, size: entry.size, modified: entry.modified)
    }
  }

  public func stat(_ path: String) throws -> LocalFile? {
    guard let entry = try? folder.stat(path), !entry.isDirectory else { return nil }
    return LocalFile(path: entry.path, size: entry.size, modified: entry.modified)
  }

  public func reader(_ path: String) throws -> any LocalFileReader { try folder.reader(path) }

  public func beginWrite(_ path: String) throws -> any LocalFileWriter {
    EncryptedFileWriterAdapter(path: path, pending: try folder.beginWrite(to: path), folder: self)
  }

  public func remove(_ path: String) throws {
    guard folder.exists(path) else { return }
    try folder.remove(path)
    var parts = path.split(separator: "/").map(String.init)
    parts.removeLast()
    while !parts.isEmpty {
      let directory = parts.joined(separator: "/")
      guard let children = try? folder.list(directory), children.isEmpty else { return }
      try? folder.remove(directory)
      parts.removeLast()
    }
  }
}

extension EncryptedFileReader: LocalFileReader {}

final class EncryptedFileWriterAdapter: LocalFileWriter {
  let path: String
  let pending: EncryptedFolder.PendingWrite
  let folder: EncryptedSyncFolder

  init(path: String, pending: EncryptedFolder.PendingWrite, folder: EncryptedSyncFolder) {
    self.path = path
    self.pending = pending
    self.folder = folder
  }

  func append(_ data: Data) throws { try pending.append(data) }

  func commit() throws -> LocalFile {
    try pending.commit()
    guard let file = try folder.stat(path) else { throw VaultFilesError.notFound(path) }
    return file
  }

  func cancel() { pending.cancel() }
}
