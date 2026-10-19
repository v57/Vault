import Foundation

extension VaultProject {
  /// What a project is, from the files in its folder: an app picks the projects it works on by these (Dev
  /// lists only Xcode projects). A struct rather than an enum, so a kind a newer app writes survives.
  public struct Kind: RawRepresentable, Hashable, Sendable, Comparable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// An `.xcodeproj` in the folder or in a folder right inside it.
    public static let xcode = Kind(rawValue: "xcode")
    /// A `Package.swift` in the folder.
    public static let swiftPackage = Kind(rawValue: "swiftPackage")

    public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

    /// The kinds of the project in `folder`. Looks at the folder and the folders right inside it (an app's
    /// project is often one level down), skipping hidden ones and build output.
    public static func detect(in folder: URL) -> Set<Kind> {
      let fileManager = FileManager.default
      let top = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
      var kinds = Set<Kind>()
      if top.contains("Package.swift") { kinds.insert(.swiftPackage) }
      if top.contains(where: { $0.hasSuffix(".xcodeproj") }) { return kinds.union([.xcode]) }
      for name in top where !name.hasPrefix(".") && !skippedFolders.contains(name) {
        let inner = folder.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inner.path, isDirectory: &isDirectory), isDirectory.boolValue,
          let names = try? fileManager.contentsOfDirectory(atPath: inner.path)
        else { continue }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") }) { return kinds.union([.xcode]) }
      }
      return kinds
    }

    static let skippedFolders: Set<String> = ["build", "Build", "DerivedData", "node_modules", "Pods", "Carthage"]
  }
}

extension VaultStore {
  /// Looks again at the folders of this device's projects and saves the kinds that changed (only those
  /// fields, so it costs nothing when nothing did). Folders missing on this device keep the kinds they had.
  public func refreshProjectKinds() throws {
    let fileManager = FileManager.default
    for var project in try records(VaultProject.self) {
      guard let path = project.paths[deviceID], fileManager.fileExists(atPath: path) else { continue }
      let kinds = VaultProject.Kind.detect(in: URL(fileURLWithPath: path, isDirectory: true))
      guard kinds != project.kinds else { continue }
      project.kinds = kinds
      try save(project)
    }
  }
}
