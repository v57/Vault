import CryptoKit
import Foundation

extension VaultStore {
  /// The largest icon a project keeps: a thumbnail, not the picture itself.
  public static let maxProjectIconSize = 64 * 1024

  /// Gives this device's projects their icons. `find` names the image file that is a folder's icon (Code's
  /// `ProjectIcon.find`), `thumbnail` turns it into the small PNG the vault keeps (`ProjectIcon.thumbnail`). An icon
  /// is made again only when its file's contents changed (`iconSource` is their hash; an Icon Composer icon's
  /// `icon.json` with its assets). A folder that has no icon loses the one it had; a folder this device can't read
  /// keeps it. `ids` limits it to some projects. Safe to call off the main thread (the store is locked only to read
  /// and save, not while looking).
  public func refreshProjectIcons(
    ids: Set<String>? = nil, find: (URL) -> URL?, thumbnail: (URL) -> Data?
  ) throws {
    for project in try records(VaultProject.self) where ids?.contains(project.id) ?? true {
      guard let path = project.paths[deviceID], (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
      else { continue }
      guard let file = find(URL(fileURLWithPath: path, isDirectory: true)), let contents = Self.iconContents(file)
      else {
        if project.icon != nil || project.iconSource != nil, var current = try record(VaultProject.self, id: project.id) {
          current.icon = nil
          current.iconSource = nil
          try save(current)
        }
        continue
      }
      let source = SHA256.hash(data: contents).prefix(12).map { String(format: "%02x", $0) }.joined()
      guard source != project.iconSource, let icon = thumbnail(file), icon.count <= Self.maxProjectIconSize,
        var current = try record(VaultProject.self, id: project.id)
      else { continue }
      current.icon = icon
      current.iconSource = source
      try save(current)
    }
  }

  /// What an icon file holds, for telling when it changed: the file, or for an Icon Composer icon's `icon.json` the
  /// files of its `.icon` folder (a new glyph changes only `Assets/`), in path order.
  static func iconContents(_ file: URL) -> Data? {
    let folder = file.deletingLastPathComponent()
    guard folder.pathExtension == "icon",
      let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
    else { return try? Data(contentsOf: file) }
    var contents = Data()
    let files = walker.compactMap { $0 as? URL }
      .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
      .sorted { $0.path < $1.path }
    for url in files {
      contents.append(Data(url.path.dropFirst(folder.path.count).utf8))
      guard let data = try? Data(contentsOf: url) else { return nil }
      contents.append(data)
    }
    return contents.isEmpty ? nil : contents
  }
}
