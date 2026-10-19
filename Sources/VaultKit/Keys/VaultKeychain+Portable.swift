#if !canImport(Security)
  import Foundation

  #if os(Windows)
    import WinSDK
  #endif

  /// Keychain status codes, as Apple's Security framework numbers them.
  public typealias OSStatus = Int32
  public let errSecSuccess: OSStatus = 0
  public let errSecParam: OSStatus = -50
  public let errSecIO: OSStatus = -36
  public let errSecDuplicateItem: OSStatus = -25299
  public let errSecItemNotFound: OSStatus = -25300
  public let errSecMissingEntitlement: OSStatus = -34018

  /// Generic-password items for the vault where Apple's keychain is missing: the Windows Credential Manager
  /// (encrypted for the user, like the login keychain), and elsewhere a file only the user can read. Items
  /// are never synced; `synchronizable` items are kept apart from this-device ones, as on Apple platforms.
  public struct VaultKeychain: Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "dev.v57.vault", accessGroup: String? = VaultConfiguration.keychainGroup) {
      self.service = service
      self.accessGroup = accessGroup
    }

    public enum KeychainError: LocalizedError, Equatable {
      case status(OSStatus)

      public var errorDescription: String? {
        switch self {
        case .status(let status): "Keychain: error \(status)"
        }
      }
    }

    public struct Options: Sendable {
      public var synchronizable: Bool
      public var label: String?

      public init(synchronizable: Bool, label: String? = nil) {
        self.synchronizable = synchronizable
        self.label = label
      }

      public static let synced = Options(synchronizable: true)
      public static let thisDevice = Options(synchronizable: false)
    }

    /// Every app of the user shares the items.
    public static let isShared = true

    /// The item's name: service, kind and account.
    private func target(_ account: String, _ options: Options) -> String {
      "\(prefix(options))\(account)"
    }

    private func prefix(_ options: Options) -> String {
      "\(service)|\(options.synchronizable ? "synced" : "device")|"
    }

    public func read(_ account: String, options: Options) throws -> Data? {
      try Store.read(target(account, options))
    }

    public func readAll(options: Options) throws -> [(account: String, data: Data)] {
      let prefix = prefix(options)
      return try Store.all(prefix: prefix).map { (String($0.target.dropFirst(prefix.count)), $0.data) }
    }

    public func write(_ data: Data, account: String, options: Options) throws {
      try Store.write(target(account, options), data, label: options.label)
    }

    public func addNew(_ data: Data, account: String, options: Options) throws {
      let target = target(account, options)
      if try Store.read(target) != nil { throw KeychainError.status(errSecDuplicateItem) }
      try Store.write(target, data, label: options.label)
    }

    public func delete(_ account: String, options: Options) throws {
      try Store.delete(target(account, options))
    }
  }

  #if os(Windows)
    /// Generic credentials in the Windows Credential Manager. Failures carry the Windows error code as the status
    /// (the manager needs an interactive logon: over SSH with a key it fails with ERROR_NO_SUCH_LOGON_SESSION).
    private enum Store {
      private static var failure: VaultKeychain.KeychainError { .status(OSStatus(truncatingIfNeeded: GetLastError())) }

      static func read(_ target: String) throws -> Data? {
        var credential: PCREDENTIALW?
        let ok = target.withCString(encodedAs: UTF16.self) { CredReadW($0, DWORD(CRED_TYPE_GENERIC), 0, &credential) }
        guard ok, let credential else {
          if GetLastError() == DWORD(ERROR_NOT_FOUND) { return nil }
          throw failure
        }
        defer { CredFree(credential) }
        return blob(credential.pointee)
      }

      static func all(prefix: String) throws -> [(target: String, data: Data)] {
        var count: DWORD = 0
        var credentials: UnsafeMutablePointer<PCREDENTIALW?>?
        let ok = (prefix + "*").withCString(encodedAs: UTF16.self) { CredEnumerateW($0, 0, &count, &credentials) }
        guard ok, let credentials else {
          if GetLastError() == DWORD(ERROR_NOT_FOUND) { return [] }
          throw failure
        }
        defer { CredFree(credentials) }
        return (0..<Int(count)).compactMap { index in
          guard let credential = credentials[index]?.pointee, let name = credential.TargetName else { return nil }
          return (String(decodingCString: name, as: UTF16.self), blob(credential))
        }
      }

      static func write(_ target: String, _ data: Data, label: String?) throws {
        guard data.count <= Int(CRED_MAX_CREDENTIAL_BLOB_SIZE) else { throw VaultKeychain.KeychainError.status(errSecParam) }
        var bytes = [UInt8](data)
        let ok = target.withCString(encodedAs: UTF16.self) { name in
          (label ?? "").withCString(encodedAs: UTF16.self) { comment in
            "v57".withCString(encodedAs: UTF16.self) { user in
              bytes.withUnsafeMutableBufferPointer { buffer in
                var credential = CREDENTIALW()
                credential.Type = DWORD(CRED_TYPE_GENERIC)
                credential.TargetName = UnsafeMutablePointer(mutating: name)
                credential.Comment = label == nil ? nil : UnsafeMutablePointer(mutating: comment)
                credential.CredentialBlobSize = DWORD(buffer.count)
                credential.CredentialBlob = buffer.baseAddress
                credential.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                credential.UserName = UnsafeMutablePointer(mutating: user)
                return CredWriteW(&credential, 0)
              }
            }
          }
        }
        guard ok else { throw failure }
      }

      static func delete(_ target: String) throws {
        let ok = target.withCString(encodedAs: UTF16.self) { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
        guard ok || GetLastError() == DWORD(ERROR_NOT_FOUND) else { throw failure }
      }

      private static func blob(_ credential: CREDENTIALW) -> Data {
        guard let pointer = credential.CredentialBlob, credential.CredentialBlobSize > 0 else { return Data() }
        return Data(bytes: pointer, count: Int(credential.CredentialBlobSize))
      }
    }
  #else
    /// A JSON file of base64 items in the user's data folder, readable by the user only.
    private enum Store {
      private static let lock = NSLock()
      private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.v57.vault/keychain.json")
      }

      private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
      }

      private static func save(_ items: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }

      static func read(_ target: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return load()[target].flatMap { Data(base64Encoded: $0) }
      }

      static func all(prefix: String) throws -> [(target: String, data: Data)] {
        lock.lock(); defer { lock.unlock() }
        return load().filter { $0.key.hasPrefix(prefix) }.compactMap { key, value in Data(base64Encoded: value).map { (key, $0) } }
      }

      static func write(_ target: String, _ data: Data, label: String?) throws {
        lock.lock(); defer { lock.unlock() }
        var items = load()
        items[target] = data.base64EncodedString()
        try save(items)
      }

      static func delete(_ target: String) throws {
        lock.lock(); defer { lock.unlock() }
        var items = load()
        items[target] = nil
        try save(items)
      }
    }
  #endif
#endif
