import Foundation

/// What a drop found that the vault doesn't have yet, for VaultUI's `VaultImportSheet` to offer: repositories and
/// folders as projects, database files as connections. Nil when there is nothing new, so an app shows the sheet only
/// when it has something to ask.
///
/// ```swift
/// offer = await VaultImportOffer.scan(droppedURLs, store: vault.store)
/// ```
public struct VaultImportOffer: Identifiable, Sendable {
  public let id = UUID()
  /// The dropped folders and files.
  public let roots: [URL]
  /// Repositories that aren't projects yet.
  public let repositories: [URL]
  /// Folders without a repository that aren't projects yet (and hold more than databases).
  public let folders: [VaultProjectDiscovery.Skipped]
  /// Database files no connection opens yet.
  public let databases: [VaultProjectDiscovery.DatabaseFile]

  public var isEmpty: Bool { repositories.isEmpty && folders.isEmpty && databases.isEmpty }

  /// What `results` found that `store` doesn't have; nil when that is nothing (or there is no store).
  public init?(_ results: [VaultProjectDiscovery.Result], store: VaultStore?) {
    guard let store else { return nil }
    let projects = Set(((try? store.records(VaultProject.self)) ?? []).compactMap { $0.paths[store.deviceID] })
    let files = Set(((try? store.records(VaultDatabase.self)) ?? []).map(\.filePath))
    roots = results.map(\.root)
    repositories = results.flatMap(\.repositories).filter { !projects.contains($0.path) }
    // A folder of databases alone is no project: its databases are offered.
    folders = results.flatMap(\.skipped).filter { !projects.contains($0.url.path) && $0.contents != .database }
    databases = results.flatMap(\.databases).filter { !files.contains($0.url.path) }
    if isEmpty { return nil }
  }
}

extension VaultImportOffer {
  /// Scans dropped folders and files (off the calling actor) and keeps what `store` doesn't have.
  public static func scan(_ urls: [URL], store: VaultStore?) async -> VaultImportOffer? {
    let urls = urls.filter(\.isFileURL)
    guard !urls.isEmpty else { return nil }
    return VaultImportOffer(await VaultProjectDiscovery.scan(urls), store: store)
  }
}

extension VaultStore {
  /// Saves a SQLite or DuckDB file as a database connection (Database and Shell list it), named after the file;
  /// the connection that opens that file already, if there is one.
  @discardableResult
  public func addDatabaseFile(_ file: VaultProjectDiscovery.DatabaseFile) throws -> VaultDatabase {
    let databases = try records(VaultDatabase.self)
    if let existing = databases.first(where: { $0.filePath == file.url.path }) { return existing }
    let database = VaultDatabase(
      name: file.url.deletingPathExtension().lastPathComponent, engine: file.engine, host: "", port: 0,
      filePath: file.url.path, order: (databases.map(\.order).max() ?? -1) + 1)
    try save(database)
    return database
  }
}
