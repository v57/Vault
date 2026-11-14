import Foundation

/// How `ssh` in a terminal finds the agent: one `Include ~/.ssh/vault.conf` line at the top of `~/.ssh/config`, and the
/// file it names, which Vault writes and keeps up to date (the hosts the agent serves). Turning it off takes both out.
///
/// ssh takes a setting's first value, so the line goes first. The file's `Match` also checks that the socket exists:
/// with Vault quit ssh quietly uses the user's own keys. It ends with `Match all`, so the lines after the Include in the
/// user's config apply as they did.
public struct SSHAgentConfig: Sendable {
  public let home: URL
  public let socket: URL

  public init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), socket: URL) {
    self.home = home
    self.socket = socket
  }

  public static let includeLine = "Include ~/.ssh/vault.conf"

  public var sshDirectory: URL { home.appendingPathComponent(".ssh", isDirectory: true) }
  public var configFile: URL { sshDirectory.appendingPathComponent("config") }
  public var vaultFile: URL { sshDirectory.appendingPathComponent("vault.conf") }

  /// Whether `~/.ssh/config` includes Vault's file.
  public var isInstalled: Bool { lines(of: configFile).contains { Self.isInclude($0) } }

  /// The file's text for these hosts (nil: every host).
  public func contents(hosts: [String]?) -> String {
    let path = socket.path
    let match: String
    if let hosts {
      // No host yet: a pattern that matches nothing, so ssh never reaches the agent.
      let list = hosts.isEmpty ? "!*" : hosts.joined(separator: ",")
      match = "Match host \(list) exec \"test -S '\(path)'\""
    } else {
      match = "Match exec \"test -S '\(path)'\""
    }
    return """
      # Written by Vault (Settings ▸ SSH Agent). It's replaced when the agent's hosts change; turning off
      # "Use from Terminal" removes it and the Include line in ~/.ssh/config.
      \(match)
        IdentityAgent "\(path)"
      Match all

      """
  }

  /// Writes the file and puts the Include line first in `~/.ssh/config` (made if missing).
  public func install(hosts: [String]?) throws {
    try ensureDirectory()
    try write(contents(hosts: hosts), to: vaultFile)
    var lines = lines(of: configFile)
    guard !lines.contains(where: { Self.isInclude($0) }) else { return }
    lines.insert(Self.includeLine, at: 0)
    try write(lines.joined(separator: "\n"), to: configFile, keepEnding: true)
  }

  /// Rewrites the file for new hosts, only while installed.
  public func update(hosts: [String]?) throws {
    guard isInstalled else { return }
    let text = contents(hosts: hosts)
    if (try? String(contentsOf: vaultFile, encoding: .utf8)) == text { return }
    try write(text, to: vaultFile)
  }

  /// Takes the Include line out of `~/.ssh/config` and removes the file.
  public func remove() throws {
    var lines = lines(of: configFile)
    if lines.contains(where: { Self.isInclude($0) }) {
      lines.removeAll { Self.isInclude($0) }
      try write(lines.joined(separator: "\n"), to: configFile, keepEnding: true)
    }
    try? FileManager.default.removeItem(at: vaultFile)
  }

  /// Another agent `~/.ssh/config` names (1Password, Secretive…), with its 1-based line.
  public struct OtherAgent: Equatable, Sendable {
    public var line: Int
    public var path: String
    public var name: String
  }

  public func otherAgents() -> [OtherAgent] {
    lines(of: configFile).enumerated().compactMap { index, line in
      let words = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
      guard words.count == 2, words[0].lowercased() == "identityagent" else { return nil }
      let path = words[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
      guard path.lowercased() != "none", path != socket.path else { return nil }
      return OtherAgent(line: index + 1, path: path, name: Self.agentName(path))
    }
  }

  static func agentName(_ path: String) -> String {
    let lower = path.lowercased()
    if lower.contains("1password") || lower.contains("2bua8c4s2c") { return "1Password" }
    if lower.contains("secretive") { return "Secretive" }
    if lower.contains("ssh_auth_sock") { return "SSH_AUTH_SOCK" }
    if lower.contains("gpg") { return "GnuPG" }
    return (path as NSString).lastPathComponent
  }

  static func isInclude(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces) == includeLine
  }

  private func lines(of file: URL) -> [String] {
    guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return [] }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  private func ensureDirectory() throws {
    if !FileManager.default.fileExists(atPath: sshDirectory.path) {
      try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }

  /// Writes through a temporary file, user-only. `keepEnding`: the text is lines joined; end it with a newline.
  private func write(_ text: String, to link: URL, keepEnding: Bool = false) throws {
    // A config kept in a dotfiles repo is often a symlink: write where it points, keeping the link.
    let file = link.resolvingSymlinksInPath()
    var text = text
    if keepEnding, !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
    let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0o600
    try Data(text.utf8).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
  }
}
