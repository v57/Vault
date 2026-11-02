import Foundation

extension VaultProject {
  /// How a project's repository was on one device when Git there last looked: its branch, its counts and its
  /// uncommitted files (the first `fileLimit`), so the user's other devices show it before they reach the device, and
  /// still show it when they can't.
  public struct Status: Codable, Sendable, Hashable {
    public var branch: String?
    public var changeCount: Int
    public var ahead: Int
    public var behind: Int
    public var hasUpstream: Bool
    public var conflictCount: Int
    /// The operation git is in the middle of there ("merge", "rebase", …).
    public var operation: String?
    public var files: [File]
    /// HEAD's commit date there.
    public var lastCommit: Date?
    /// When the branch was last pushed from there.
    public var lastPush: Date?

    /// One uncommitted file.
    public struct File: Codable, Sendable, Hashable {
      public var path: String
      /// Git's letter for the change ("M", "A", "D", "R", "?", "U", …).
      public var kind: String
      /// "staged", "unstaged" or "conflicted".
      public var area: String

      public init(path: String, kind: String, area: String) {
        self.path = path
        self.kind = kind
        self.area = area
      }
    }

    /// How many files a status keeps: enough for a glance, small enough to sync with every change.
    public static let fileLimit = 100

    public init(
      branch: String?, changeCount: Int, ahead: Int = 0, behind: Int = 0, hasUpstream: Bool = false,
      conflictCount: Int = 0, operation: String? = nil, files: [File] = [], lastCommit: Date? = nil,
      lastPush: Date? = nil
    ) {
      self.branch = branch
      self.changeCount = changeCount
      self.ahead = ahead
      self.behind = behind
      self.hasUpstream = hasUpstream
      self.conflictCount = conflictCount
      self.operation = operation
      self.files = Array(files.prefix(Self.fileLimit))
      self.lastCommit = lastCommit
      self.lastPush = lastPush
    }

    /// Anything to commit, push, pull or finish there.
    public var needsAttention: Bool { changeCount > 0 || ahead > 0 || behind > 0 || conflictCount > 0 || operation != nil }

    init?(json: String) {
      guard let status = try? JSONDecoder().decode(Status.self, from: Data(json.utf8)) else { return nil }
      self = status
    }

    var json: String? {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }
  }
}

extension Vault {
  /// Keeps how the repository at `path` on this device is (`VaultProject.Status`) in its project, for the user's
  /// other devices. Writes only when it changed, so calling it after every refresh syncs only real changes. Nothing
  /// for a folder that isn't one of the vault's projects.
  public func setStatus(_ status: VaultProject.Status, ofProjectAt path: String) {
    guard var project = project(atPath: path), project.statuses[deviceID] != status else { return }
    project.statuses[deviceID] = status
    save(project)
  }

  /// Every address that reaches a host's machine, in the order to try them: its hostname and the fallbacks the user
  /// added, then, for one of the user's own devices, its other ways there: the name the Mac published (its Bonjour
  /// name, on the same network) and its Hub Network address. Any of them can be out of reach (another network, the
  /// Hub off), which is why there are several. The Macs that published themselves are Personal's; the Hub hosts are
  /// this vault's and Personal's.
  public func addresses(of host: VaultHost) -> [String] {
    let personal = personalVault
    var addresses = [host.hostname] + host.fallbacks
    func deviceID(of host: VaultHost) -> String? { vaultDevice(of: host) ?? personal.vaultDevice(of: host) }
    if let device = deviceID(of: host) {
      for other in personal.deviceHosts where other.device?.deviceID == device {
        addresses += [other.hostname] + other.fallbacks + [other.device?.address ?? ""]
      }
      for other in hubHosts + (isPersonal ? [] : personal.hubHosts) where deviceID(of: other) == device {
        addresses += [other.hostname] + other.fallbacks
      }
    }
    var seen = Set<String>()
    return addresses.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// `addresses(of:)` after the host's own hostname: what to pass as `SSHServer.fallbackHosts`.
  public func fallbackAddresses(of host: VaultHost) -> [String] {
    addresses(of: host).filter { $0 != host.hostname }
  }
}
