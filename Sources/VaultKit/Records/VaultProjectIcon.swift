import CryptoKit
import Foundation

extension VaultStore {
  /// The largest icon a project keeps: a thumbnail, not the picture itself.
  public static let maxProjectIconSize = 64 * 1024

  /// Gives this device's projects their icons. `find` names the image file that is a folder's icon (Code's
  /// `ProjectIcon.find`), `thumbnail` turns it into the small PNG the vault keeps (`ProjectIcon.thumbnail`). An icon
  /// is made again only when its file's contents changed (`iconSource` is their hash), and a project keeps its icon
  /// when this device finds none. `ids` limits it to some projects. Safe to call off the main thread (the store is
  /// locked only to read and save, not while looking).
  public func refreshProjectIcons(
    ids: Set<String>? = nil, find: (URL) -> URL?, thumbnail: (URL) -> Data?
  ) throws {
    for project in try records(VaultProject.self) where ids?.contains(project.id) ?? true {
      guard let path = project.paths[deviceID],
        let file = find(URL(fileURLWithPath: path, isDirectory: true)),
        let contents = try? Data(contentsOf: file)
      else { continue }
      let source = SHA256.hash(data: contents).prefix(12).map { String(format: "%02x", $0) }.joined()
      guard source != project.iconSource, let icon = thumbnail(file), icon.count <= Self.maxProjectIconSize,
        var current = try record(VaultProject.self, id: project.id)
      else { continue }
      current.icon = icon
      current.iconSource = source
      try save(current)
    }
  }
}
