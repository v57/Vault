import Foundation

/// The folders the user let a sandboxed app open, remembered on this device: a security-scoped bookmark per folder
/// (canonical path), kept in the app's settings, so a folder picked once opens again without asking, also after a
/// relaunch and for any folder inside it. Without the sandbox every folder opens and nothing is asked or kept.
/// `VaultFolderAccess` (VaultUI) asks with the open panel when there's no grant yet.
///
/// ```swift
/// let grants = FolderGrants()
/// if let folder = grants.access(to: project) { open(folder) }               // nil: ask the user first
/// open(grants.grant(picked, for: project))                                  // what they picked in the panel
/// ```
@MainActor public final class FolderGrants {
  /// The app's grants in its standard settings.
  public static let shared = FolderGrants()

  private let defaults: UserDefaults
  private let key: String
  /// The folders whose access this run started (kept open while the app runs).
  private var accessing: Set<URL> = []

  /// Grants kept under `key` in `defaults` (an app's test or demo runs pass their own).
  public init(defaults: UserDefaults = .standard, key: String = "GrantedFolders") {
    self.defaults = defaults
    self.key = key
  }

  /// The folder, ready to open: as it is without the sandbox; in it, with the access granted earlier to it or a folder
  /// around it, started for this run. Nil when the user has to pick it first.
  public func access(to folder: URL) -> URL? {
    guard AppSandbox.isOn else { return folder }
    #if os(macOS)
      let path = Self.canonical(folder).path
      var granted = grants
      defer { if granted != grants { grants = granted } }
      let candidates = granted.keys.filter { path == $0 || path.hasPrefix($0 + "/") }.sorted { $0.count > $1.count }
      for candidate in candidates {
        var isStale = false
        guard let bookmark = granted[candidate],
          let url = try? URL(
            resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
            bookmarkDataIsStale: &isStale),
          Self.canonical(url).path == candidate, url.startAccessingSecurityScopedResource()
        else {
          granted[candidate] = nil
          continue
        }
        accessing.insert(url)
        if isStale {
          granted[candidate] = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return path == candidate ? url : folder
      }
      return nil
    #else
      // iPhone and iPad: the app's own file picker gives the access (security-scoped bookmarks are the Mac's).
      return folder
    #endif
  }

  /// Takes what the user picked in the open panel for `folder`: a folder around it (or the folder itself) is
  /// remembered and `folder` comes back with its access; any other pick comes back as it is, with the access the
  /// panel gave it for this run.
  public func grant(_ picked: URL, for folder: URL) -> URL {
    let root = Self.canonical(picked).path
    let path = Self.canonical(folder).path
    guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return picked }
    #if os(macOS)
      if picked.startAccessingSecurityScopedResource() { accessing.insert(picked) }
      if let bookmark = try? picked.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      {
        remember(bookmark, for: picked)
      }
    #endif
    return path == root ? picked : folder
  }

  /// Keeps a bookmark the app made itself (a folder it added with the user's pick) as that folder's grant.
  public func remember(_ bookmark: Data, for folder: URL) {
    grants[Self.canonical(folder).path] = bookmark
  }

  /// Where the open panel for `folder` starts: the folder that holds it and every one of `others` (an app's projects)
  /// when that is narrower than the home folder, so one pick there opens them all; otherwise `folder` itself.
  public nonisolated static func folder(around folder: URL, among others: [URL]) -> URL {
    let folder = canonical(folder)
    var common = folder.pathComponents
    for other in others {
      common = Array(zip(common, canonical(other).pathComponents).prefix { $0 == $1 }.map(\.0))
    }
    let home = canonical(URL(fileURLWithPath: realHome, isDirectory: true)).pathComponents
    guard common.count > home.count, common.starts(with: home) else { return folder }
    return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
  }

  private var grants: [String: Data] {
    get { defaults.dictionary(forKey: key) as? [String: Data] ?? [:] }
    set { defaults.set(newValue, forKey: key) }
  }

  /// One spelling per folder: standardized, no trailing slash, no base URL.
  private nonisolated static func canonical(_ url: URL) -> URL {
    URL(fileURLWithPath: url.standardizedFileURL.path)
  }

  /// The user's home folder (in the sandbox `NSHomeDirectory()` is the app's container).
  private nonisolated static var realHome: String {
    #if canImport(Darwin)
      getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
    #else
      NSHomeDirectory()
    #endif
  }
}
