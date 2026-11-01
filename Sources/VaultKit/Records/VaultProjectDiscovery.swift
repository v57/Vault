import Foundation

/// What a dropped or picked folder holds, for adding it as projects: the git repositories in it, and the folders
/// beside them that hold none, which an app offers instead of skipping them silently (with what is in each, so it
/// can say which apps would use it). Git and Dev import through it; `VaultStore.arrangeProjects` then lays the
/// projects out in the tree as the folders are.
///
/// A repository is a directory with a `.git` entry (a directory, or a file for worktrees and submodules). The walk
/// never descends into one, so nested packages and submodules aren't listed separately. It skips hidden folders,
/// symlinks, packages (`.app`, `.xcodeproj`) and dependency and build folders, and stops `maxDepth` levels down.
///
/// ```swift
/// let found = await VaultProjectDiscovery.scan(droppedFolders)
/// add(found.flatMap(\.repositories))
/// suggestions = found.flatMap(\.skipped)
/// ```
public enum VaultProjectDiscovery {
  /// How deep the walk goes below the dropped folder: repositories sit a level or two down in practice, and the cap
  /// keeps a drop of `~` from walking the disk.
  public static let maxDepth = 6

  /// Folders never descended into or offered: build output and dependency caches.
  public static let ignoredNames: Set<String> = [
    "node_modules", "DerivedData", "build", "Build", "Pods", "Carthage", "vendor", "target", "dist",
    "__pycache__", "venv",
  ]

  public struct Result: Sendable, Equatable {
    /// The folder that was scanned.
    public var root: URL
    /// The repositories at or under `root`, in path order.
    public var repositories: [URL]
    /// The folders without a repository that sit beside one, in path order.
    public var skipped: [Skipped]
  }

  /// A folder the scan didn't add: it holds no repository, but one beside it does.
  public struct Skipped: Sendable, Hashable, Identifiable {
    public let url: URL
    /// What is in it (looked at a few levels down).
    public let contents: Contents
    /// It has the marks of a project at its top (a manifest, an Xcode project, a String Catalog), so an offer
    /// ticks it.
    public let looksLikeProject: Bool

    public var id: URL { url }

    public init(url: URL, contents: Contents, looksLikeProject: Bool) {
      self.url = url
      self.contents = contents
      self.looksLikeProject = looksLikeProject
    }
  }

  /// What a folder holds, for saying which apps would use it.
  public struct Contents: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Markdown files.
    public static let notes = Contents(rawValue: 1 << 0)
    /// An Xcode project.
    public static let xcode = Contents(rawValue: 1 << 1)
    /// A `Package.swift`.
    public static let swiftPackage = Contents(rawValue: 1 << 2)
    /// Source files or another manifest.
    public static let code = Contents(rawValue: 1 << 3)
    /// SQLite or DuckDB files.
    public static let database = Contents(rawValue: 1 << 4)
  }

  /// The repositories in `root` and the folders it skipped. A repository itself is the one result; a folder with
  /// none anywhere in it is the one folder skipped.
  public static func scan(_ root: URL) -> Result {
    let root = root.standardizedFileURL
    if isRepository(root) { return Result(root: root, repositories: [root], skipped: []) }
    var repositories: [URL] = []
    var skipped: [Skipped] = []
    if !walk(root, depth: 0, repositories: &repositories, skipped: &skipped) {
      skipped = [Skipped(url: root, contents: contents(of: root), looksLikeProject: looksLikeProject(root))]
    }
    return Result(
      root: root, repositories: repositories.sorted(by: pathOrder), skipped: skipped.sorted { pathOrder($0.url, $1.url) })
  }

  /// Scans each folder off the calling actor, in the order given.
  public static func scan(_ roots: [URL]) async -> [Result] {
    await Task.detached(priority: .userInitiated) { roots.map { scan($0) } }.value
  }

  /// A `.git` directory, or a `.git` file: a worktree's and a submodule's checkout point at their repository
  /// through one.
  public static func isRepository(_ directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
  }

  /// What `folder` holds, looking three levels down and at most a few thousand entries.
  public static func contents(of folder: URL) -> Contents {
    var contents = Contents()
    var budget = 4000
    look(folder, depth: 0, budget: &budget, into: &contents)
    return contents
  }

  // MARK: Walking

  /// Walks `directory` (not itself a repository) and answers whether a repository is somewhere below it. Children
  /// without one are reported as skipped only when a sibling has one: a subtree with no repository at all is the
  /// parent's to report, as one entry rather than every folder inside it.
  private static func walk(
    _ directory: URL, depth: Int, repositories: inout [URL], skipped: inout [Skipped]
  ) -> Bool {
    guard depth < maxDepth else { return false }
    var withRepository = false
    var without: [URL] = []
    var nested: [Skipped] = []
    for child in childDirectories(of: directory) {
      if isRepository(child) {
        repositories.append(child)
        withRepository = true
      } else if walk(child, depth: depth + 1, repositories: &repositories, skipped: &nested) {
        withRepository = true
      } else {
        without.append(child)
      }
    }
    skipped += nested
    if withRepository {
      skipped += without.map {
        Skipped(url: $0, contents: contents(of: $0), looksLikeProject: looksLikeProject($0))
      }
    }
    return withRepository
  }

  /// Visible, real directories: no hidden ones, no symlinks (they can leave the tree or loop), no packages,
  /// nothing in `ignoredNames`.
  private static func childDirectories(of directory: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
    guard
      let children = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return [] }
    return children.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        values.isPackage != true,
        // Dot folders are hidden by convention (Windows hides by attribute only).
        !url.lastPathComponent.hasPrefix("."),
        !ignoredNames.contains(url.lastPathComponent)
      else { return nil }
      return url.standardizedFileURL
    }
  }

  // MARK: Contents

  static let manifests: Set<String> = [
    "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "build.gradle", "build.gradle.kts",
    "CMakeLists.txt", "Makefile",
  ]
  static let noteExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
  static let sourceExtensions: Set<String> = [
    "swift", "m", "h", "c", "cc", "cpp", "rs", "go", "py", "js", "ts", "tsx", "jsx", "java", "kt", "rb", "cs", "sh",
  ]
  static let databaseExtensions: Set<String> = ["sqlite", "sqlite3", "db", "duckdb"]

  /// A manifest, an Xcode project or workspace, or a String Catalog at the top.
  private static func looksLikeProject(_ directory: URL) -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.contains { name in
      manifests.contains(name) || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
        || name.hasSuffix(".xcstrings")
    }
  }

  private static func look(_ directory: URL, depth: Int, budget: inout Int, into contents: inout Contents) {
    guard depth < 3, budget > 0,
      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return }
    var folders: [URL] = []
    for name in names where !name.hasPrefix(".") {
      budget -= 1
      if budget <= 0 { return }
      let ext = (name as NSString).pathExtension.lowercased()
      if name == "Package.swift" { contents.insert([.swiftPackage, .code]) }
      if manifests.contains(name) || sourceExtensions.contains(ext) { contents.insert(.code) }
      if noteExtensions.contains(ext) { contents.insert(.notes) }
      if databaseExtensions.contains(ext) { contents.insert(.database) }
      if ext == "xcodeproj" || ext == "xcworkspace" {
        contents.insert([.xcode, .code])
        continue
      }
      guard ext.isEmpty, !ignoredNames.contains(name) else { continue }
      var isDirectory: ObjCBool = false
      let url = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
        folders.append(url)
      }
    }
    for folder in folders { look(folder, depth: depth + 1, budget: &budget, into: &contents) }
  }

  private static func pathOrder(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
  }
}
