import Foundation

/// A saved database connection, shared by Database, DatabasePro and Shell.
///
/// The model is DatabasePro's (the most complete); Database and Shell read what they support and leave the
/// rest alone. Engine-specific settings are `options` (`authSource`, `replicaSet`, `directConnection`,
/// `authMechanism`, `consistency`…), each its own field so two devices changing different options merge.
/// The password is a `VaultSecrets` item named after the connection.
public struct VaultDatabase: VaultRecord, Hashable {
  public static let kind = "database"
  public static let dynamicPrefixes = ["option."]

  /// Engine names, as DatabasePro's `EngineKind` raw values.
  public enum Engine {
    public static let postgres = "postgres"
    public static let mysql = "mysql"
    public static let mariadb = "mariadb"
    public static let sqlserver = "sqlserver"
    public static let sqlite = "sqlite"
    public static let duckdb = "duckdb"
    public static let mongodb = "mongodb"
    public static let redis = "redis"
    public static let cassandra = "cassandra"
    public static let scylla = "scylla"
  }

  public var id: String
  public var name: String
  public var engine: String
  public var host: String
  public var port: Int
  public var user: String
  /// Default database, keyspace or Redis index.
  public var database: String
  /// SQLite and DuckDB files.
  public var filePath: String
  public var options: [String: String]
  /// Sidebar color tag ("none", "red", …).
  public var color: String
  public var isProduction: Bool
  public var isReadOnly: Bool
  public var useTLS: Bool
  public var allowUntrustedCertificate: Bool
  /// The `VaultHost` to tunnel through, if any.
  public var sshHostID: String?
  public var savePassword: Bool
  public var order: Int
  public var lastUsed: Date?

  public init(
    id: String = UUID().uuidString, name: String = "", engine: String, host: String = "127.0.0.1", port: Int,
    user: String = "", database: String = "", filePath: String = "", options: [String: String] = [:],
    color: String = "none", isProduction: Bool = false, isReadOnly: Bool = false, useTLS: Bool = false,
    allowUntrustedCertificate: Bool = false, sshHostID: String? = nil, savePassword: Bool = true, order: Int = 0,
    lastUsed: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.engine = engine
    self.host = host
    self.port = port
    self.user = user
    self.database = database
    self.filePath = filePath
    self.options = options
    self.color = color
    self.isProduction = isProduction
    self.isReadOnly = isReadOnly
    self.useTLS = useTLS
    self.allowUntrustedCertificate = allowUntrustedCertificate
    self.sshHostID = sshHostID
    self.savePassword = savePassword
    self.order = order
    self.lastUsed = lastUsed
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    engine = read.string("engine", default: Engine.postgres)
    host = read.string("host", default: "")
    port = read.int("port", default: 0)
    user = read.string("user", default: "")
    database = read.string("database", default: "")
    filePath = read.string("filePath", default: "")
    options = read.strings(prefixed: "option")
    color = read.string("color", default: "none")
    isProduction = read.bool("isProduction")
    isReadOnly = read.bool("isReadOnly")
    useTLS = read.bool("useTLS")
    allowUntrustedCertificate = read.bool("allowUntrustedCertificate")
    sshHostID = read.string("sshHostID")
    savePassword = read.bool("savePassword", default: true)
    order = read.int("order", default: 0)
    lastUsed = read.date("lastUsed")
  }

  public var values: [String: JSONValue] {
    var values: [String: JSONValue] = [
      "name": .string(name), "engine": .string(engine), "host": .string(host), "port": .init(port),
      "user": .string(user), "database": .string(database), "filePath": .string(filePath), "color": .string(color),
      "isProduction": .bool(isProduction), "isReadOnly": .bool(isReadOnly), "useTLS": .bool(useTLS),
      "allowUntrustedCertificate": .bool(allowUntrustedCertificate), "sshHostID": .init(sshHostID),
      "savePassword": .bool(savePassword), "order": .init(order), "lastUsed": .init(lastUsed),
    ]
    values.set(options, prefixed: "option")
    return values
  }

  public var password: String? { VaultSecrets.password(for: id) }
  public var isFileBased: Bool { engine == Engine.sqlite || engine == Engine.duckdb }

  /// The SSH host this connection goes through: the one it names, or else the saved host whose name or
  /// address is the database's server (so a database added on a server you SSH into attaches to it).
  public func tunnelHost(in hosts: [VaultHost]) -> VaultHost? {
    if let sshHostID { return hosts.first { $0.id == sshHostID } }
    guard !isFileBased, !Self.isLocal(host) else { return nil }
    return hosts.first { $0.serves(host) }
  }

  /// Where the tunnel connects on the far side: a database named after the SSH host itself listens on that
  /// machine, so the tunnel goes to its loopback; any other address is reached from the host as written.
  public func tunnelTarget(through sshHost: VaultHost) -> String {
    Self.isLocal(host) || sshHost.serves(host) ? "127.0.0.1" : host
  }

  public static func isLocal(_ host: String) -> Bool {
    ["", "localhost", "127.0.0.1", "::1"].contains(host.lowercased())
  }
}
