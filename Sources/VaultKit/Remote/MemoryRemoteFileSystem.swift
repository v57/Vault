import Foundation

/// A remote held in memory: for tests (folder sync with several devices, like `FakeCloud`), previews and demos.
public actor MemoryRemoteFileSystem: RemoteFileSystem {
  enum Node {
    case file(Data, Date)
    case directory(Date)
  }

  private var nodes: [String: Node] = [:]
  private let clock: @Sendable () -> Date

  public init(files: [String: Data] = [:], clock: @escaping @Sendable () -> Date = { .now }) {
    self.clock = clock
    let now = clock()
    for (path, data) in files {
      guard let parts = try? RemotePath.components(path), !parts.isEmpty else { continue }
      for index in 1..<parts.count { nodes[parts[..<index].joined(separator: "/")] = .directory(now) }
      nodes[parts.joined(separator: "/")] = .file(data, now)
    }
  }

  /// Every file's path, sorted, for tests.
  public var allFiles: [String] {
    nodes.compactMap { if case .file = $0.value { $0.key } else { nil } }.sorted()
  }

  public func list(_ path: String) async throws -> [RemoteFileInfo] {
    let path = try RemotePath.normalize(path)
    if !path.isEmpty {
      switch nodes[path] {
      case nil: throw RemoteFileError.notFound(path)
      case .file: throw RemoteFileError.notADirectory(path)
      case .directory: break
      }
    }
    return nodes.keys.filter { RemotePath.parent($0) == path && $0 != path }.sorted().compactMap(info)
  }

  public func stat(_ path: String) async throws -> RemoteFileInfo? {
    let path = try RemotePath.normalize(path)
    if path.isEmpty { return RemoteFileInfo(path: "", isDirectory: true) }
    return info(path)
  }

  public func read(_ path: String, range: Range<Int64>?) async throws -> Data {
    let path = try RemotePath.normalize(path)
    switch nodes[path] {
    case nil: throw path.isEmpty ? RemoteFileError.isADirectory(path) : RemoteFileError.notFound(path)
    case .directory: throw RemoteFileError.isADirectory(path)
    case .file(let data, _):
      guard let range else { return data }
      let lower = Int(min(max(range.lowerBound, 0), Int64(data.count)))
      let upper = Int(min(max(range.upperBound, Int64(lower)), Int64(data.count)))
      return data.subdata(in: lower..<upper)
    }
  }

  public func write(_ data: Data, to path: String) async throws {
    let path = try RemotePath.normalize(path)
    guard !path.isEmpty else { throw RemoteFileError.isADirectory(path) }
    if case .directory = nodes[path] { throw RemoteFileError.isADirectory(path) }
    try makeParents(of: path)
    nodes[path] = .file(data, clock())
  }

  public func createDirectory(_ path: String) async throws {
    let path = try RemotePath.normalize(path)
    guard !path.isEmpty else { return }
    switch nodes[path] {
    case .directory: return
    case .file: throw RemoteFileError.alreadyExists(path)
    case nil:
      try makeParents(of: path)
      nodes[path] = .directory(clock())
    }
  }

  public func rename(_ source: String, to destination: String) async throws {
    let source = try RemotePath.normalize(source)
    let destination = try RemotePath.normalize(destination)
    guard !source.isEmpty, !destination.isEmpty else { throw RemoteFileError.invalidPath(source) }
    guard let node = nodes[source] else { throw RemoteFileError.notFound(source) }
    guard source != destination else { return }
    if destination.hasPrefix(source + "/") { throw RemoteFileError.invalidPath(destination) }
    switch (node, nodes[destination]) {
    case (_, .directory?): throw RemoteFileError.alreadyExists(destination)
    case (.directory, .file?): throw RemoteFileError.alreadyExists(destination)
    default: break
    }
    try makeParents(of: destination)
    if case .directory = node {
      for key in nodes.keys where key.hasPrefix(source + "/") {
        nodes[destination + key.dropFirst(source.count)] = nodes.removeValue(forKey: key)
      }
    }
    nodes[destination] = nodes.removeValue(forKey: source)
  }

  public func delete(_ path: String) async throws {
    let path = try RemotePath.normalize(path)
    guard !path.isEmpty else { throw RemoteFileError.invalidPath(path) }
    guard let node = nodes[path] else { throw RemoteFileError.notFound(path) }
    if case .directory = node, nodes.keys.contains(where: { $0.hasPrefix(path + "/") }) {
      throw RemoteFileError.directoryNotEmpty(path)
    }
    nodes[path] = nil
  }

  private func info(_ path: String) -> RemoteFileInfo? {
    switch nodes[path] {
    case nil: nil
    case .file(let data, let date): RemoteFileInfo(path: path, isDirectory: false, size: Int64(data.count), modified: date)
    case .directory(let date): RemoteFileInfo(path: path, isDirectory: true, modified: date)
    }
  }

  private func makeParents(of path: String) throws {
    let parts = path.split(separator: "/").map(String.init)
    let now = clock()
    for index in 1..<max(parts.count, 1) {
      let parent = parts[..<index].joined(separator: "/")
      switch nodes[parent] {
      case .file: throw RemoteFileError.notADirectory(parent)
      case .directory: continue
      case nil: nodes[parent] = .directory(now)
      }
    }
  }
}
