import Foundation

/// A file or folder on a remote.
public struct RemoteFileInfo: Sendable, Hashable, Identifiable {
  /// Relative to the remote's root, `/`-separated, without leading or trailing `/`; "" is the root.
  public var path: String
  public var isDirectory: Bool
  /// Bytes; 0 for a folder.
  public var size: Int64
  public var modified: Date?

  public init(path: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil) {
    self.path = path
    self.isDirectory = isDirectory
    self.size = size
    self.modified = modified
  }

  public var id: String { path }
  public var name: String { path.split(separator: "/").last.map(String.init) ?? "" }
}

public enum RemoteFileError: LocalizedError, Equatable {
  case notFound(String)
  case notADirectory(String)
  case isADirectory(String)
  case alreadyExists(String)
  case directoryNotEmpty(String)
  case invalidPath(String)

  public var errorDescription: String? {
    switch self {
    case .notFound(let path): "“\(path)” doesn’t exist."
    case .notADirectory(let path): "“\(path)” isn’t a folder."
    case .isADirectory(let path): "“\(path)” is a folder."
    case .alreadyExists(let path): "“\(path)” already exists."
    case .directoryNotEmpty(let path): "The folder “\(path)” isn’t empty."
    case .invalidPath(let path): "“\(path)” isn’t a valid path."
    }
  }
}

/// One way to reach files on a remote (SFTP, S3, SMB, a local folder), used by the file browser and by folder
/// sync alike.
///
/// Paths are relative to the remote's root and `/`-separated (`RemotePath.normalize`). The rules every backend
/// follows (the tests check them against `MemoryRemoteFileSystem` and `LocalRemoteFileSystem`):
/// - `list` gives a folder's entries sorted by name; `stat` gives nil for a missing path.
/// - `read` with a range gives the bytes in it that exist (none past the end).
/// - `write` replaces a file and makes missing parent folders, like S3.
/// - `rename` replaces a file at the destination and makes missing parent folders; it never replaces a folder.
/// - `delete` removes a file or an empty folder.
public protocol RemoteFileSystem: Sendable {
  func list(_ path: String) async throws -> [RemoteFileInfo]
  func stat(_ path: String) async throws -> RemoteFileInfo?
  func read(_ path: String, range: Range<Int64>?) async throws -> Data
  func write(_ data: Data, to path: String) async throws
  func createDirectory(_ path: String) async throws
  func rename(_ source: String, to destination: String) async throws
  func delete(_ path: String) async throws
}

extension RemoteFileSystem {
  /// The whole file.
  public func read(_ path: String) async throws -> Data {
    try await read(path, range: nil)
  }

  public func exists(_ path: String) async throws -> Bool {
    try await stat(path) != nil
  }
}

/// Remote paths: `/`-separated, relative to the remote's root.
public enum RemotePath {
  /// The path without leading, trailing or doubled `/` and without `.`; "" for the root. `..` and NUL
  /// characters are refused, so a path never leaves the root.
  public static func normalize(_ path: String) throws -> String {
    try components(path).joined(separator: "/")
  }

  public static func components(_ path: String) throws -> [String] {
    var parts: [String] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
      if part == "." { continue }
      if part == ".." || part.contains("\0") { throw RemoteFileError.invalidPath(path) }
      parts.append(String(part))
    }
    return parts
  }

  /// The folder holding `path` ("" for a top-level item and for the root).
  public static func parent(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }

  public static func join(_ base: String, _ name: String) -> String {
    base.isEmpty ? name : name.isEmpty ? base : base + "/" + name
  }
}
