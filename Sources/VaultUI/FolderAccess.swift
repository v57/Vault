import ComponentKit
import Foundation
import VaultKit

/// Opens a folder the app needs (a project's, say), asking only when the sandbox makes it: without the sandbox the
/// folder comes back as it is; in it, the access remembered for it or a folder around it (`FolderGrants`), else the
/// open panel, once. The panel starts on the folder that holds it and `others` (the app's other projects), so picking
/// that one opens all of them from then on.
///
/// ```swift
/// guard let folder = await VaultFolderAccess.request(project.url, name: project.name, among: projects.map(\.url))
/// else { return }  // cancelled
/// ```
public enum VaultFolderAccess {
  /// The folder, ready to open; nil when the user cancelled the panel (or, on iPhone and iPad, where there's no
  /// panel, when it hasn't been granted). `message` replaces the panel's own explanation.
  @MainActor public static func request(
    _ folder: URL, name: String, among others: [URL] = [], message: String? = nil, grants: FolderGrants = .shared
  ) async -> URL? {
    if let folder = grants.access(to: folder) { return folder }
    let around = FolderGrants.folder(around: folder, among: others)
    let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? String(localized: "The app")
    let isAround = around.standardizedFileURL.path != folder.standardizedFileURL.path
    let explanation =
      message
      ?? (isAround
        ? String(localized: "Open “\(name)” in \(app). Choose “\(around.lastPathComponent)” to open every project in it without asking again.")
        : String(localized: "Open “\(name)” in \(app). \(app) opens only folders you choose."))
    guard
      let picked = await KitDesktop.chooseFolders(prompt: String(localized: "Open"), message: explanation, directory: around).first
    else { return nil }
    return grants.grant(picked, for: folder)
  }
}
