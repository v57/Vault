import Foundation

/// A folder on this device seen as a remote: a USB drive, a mounted share, or a folder another sync tool
/// fills. Paths stay inside `root` (symbolic links in it are followed, like any app would).
public struct LocalRemoteFileSystem: RemoteFileSystem {
  public let root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  private func url(_ path: String) -> URL {
    path.isEmpty ? root : root.appendingPathComponent(path)
  }

  private func info(_ path: String) -> RemoteFileInfo? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url(path).path)
    guard let attributes else { return nil }
    let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    return RemoteFileInfo(
      path: path, isDirectory: isDirectory, size: isDirectory ? 0 : size, modified: attributes[.modificationDate] as? Date)
  }

  public func list(_ path: String) async throws -> [RemoteFileInfo] {
    let path = try RemotePath.normalize(path)
    guard let folder = info(path) else { throw RemoteFileError.notFound(path) }
    guard folder.isDirectory else { throw RemoteFileError.notADirectory(path) }
    return try FileManager.default.contentsOfDirectory(atPath: url(path).path).sorted()
      .compactMap { info(RemotePath.join(path, $0)) }
  }

  public func stat(_ path: String) async throws -> RemoteFileInfo? {
    info(try RemotePath.normalize(path))
  }

  public func read(_ path: String, range: Range<Int64>?) async throws -> Data {
    let path = try RemotePath.normalize(path)
    guard let file = info(path) else { throw RemoteFileError.notFound(path) }
    guard !file.isDirectory else { throw RemoteFileError.isADirectory(path) }
    guard let range else { return try Data(contentsOf: url(path)) }
    let lower = min(max(range.lowerBound, 0), file.size)
    let upper = min(max(range.upperBound, lower), file.size)
    guard upper > lower else { return Data() }
    let handle = try FileHandle(forReadingFrom: url(path))
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(lower))
    return try handle.read(upToCount: Int(upper - lower)) ?? Data()
  }

  public func write(_ data: Data, to path: String) async throws {
    let path = try RemotePath.normalize(path)
    guard !path.isEmpty else { throw RemoteFileError.isADirectory(path) }
    if info(path)?.isDirectory == true { throw RemoteFileError.isADirectory(path) }
    try makeParents(of: path)
    try data.write(to: url(path), options: .atomic)
  }

  public func createDirectory(_ path: String) async throws {
    let path = try RemotePath.normalize(path)
    if let existing = info(path) {
      if existing.isDirectory { return }
      throw RemoteFileError.alreadyExists(path)
    }
    try makeParents(of: path)
    try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: false)
  }

  public func rename(_ source: String, to destination: String) async throws {
    let source = try RemotePath.normalize(source)
    let destination = try RemotePath.normalize(destination)
    guard !source.isEmpty, !destination.isEmpty else { throw RemoteFileError.invalidPath(source) }
    guard let item = info(source) else { throw RemoteFileError.notFound(source) }
    guard source != destination else { return }
    if destination.hasPrefix(source + "/") { throw RemoteFileError.invalidPath(destination) }
    if let existing = info(destination) {
      if existing.isDirectory || item.isDirectory { throw RemoteFileError.alreadyExists(destination) }
      try FileManager.default.removeItem(at: url(destination))
    }
    try makeParents(of: destination)
    try FileManager.default.moveItem(at: url(source), to: url(destination))
  }

  public func delete(_ path: String) async throws {
    let path = try RemotePath.normalize(path)
    guard !path.isEmpty else { throw RemoteFileError.invalidPath(path) }
    guard let item = info(path) else { throw RemoteFileError.notFound(path) }
    if item.isDirectory, !(try FileManager.default.contentsOfDirectory(atPath: url(path).path)).isEmpty {
      throw RemoteFileError.directoryNotEmpty(path)
    }
    try FileManager.default.removeItem(at: url(path))
  }

  private func makeParents(of path: String) throws {
    // The root itself, the first time something is written.
    if info("") == nil { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    let parts = path.split(separator: "/").map(String.init)
    for index in 1..<max(parts.count, 1) {
      let parent = parts[..<index].joined(separator: "/")
      if let existing = info(parent) {
        guard existing.isDirectory else { throw RemoteFileError.notADirectory(parent) }
        continue
      }
      try FileManager.default.createDirectory(at: url(parent), withIntermediateDirectories: false)
    }
  }
}
