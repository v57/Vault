import Foundation

/// Who the user is in an account: the name and email on their commits, in the comment of their keys'
/// `authorized_keys` lines and on their Hub. One per account, kept in Personal like the accounts themselves (id
/// `profile.<account id>`: a store's ids are unique across kinds, and the account's record has its id), so an app
/// knows every account's without opening its store. Empty fields
/// haven't been asked yet (`Vaults.profile(for:)` and `suggestedProfile(for:gitHub:)`).
///
/// Apps hand it to the tools they run (git's `GIT_AUTHOR_*` environment), never to the user's files: the terminal and
/// agents keep their own setup.
public struct VaultProfile: VaultRecord, Hashable {
  public static let kind = "profile"

  /// `profile.<account id>`.
  public var id: String
  public var name: String
  public var email: String

  public init(account: String, name: String = "", email: String = "") {
    id = Self.id(forAccount: account)
    self.name = name
    self.email = email
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    name = read.string("name", default: "")
    email = read.string("email", default: "")
  }

  public var values: [String: JSONValue] {
    ["name": name.isEmpty ? .null : .string(name), "email": email.isEmpty ? .null : .string(email)]
  }

  /// The record's id for an account.
  public static func id(forAccount account: String) -> String { "profile.\(account)" }

  /// The account's id.
  public var account: String { id.hasPrefix("profile.") ? String(id.dropFirst("profile.".count)) : id }

  /// Whether both the name and the email are set.
  public var isComplete: Bool { !name.isEmpty && !email.isEmpty }

  /// `Name <email>`, as git and OpenSSH key comments write a person; nil until both are set.
  public var signature: String? { isComplete ? "\(name) <\(email)>" : nil }

  /// git's author and committer for its commits (`GIT_AUTHOR_NAME`, `GIT_COMMITTER_EMAIL`, …), empty until both are
  /// set. A repository's own `user.name` and `user.email` should win: pass it only to repositories without them.
  public var gitEnvironment: [String: String] {
    guard isComplete else { return [:] }
    return [
      "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email,
    ]
  }

  /// The comment of a device's key line in `authorized_keys`: `Name <email> (Device)`, so a server's admin sees whose
  /// key it is; the name alone, then the device alone, while the profile is incomplete.
  public func keyComment(device: String) -> String {
    let device = device.trimmingCharacters(in: .whitespacesAndNewlines)
    let person = signature ?? (name.isEmpty ? nil : name)
    guard let person else { return device }
    return device.isEmpty ? person : "\(person) (\(device))"
  }

  /// The name and email trimmed of surrounding spaces and newlines, as the sheet saves them.
  public var trimmed: VaultProfile {
    VaultProfile(
      account: account, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      email: email.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// `user.name` and `user.email` from git's global configuration (`$XDG_CONFIG_HOME/git/config`, then `~/.gitconfig`,
/// which wins, as git reads them), read from the files: no git process runs.
public struct GitGlobalIdentity: Sendable, Hashable {
  public var name: String?
  public var email: String?

  public init(name: String? = nil, email: String? = nil) {
    self.name = name
    self.email = email
  }

  /// The user's, from `home` (the home folder; a sandboxed app sees its container's, which has none).
  public static func read(
    home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> GitGlobalIdentity {
    let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(".config")
    var identity = GitGlobalIdentity()
    for file in [xdg.appendingPathComponent("git/config"), home.appendingPathComponent(".gitconfig")] {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      let read = parse(text)
      identity.name = read.name ?? identity.name
      identity.email = read.email ?? identity.email
    }
    return identity
  }

  /// The `[user]` section's `name` and `email` in one git config file. Section and key names are case-insensitive,
  /// `#` and `;` start comments outside quotes, and a later value wins. Includes aren't followed.
  static func parse(_ text: String) -> GitGlobalIdentity {
    var identity = GitGlobalIdentity()
    var inUser = false
    for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        // `[user]`, not `[user "x"]` (git has no such subsections) or `[userx]`.
        let header = line.dropFirst().prefix { $0 != "]" }.trimmingCharacters(in: .whitespaces)
        inUser = header.lowercased() == "user"
        continue
      }
      guard inUser, let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
      guard key == "name" || key == "email" else { continue }
      let value = Self.value(line[line.index(after: equals)...])
      guard !value.isEmpty else { continue }
      if key == "name" { identity.name = value } else { identity.email = value }
    }
    return identity
  }

  /// A value with its quotes removed, `\"` and `\\` unescaped and a trailing comment dropped.
  private static func value(_ text: Substring) -> String {
    var result = ""
    var quoted = false
    var escaped = false
    for character in text {
      if escaped {
        result.append(character == "t" ? "\t" : character == "n" ? "\n" : character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        quoted.toggle()
      } else if !quoted, character == "#" || character == ";" {
        break
      } else {
        result.append(character)
      }
    }
    return result.trimmingCharacters(in: .whitespaces)
  }
}

extension Vaults {
  /// The account's name and email. An organization's account without a name of its own takes Personal's; its email
  /// it doesn't, as an organization's commits go out with its own address. Fields stay empty until asked.
  public func profile(for account: VaultAccount) -> VaultProfile {
    let own = personal.profiles.first { $0.account == account.id } ?? VaultProfile(account: account.id)
    guard !account.isPersonal, own.name.isEmpty else { return own }
    var profile = own
    profile.name = personal.profiles.first { $0.account == VaultAccount.personal.id }?.name ?? ""
    return profile
  }

  /// Saves an account's name and email (trimmed), in Personal like the account.
  public func save(_ profile: VaultProfile) {
    personal.save(profile.trimmed)
  }

  /// What the Your Name sheet starts with: what the account has, then, for each empty field, Personal's (for an
  /// organization's account), git's global configuration, the GitHub sign-in's name and email (`gitHub`, which the
  /// caller passes only when the user is already signed in: nothing is fetched for this) and, for the name, the Mac
  /// user's full name.
  public func suggestedProfile(
    for account: VaultAccount, gitHub: (name: String?, email: String?)? = nil,
    git: GitGlobalIdentity = .read()
  ) -> VaultProfile {
    var profile = profile(for: account)
    let personalProfile = account.isPersonal ? nil : self.profile(for: .personal)
    let names = [personalProfile?.name, git.name, gitHub?.name, Self.systemFullName]
    let emails = [personalProfile?.email, git.email, gitHub?.email]
    func first(_ candidates: [String?]) -> String {
      candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
    }
    if profile.name.isEmpty { profile.name = first(names) }
    if profile.email.isEmpty { profile.email = first(emails) }
    return profile
  }

  /// The signed-in user's full name on the Mac and Linux; nil elsewhere (iOS has only "Mobile User").
  static var systemFullName: String? {
    #if os(macOS) || os(Linux)
      let name = NSFullUserName()
      return name.isEmpty ? nil : name
    #else
      return nil
    #endif
  }
}
