import Foundation

#if os(macOS)
  import Darwin
#endif

/// Who asked the agent: the process that connected and its parents, up to the app the user sees (Terminal, Code, an
/// AI agent's app). The request panel and the Requests list show it as `Terminal › zsh › git push › ssh`.
public struct SSHAgentCaller: Hashable, Sendable {
  public struct Step: Hashable, Sendable {
    public var pid: Int32
    /// The executable's path.
    public var path: String
    public var arguments: [String]

    public init(pid: Int32, path: String, arguments: [String]) {
      self.pid = pid
      self.path = path
      self.arguments = arguments
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The command as typed, shortened: `git push origin main`, `ssh git@github.com …`.
    public var command: String {
      let words = [name] + arguments.dropFirst().prefix(5).map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 }
      return words.joined(separator: " ") + (arguments.count > 6 ? " …" : "")
    }

    /// The app bundle this executable is in (`/Applications/Utilities/Terminal.app`), nil for a plain command.
    public var appPath: String? {
      guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
      return String(path[..<range.lowerBound]) + ".app"
    }
  }

  /// From the process that connected up to (not including) launchd.
  public var steps: [Step]

  public init(steps: [Step]) { self.steps = steps }

  /// The outermost app in the chain: the one the user sees (Terminal, Ghostty, Code). Nil for a process launchd started.
  public var app: Step? { steps.last { $0.appPath != nil } }

  public var appName: String {
    guard let app, let path = app.appPath else { return steps.first?.name ?? "?" }
    return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
  }

  /// The app's bundle path, the key "don't ask again for this app" remembers.
  public var appKey: String { app?.appPath ?? steps.last?.path ?? "" }

  /// The AI agent in the chain (Claude Code, Codex…), if one started this. Its requests always ask.
  public var aiAgent: String? {
    for step in steps {
      let names = [step.name] + step.arguments.dropFirst().prefix(1).map { ($0 as NSString).lastPathComponent }
      for name in names {
        if let agent = Self.aiAgents[name.lowercased()] { return agent }
      }
    }
    return nil
  }

  /// What the user sees as the asker: the AI agent when one is in the chain, else the app.
  public var displayName: String { aiAgent ?? appName }

  /// The steps from the app down to the process that asked, as the panel lists them (shells and commands, no system
  /// processes above the app).
  public var shownSteps: [Step] {
    guard let index = steps.lastIndex(where: { $0.appPath != nil }) else { return steps.reversed() }
    return steps[...index].reversed()
  }

  /// `zsh › git push › ssh`: the commands under the app, for one line.
  public var chainLine: String {
    shownSteps.dropFirst().map(\.name).joined(separator: " › ")
  }

  /// The server an `ssh` in the chain was asked to reach (`git@github.com` → `github.com`), from its arguments.
  public var sshDestination: String? {
    guard let ssh = steps.first(where: { $0.name == "ssh" }) else { return nil }
    return Self.destination(sshArguments: Array(ssh.arguments.dropFirst()))
  }

  /// ssh's options that take a value; the first other word is the destination.
  static let valued: Set<Character> = ["B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o", "P", "p", "Q", "R", "S", "W", "w"]

  static func destination(sshArguments: [String]) -> String? {
    var index = 0
    while index < sshArguments.count {
      let word = sshArguments[index]
      if word == "--" { index += 1; break }
      guard word.hasPrefix("-"), word.count > 1 else { break }
      // `-p22`: the value is in the same word. `-p 22` or `-vp 22`: the next one.
      if let last = word.last, valued.contains(last) { index += 1 }
      index += 1
    }
    guard index < sshArguments.count else { return nil }
    var host = sshArguments[index]
    if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
    if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
    if let colon = host.firstIndex(of: ":"), !host.contains("[") { host = String(host[..<colon]) }
    return host.isEmpty ? nil : host
  }

  /// Executable names of AI coding agents, and what to call them.
  static let aiAgents: [String: String] = [
    "claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "cursor-agent": "Cursor Agent",
    "aider": "Aider", "opencode": "opencode", "goose": "Goose", "amp": "Amp", "copilot": "GitHub Copilot",
    "crush": "Crush", "qwen": "Qwen Code",
  ]

  #if os(macOS)
    /// The chain of the process with this pid, read from the kernel. A process that's gone already reads as empty.
    public static func of(pid: pid_t) -> SSHAgentCaller {
      var steps: [Step] = []
      var current = pid
      while current > 1, steps.count < 32 {
        guard let parent = parentPID(current) else { break }
        steps.append(Step(pid: current, path: executablePath(current) ?? "pid \(current)", arguments: arguments(current)))
        current = parent
      }
      return SSHAgentCaller(steps: steps)
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
      return info.kp_eproc.e_ppid
    }

    static func executablePath(_ pid: pid_t) -> String? {
      var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
      let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
      guard length > 0 else { return nil }
      return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// argv, from KERN_PROCARGS2: argc, the executable path, padding, then argc strings (the environment follows,
    /// never read).
    static func arguments(_ pid: pid_t) -> [String] {
      var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
      var size = 0
      guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
      var buffer = [UInt8](repeating: 0, count: size)
      guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
      let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
      var index = 4
      while index < size, buffer[index] != 0 { index += 1 }
      while index < size, buffer[index] == 0 { index += 1 }
      var arguments: [String] = []
      while arguments.count < argc, index < size {
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
        index += 1
      }
      return arguments
    }
  #endif
}
