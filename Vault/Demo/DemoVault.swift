import ComponentKit
import Foundation
import VaultFiles
import VaultKit

/// The demo vault (`--demo`): a store in a temporary folder with in-memory keys, secrets and identity, seeded with
/// the design's data. Folders are real encrypted folders on disk, decrypted for real; only what VaultKit doesn't do
/// yet (folder sync, remote backends, the recovery key) comes from sample data. Never the user's vault.
enum DemoVault {
  static let thisDevice = "studio-mac"
  static let airDevice = "macbook-air"
  static let padDevice = "ipad-pro"

  @MainActor
  static func make() -> AppModel {
    VaultSecrets.useInMemoryStore()
    VaultPersonalIdentity.useInMemoryStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("VaultDemo", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let keys = MemoryKeyProvider()
    do {
      let store = try VaultStore(directory: root.appendingPathComponent("store"), keys: keys, deviceID: thisDevice, notifier: nil)
      let air = try VaultStore(directory: root.appendingPathComponent("store"), keys: keys, deviceID: airDevice, notifier: nil)
      let pad = try VaultStore(directory: root.appendingPathComponent("store"), keys: keys, deviceID: padDevice, notifier: nil)
      try seed(store: store, air: air, pad: pad, keys: keys, root: root)
      let vault = Vault(store: store)
      let folders = FolderLibrary(vault: vault, keys: keys, sync: DemoFolderSync(vault: vault), decryptedRoot: root.appendingPathComponent("Decrypted"))
      let remotes = RemoteLibrary(vault: vault, backends: remoteBackends(vault), offline: Set(vault.remotes.filter { $0.name == "nas" }.map(\.id)), home: root.appendingPathComponent("Folders"))
      let sharing = PeopleLibrary(
        vault: vault, deliversFolderKeys: true,
        sharedItems: Dictionary(uniqueKeysWithValues: vault.logins.filter { $0.title == "Figma" }.map { ($0.id, "Maya") }))
      let model = AppModel(vault: vault, isDemo: true, folders: folders, remotes: remotes, sharing: sharing, recovery: DemoRecovery())
      model.lastSync = .now.addingTimeInterval(-70)
      // atlas-design is decrypted for other apps, with 24 minutes left.
      if let design = vault.folders.first(where: { $0.name == "atlas-design" }) {
        try? folders.decrypt(design.id, for: 24 * 60 + 20)
      }
      return model
    } catch {
      fatalError("The demo vault couldn't be made: \(error)")
    }
  }

  // MARK: Records

  private static func day(_ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
    let year = Calendar.current.component(.year, from: .now)
    return Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .now
  }

  private static func keyLine(_ seed: String, _ name: String) -> String {
    var bytes = Data(seed.utf8)
    while bytes.count < 104 { bytes += Data(seed.utf8.reversed()) }
    return "ecdsa-sha2-nistp256 \(bytes.prefix(104).base64EncodedString()) \(name)"
  }

  private static func seed(store: VaultStore, air: VaultStore, pad: VaultStore, keys: VaultKeyProvider, root: URL) throws {
    // Devices: each with its own Secure Enclave key, published so the others can add it to servers.
    try store.save(VaultDeviceKey(id: thisDevice, deviceName: "Studio Mac", publicKey: keyLine("studio", "Studio Mac"), platform: "macOS", updated: day(9, 30)))
    try store.save(VaultDeviceKey(id: airDevice, deviceName: "MacBook Air", publicKey: keyLine("air", "MacBook Air"), platform: "macOS", updated: day(9, 30)))
    try store.save(VaultDeviceKey(id: padDevice, deviceName: "iPad Pro", publicKey: keyLine("ipad", "iPad Pro"), platform: "iOS", updated: day(10, 2)))

    // SSH hosts, as Shell and Database share them.
    let web1 = VaultHost(name: "atlas-web-1", hostname: "atlas-web-1.atlas.example.com", user: "deploy", order: 0, source: "shell")
    let web2 = VaultHost(name: "atlas-web-2", hostname: "atlas-web-2.atlas.example.com", user: "deploy", order: 1, source: "shell")
    let bastion = VaultHost(name: "bastion", hostname: "bastion.atlas.example.com", port: 2222, user: "aiko", order: 2, source: "shell")
    let staging = VaultHost(name: "staging", hostname: "staging.atlas.example.com", user: "deploy", jumpHostID: bastion.id, order: 3, source: "shell")
    let replica = VaultHost(name: "db-replica", hostname: "10.0.4.12", user: "postgres", auth: .password, jumpHostID: bastion.id, order: 4)
    let studio = VaultHost(name: "studio-mac", hostname: "studio-mac.local", user: "aiko", order: 5, source: "shell")
    let build = VaultHost(name: "build-linux", hostname: "192.168.1.40", user: "ci", auth: .importedKey, order: 6, source: "dev-vm")
    let nas = VaultHost(name: "nas", hostname: "nas.local", user: "admin", auth: .password, order: 7)
    let pi = VaultHost(name: "Raspberry Pi", hostname: "pi.local", user: "pi", auth: .password, order: 8)
    for host in [web1, web2, bastion, staging, replica, studio, build, nas, pi] { try store.save(host) }
    try VaultSecrets.setPassword("replica-reader-2026", for: replica.id)
    try VaultSecrets.setPassword("nas-admin-Lm2x", for: nas.id)
    try store.trust(fingerprint: "SHA256:Xk2PbQ8vUe5nT1aZcR7mJ4wY9dLf3hG6sK0oPq2r9Qa", host: web1.hostname, port: 22, keyType: "ed25519")
    try store.trust(fingerprint: "SHA256:Bm7cW2xQ4kLp9vN1sT6yR3eH8jF5gD0aZu2oXi7k1Pw", host: bastion.hostname, port: 2222, keyType: "ed25519")

    // Database connections.
    let production = VaultDatabase(name: "Atlas production", engine: VaultDatabase.Engine.postgres, host: "10.0.1.5", port: 5432, user: "atlas", database: "atlas", isProduction: true, useTLS: true, sshHostID: web1.id, order: 0)
    let databases = [
      production,
      VaultDatabase(name: "Atlas staging", engine: VaultDatabase.Engine.postgres, host: "10.0.2.5", port: 5432, user: "atlas", database: "atlas", sshHostID: staging.id, order: 1),
      VaultDatabase(name: "Analytics replica", engine: VaultDatabase.Engine.postgres, host: "10.0.4.12", port: 5432, user: "reader", database: "analytics", isReadOnly: true, sshHostID: bastion.id, order: 2),
      VaultDatabase(name: "Orders", engine: VaultDatabase.Engine.mysql, host: "10.0.1.7", port: 3306, user: "orders", database: "shop", sshHostID: web2.id, order: 3),
      VaultDatabase(name: "Catalog", engine: VaultDatabase.Engine.mongodb, host: "10.0.1.9", port: 27017, user: "catalog", database: "catalog", order: 4),
      VaultDatabase(name: "Sessions", engine: VaultDatabase.Engine.redis, host: "10.0.1.11", port: 6379, database: "0", sshHostID: web1.id, order: 5),
      VaultDatabase(name: "Cache", engine: VaultDatabase.Engine.redis, host: "127.0.0.1", port: 6379, database: "1", order: 6),
      VaultDatabase(name: "Field Notes", engine: VaultDatabase.Engine.sqlite, port: 0, filePath: "~/Developer/Field Notes/notes.sqlite", order: 7),
      VaultDatabase(name: "Metrics", engine: VaultDatabase.Engine.duckdb, port: 0, filePath: "~/Data/metrics.duckdb", order: 8),
      VaultDatabase(name: "Events", engine: VaultDatabase.Engine.cassandra, host: "10.0.3.2", port: 9042, user: "events", database: "events", order: 9),
    ]
    for database in databases { try store.save(database) }
    try VaultSecrets.setPassword("pg-atlas-9KpR", for: production.id)

    // Projects with folders on this Mac (and some on the others).
    var atlas: VaultProject?
    for (index, name) in ["atlas", "atlas-web", "Weather", "Field Notes", "harbor", "Lisbon Guide", "Shell", "Vault"].enumerated() {
      var project = try store.addProject(path: "\(NSHomeDirectory())/Developer/\(name)", name: name, remoteURL: "https://github.com/atlas/\(name.lowercased().replacingOccurrences(of: " ", with: "-")).git")
      project.paths[airDevice] = "/Users/aiko/Developer/\(name)"
      project.order = index
      try store.save(project)
      if name == "atlas" { atlas = project }
    }

    // Notes from Markdown and Shell.
    for (name, folder, encrypted, text) in [
      ("Release checklist", "Atlas", false, "Bump the version, tag, run the release workflow, post the notes."),
      ("Server inventory", "Atlas", true, "atlas-web-1 and atlas-web-2 behind the bastion; the replica on 10.0.4.12."),
      ("Lisbon trip", "Personal", false, "Tram 28 early, Pastéis de Belém, Sintra on Thursday."),
      ("Recovery codes", "Personal", true, "GitHub, Cloudflare and Figma backup codes."),
      ("Meeting notes", "Atlas", false, "Ship the offline maps before the conference."),
      ("Wi-Fi", "Home", true, "Network names and the guest password."),
    ] {
      try store.save(VaultNote(folder: folder, name: name, encrypted: encrypted, text: text))
    }

    // Folders: real encrypted folders on disk, their keys wrapped by the vault key.
    let remotesRoot = root.appendingPathComponent("Folders")
    let studioRemote = VaultRemote(name: "studio-mac", kind: .sftp, endpoint: "studio-mac.local", path: "/srv/vault", hostID: studio.id, user: "aiko", enabled: true, order: 0)
    let backups = VaultRemote(name: "backups", kind: .s3, endpoint: "https://4f1c09e2b7.r2.cloudflarestorage.com", bucket: "atlas-backups", region: "auto", accessKeyID: "8d2e61b0c4f9a7e3", enabled: true, order: 1)
    let nasRemote = VaultRemote(name: "nas", kind: .smb, endpoint: "smb://nas.local/vault", user: "admin", enabled: true, order: 2)
    for remote in [studioRemote, backups, nasRemote] { try store.save(remote) }
    try store.setSecret("r2-secret-demo", forRemote: backups.id)

    let design = try makeFolder("atlas-design", files: DemoFiles.design, in: remotesRoot, keys: keys, remote: studioRemote, store: store, order: 0)
    let taxes = try makeFolder("Taxes 2026", files: DemoFiles.taxes, in: remotesRoot, keys: keys, remote: backups, store: store, order: 1)
    let photosFolder = try makeFolder("Photos 2026", files: DemoFiles.photos, in: remotesRoot, keys: keys, remote: studioRemote, store: store, order: 2, plain: true, readOnly: true)
    _ = try makeFolder("Contracts", files: DemoFiles.contracts, in: remotesRoot, keys: keys, remote: nasRemote, store: store, order: 3, readOnly: true)
    // The MacBook Air keeps them encrypted; Taxes isn't on the iPad.
    for folder in [design, taxes, photosFolder] {
      var record = folder
      record.setStorage(.encrypted, for: airDevice)
      if folder.id == taxes.id { record.setStorage(nil, for: padDevice) }
      try store.save(record)
    }

    // People: their keys arrived by QR code; Maya and Jonas compared the safety code, Rafael hasn't yet.
    VaultPersonalIdentity.useInMemoryStore()
    _ = try VaultPersonalIdentity.current()
    let photos = try store.records(VaultFolder.self).first { $0.name == "Photos 2026" }
    var maya = VaultPerson(name: "Maya Okafor", identity: PersonalIdentity().publicIdentity, status: .verified, verified: day(10, 2), roles: [design.id: .readWrite], created: day(10, 2))
    maya.roles["design-logins"] = .readOnly
    try store.save(maya)
    try store.save(VaultPerson(name: "Jonas Berg", identity: PersonalIdentity().publicIdentity, status: .verified, verified: day(9, 20), roles: photos.map { [$0.id: .readWrite] } ?? [:], created: day(9, 20)))
    try store.save(VaultPerson(name: "Rafael Silva", identity: PersonalIdentity().publicIdentity, status: .waiting, created: day(10, 19)))

    // Logins: passwords and codes as secrets; some fields last changed on the other devices.
    let otp = "otpauth://totp/Atlas:aiko?secret=JBSWY3DPEHPK3PXP&issuer=Atlas"
    let logins: [(String, String, String, Bool, Set<String>, Bool)] = [
      ("Apple Developer", "developer.apple.com", "aiko@atlas.example.com", false, [], true),
      ("Atlas admin", "atlas.example.com", "aiko", true, [web1.id, production.id, design.id, atlas?.id ?? ""], true),
      ("Atlas staging", "staging.atlas.example.com", "aiko", false, [staging.id, databases[1].id], false),
      ("Cloudflare", "dash.cloudflare.com", "aiko@atlas.example.com", true, [backups.id], true),
      ("Docker Hub", "hub.docker.com", "atlasci", false, [], false),
      ("Figma", "figma.com", "design@atlas.example.com", false, [], false),
      ("GitHub", "github.com", "aiko-tanaka", true, [atlas?.id ?? ""], true),
      ("Hetzner Console", "console.hetzner.com", "aiko@atlas.example.com", false, [web1.id, web2.id], true),
      ("pgAdmin (staging)", "10.0.4.12", "postgres", false, [replica.id], false),
      ("Ubiquiti", "unifi.local", "admin", false, [], false),
    ]
    let generator = PasswordGenerator()
    for (index, (title, website, username, favorite, links, hasCode)) in logins.enumerated() {
      let login = VaultLogin(title: title, website: website, username: username, favorite: favorite, order: index, created: day(8, 1), links: links.filter { !$0.isEmpty })
      try store.save(login)
      try store.setPassword(title == "Atlas admin" ? "vT7q-Lm2x-9KpR-wd4Z" : generator.generate(), forLogin: login.id, now: day(10, 12))
      if hasCode { try pad.setOneTimeCode(otp, forLogin: login.id, now: day(10, 3)) }
    }
    // Atlas admin's username was last set on the MacBook Air.
    if let admin = try store.records(VaultLogin.self).first(where: { $0.title == "Atlas admin" }) {
      try air.save(id: admin.id, kind: VaultLogin.kind, changes: ["username": .string("aiko ")])
      try air.save(id: admin.id, kind: VaultLogin.kind, changes: ["username": .string("aiko")])
    }

    // Cards.
    for (title, holder, last4, expiry, brand) in [
      ("Atlas company card", "Aiko Tanaka", "4417", "08/28", "Visa"), ("Personal", "Aiko Tanaka", "9012", "03/27", "Mastercard"),
      ("Travel", "Aiko Tanaka", "1005", "11/29", "Amex"),
    ] {
      let card = VaultCard(title: title, holder: holder, last4: last4, expiry: expiry, brand: brand)
      try store.save(card)
      try store.setCardNumber("4417 1234 5678 \(last4)", forCard: card.id)
      try store.setCardCode("123", forCard: card.id)
    }
  }

  /// An encrypted (or plain) folder on disk with demo files, its record pointing at it on this device.
  private static func makeFolder(
    _ name: String, files: [DemoFiles.File], in parent: URL, keys: VaultKeyProvider, remote: VaultRemote,
    store: VaultStore, order: Int, plain: Bool = false, readOnly: Bool = false
  ) throws -> VaultFolder {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    let key = FolderKey()
    if plain {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      for file in files { try DemoFiles.writePlain(file, in: url) }
    } else {
      let folder = try EncryptedFolder(url: url, key: key)
      for file in files { try DemoFiles.write(file, in: folder) }
    }
    var record = VaultFolder(
      name: name, encrypted: !plain, wrappedKey: try key.wrapped(with: keys), remoteID: remote.id,
      remotePath: "\(remote.path.isEmpty ? "" : remote.path)/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))", order: order)
    record.setPath(url.path, for: thisDevice)
    record.setStorage(plain ? .plain : .encrypted, for: thisDevice)
    if readOnly { record.setMode(.readOnly, for: thisDevice) }
    record.setStorage(plain ? .plain : .encrypted, for: padDevice)
    try store.save(record)
    return record
  }

  // MARK: Remotes

  /// Sample listings for the remotes (the backends are a follow-up): what each one holds, as ciphertext.
  @MainActor
  private static func remoteBackends(_ vault: Vault) -> [String: any RemoteFileSystem] {
    var backends: [String: any RemoteFileSystem] = [:]
    for remote in vault.remotes where remote.kind != .smb {
      var files: [String: Data] = [:]
      for folder in vault.folders where folder.remoteID == remote.id {
        let base = folder.name.lowercased().replacingOccurrences(of: " ", with: "-")
        files["\(base)/members"] = Data(repeating: 1, count: 1_200)
        for index in 0..<6 { files["\(base)/chunks/\(String(format: "%02x", index * 37))e1c9"] = Data(repeating: 2, count: 64_000) }
        files["\(base)/log/studio-mac/000184"] = Data(repeating: 3, count: 3_400)
        files["\(base)/log/macbook-air/000097"] = Data(repeating: 3, count: 2_100)
        files["\(base)/snapshots/2026-10-19"] = Data(repeating: 4, count: 48_000)
      }
      backends[remote.id] = MemoryRemoteFileSystem(files: files)
    }
    return backends
  }
}

/// Demo recovery: makes a key on request and shows its words (the wrapping and the stored blobs are a follow-up).
@MainActor
final class DemoRecovery: RecoveryService {
  private(set) var isOn = false
  var isAvailable: Bool { true }

  func create() throws -> [String] {
    isOn = true
    return [
      "orbit", "lantern", "maple", "fossil", "cradle", "velvet", "harbor", "ember", "quiet", "saddle", "tundra", "pixel",
      "anchor", "willow", "copper", "meadow", "falcon", "riddle", "summit", "pebble", "canyon", "violet", "thimble", "glacier",
    ]
  }
}
