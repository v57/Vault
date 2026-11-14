#if os(macOS)
  import Foundation
  import Testing

  @testable import VaultKit

  /// Vault's SSH agent against the real `ssh-add`, `ssh-keygen` and `ssh -G`, with software keys and a socket in /tmp:
  /// never the user's keychain, agent or `~/.ssh`.
  @MainActor
  @Suite(.serialized)
  final class SSHAgentTests {
    let folder: URL
    private var suites: [String] = []

    init() throws {
      VaultSecrets.useInMemoryStore()
      // A Unix socket's path has to stay under 104 bytes: /tmp, not the temporary directory.
      folder = URL(fileURLWithPath: "/tmp/v57-agent-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
      try? FileManager.default.removeItem(at: folder)
      for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    func agent() -> VaultSSHAgent {
      let suite = "dev.v57.vault.agent-test-\(UUID().uuidString)"
      suites.append(suite)
      return VaultSSHAgent(
        keys: SoftwareAgentKeys(), socket: folder.appendingPathComponent("agent.sock"),
        home: folder.appendingPathComponent("home"), defaults: UserDefaults(suiteName: suite)!)
    }

    // MARK: The real tools

    @Test func sshAddListsTheKeyOnlyWhileOn() async throws {
      let agent = agent()
      await agent.turnOn(for: .hour)
      defer { agent.shutdown() }
      let listed = try await run("/usr/bin/ssh-add", ["-L"], socket: agent.socket)
      #expect(listed.status == 0)
      #expect(listed.output.hasPrefix("ecdsa-sha2-nistp256 AAAA"))
      #expect(listed.output.contains("Vault agent key"))
      #expect(listed.output.trimmingCharacters(in: .whitespacesAndNewlines) == agent.publicKeyLine)

      agent.stop()
      let off = try await run("/usr/bin/ssh-add", ["-L"], socket: agent.socket)
      #expect(off.status != 0)
      #expect(agent.requests.first?.result == .whileOff)
      #expect(agent.lastRun?.length == .hour)
    }

    @Test func gitStyleSignaturesVerify() async throws {
      let agent = agent()
      var asked: [VaultSSHAgent.Approval] = []
      agent.approve = { approval in
        asked.append(approval)
        return .allow(.none, remember: false)
      }
      await agent.turnOn(for: .tenMinutes)
      defer { agent.shutdown() }
      let (message, signature) = try await signFile(agent)
      #expect(signature.status == 0, "\(signature.output)")
      #expect(asked.count == 1)
      #expect(asked.first?.purpose == .signature(namespace: "git"))

      // ssh-keygen checks it against the agent's public key, as git does with gpg.format ssh.
      let signers = folder.appendingPathComponent("allowed_signers")
      try "me@example.com \(agent.publicKeyLine!)\n".write(to: signers, atomically: true, encoding: .utf8)
      let verified = try await run(
        "/usr/bin/ssh-keygen", ["-Y", "verify", "-f", signers.path, "-I", "me@example.com", "-n", "git", "-s", message.path + ".sig"],
        socket: agent.socket, input: message)
      #expect(verified.status == 0, "\(verified.output)")
      #expect(agent.requests.first?.result == .signed(asked: true))
    }

    @Test func aDenialFailsTheSignature() async throws {
      let agent = agent()
      agent.approve = { _ in .deny }
      await agent.turnOn(for: .hour)
      defer { agent.shutdown() }
      let (_, signature) = try await signFile(agent)
      #expect(signature.status != 0)
      #expect(agent.requests.first?.result == .denied)
    }

    @Test func onceAsksNothingMoreAndRememberingSkipsThePanel() async throws {
      let agent = agent()
      var panels = 0
      // Run by an AI agent (Claude Code), these tests would ask every time otherwise: that rule has its own test below.
      agent.aiAgentsAlwaysAsk = false
      agent.approve = { _ in
        panels += 1
        return .allow(.none, remember: true)
      }
      await agent.turnOn(for: .hour)
      defer { agent.shutdown() }
      _ = try await signFile(agent)
      _ = try await signFile(agent)
      // The second came from the same app (this test runner), remembered.
      #expect(panels == 1)

      agent.stop()
      agent.confirmation = .once
      await agent.turnOn(for: .hour)
      _ = try await signFile(agent)
      #expect(panels == 1)
    }

    @Test func anAIAgentIsAskedEveryTime() async throws {
      let agent = agent()
      var panels: [VaultSSHAgent.Approval] = []
      agent.approve = { approval in
        panels.append(approval)
        return .allow(.none, remember: true)
      }
      agent.confirmation = .once
      await agent.turnOn(for: .hour)
      defer { agent.shutdown() }
      // Pretend Claude Code started it, whoever runs the tests.
      let claude = SSHAgentCaller(steps: [
        .init(pid: 2, path: "/usr/bin/ssh-keygen", arguments: ["ssh-keygen"]),
        .init(pid: 1, path: "/usr/local/bin/claude", arguments: ["claude"]),
      ])
      agent.setCallerForTesting(claude)
      _ = try await signFile(agent)
      _ = try await signFile(agent)
      #expect(panels.count == 2)
      #expect(panels.first?.aiAgent == "Claude Code")
    }

    @Test func turningOnAgainRestartsTheClock() async throws {
      let agent = agent()
      await agent.turnOn(for: .tenSeconds)
      defer { agent.shutdown() }
      let first = try #require(agent.until)
      await agent.turnOn(for: .hour)
      #expect(try #require(agent.until) > first.addingTimeInterval(3000))
      await agent.turnOn(for: nil)
      #expect(agent.isOn)
      #expect(agent.until == nil)
    }

    @Test func theSocketIsThisUsersOnly() async throws {
      let agent = agent()
      await agent.turnOn(for: .hour)
      defer { agent.shutdown() }
      let mode = try FileManager.default.attributesOfItem(atPath: agent.socket.path)[.posixPermissions] as? Int
      #expect(mode == 0o600)
      agent.shutdown()
      #expect(!FileManager.default.fileExists(atPath: agent.socket.path))
    }

    // MARK: ~/.ssh

    @Test func theConfigGoesFirstAndComesOutWhole() throws {
      let home = folder.appendingPathComponent("home")
      let config = SSHAgentConfig(home: home, socket: folder.appendingPathComponent("agent.sock"))
      try FileManager.default.createDirectory(at: config.sshDirectory, withIntermediateDirectories: true)
      let original = "AddKeysToAgent yes\n\nHost *\n  IdentityAgent \"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\"\n"
      try original.write(to: config.configFile, atomically: true, encoding: .utf8)

      try config.install(hosts: ["github.com", "build.local"])
      let installed = try String(contentsOf: config.configFile, encoding: .utf8)
      #expect(installed == SSHAgentConfig.includeLine + "\n" + original)
      #expect(config.isInstalled)
      #expect(config.otherAgents() == [.init(line: 5, path: "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock", name: "1Password")])
      #expect(try String(contentsOf: config.vaultFile, encoding: .utf8).contains("Match host github.com,build.local exec"))

      try config.install(hosts: ["github.com"])
      #expect(try String(contentsOf: config.configFile, encoding: .utf8) == installed)

      try config.remove()
      #expect(try String(contentsOf: config.configFile, encoding: .utf8) == original)
      #expect(!FileManager.default.fileExists(atPath: config.vaultFile.path))
    }

    @Test func aSymlinkedConfigStaysALink() throws {
      let home = folder.appendingPathComponent("home")
      let config = SSHAgentConfig(home: home, socket: folder.appendingPathComponent("agent.sock"))
      try FileManager.default.createDirectory(at: config.sshDirectory, withIntermediateDirectories: true)
      let real = folder.appendingPathComponent("dotfiles-config")
      try "Host x\n".write(to: real, atomically: true, encoding: .utf8)
      try FileManager.default.createSymbolicLink(at: config.configFile, withDestinationURL: real)
      try config.install(hosts: nil)
      #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: config.configFile.path)) == real.path)
      #expect(try String(contentsOf: real, encoding: .utf8).hasPrefix(SSHAgentConfig.includeLine))
    }

    /// ssh itself reads the file: the agent for the listed hosts while the socket exists, nothing for others or without it.
    @Test func sshReadsTheFile() async throws {
      let socket = folder.appendingPathComponent("agent.sock")
      let config = SSHAgentConfig(home: folder.appendingPathComponent("home"), socket: socket)
      let file = folder.appendingPathComponent("vault.conf")
      try config.contents(hosts: ["github.com"]).write(to: file, atomically: true, encoding: .utf8)

      func agent(for host: String) async throws -> String? {
        let result = try await run("/usr/bin/ssh", ["-G", "-F", file.path, host], socket: nil)
        return result.output.split(separator: "\n").first { $0.hasPrefix("identityagent ") }.map { String($0.dropFirst(14)) }
      }
      #expect(try await agent(for: "github.com") == nil)
      let server = SSHAgentServer(path: socket) { _, _ in SSHAgentProtocol.failureMessage }
      try server.start()
      defer { server.stop() }
      #expect(try await agent(for: "github.com")?.contains("agent.sock") == true)
      #expect(try await agent(for: "example.com") == nil)
    }

    // MARK: Words

    @Test func payloadsSayWhatTheyAreFor() {
      let login = SSHWire.string(Data(repeating: 1, count: 32)) + Data([50]) + SSHWire.string("git") + SSHWire.string("ssh-connection")
        + SSHWire.string("publickey") + Data([1]) + SSHWire.string("ecdsa-sha2-nistp256") + SSHWire.string(Data([1, 2]))
      #expect(SSHAgentProtocol.payload(login) == .login(user: "git"))
      let sshsig = Data("SSHSIG".utf8) + SSHWire.string("git") + SSHWire.string("") + SSHWire.string("sha512") + SSHWire.string(Data([9]))
      #expect(SSHAgentProtocol.payload(sshsig) == .signature(namespace: "git"))
      #expect(SSHAgentProtocol.payload(Data([1, 2, 3])) == .unknown)
    }

    @Test func sshDestinations() {
      #expect(SSHAgentCaller.destination(sshArguments: ["git@github.com", "git-receive-pack 'v57/Vault.git'"]) == "github.com")
      #expect(SSHAgentCaller.destination(sshArguments: ["-p", "2222", "-o", "BatchMode=yes", "me@build.local"]) == "build.local")
      #expect(SSHAgentCaller.destination(sshArguments: ["-vA", "-p2222", "ssh://me@nas.local:22"]) == "nas.local")
      #expect(SSHAgentCaller.destination(sshArguments: ["-v"]) == nil)
    }

    @Test func theChainNamesTheAppAndTheAgent() {
      let claude = SSHAgentCaller(steps: [
        .init(pid: 9, path: "/usr/bin/ssh", arguments: ["ssh", "build.local", "make", "deploy"]),
        .init(pid: 8, path: "/bin/bash", arguments: ["bash", "-c", "ssh build.local make deploy"]),
        .init(pid: 7, path: "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude", arguments: ["claude"]),
        .init(pid: 6, path: "/bin/zsh", arguments: ["-zsh"]),
        .init(pid: 5, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", arguments: ["Terminal"]),
      ])
      #expect(claude.appName == "Terminal")
      #expect(claude.aiAgent == "Claude Code")
      #expect(claude.displayName == "Claude Code")
      #expect(claude.chainLine == "zsh › claude › bash › ssh")
      #expect(claude.sshDestination == "build.local")

      let you = SSHAgentCaller(steps: [
        .init(pid: 3, path: "/usr/bin/ssh", arguments: ["ssh", "git@github.com"]),
        .init(pid: 2, path: "/usr/bin/git", arguments: ["git", "push"]),
        .init(pid: 1, path: "/Applications/Ghostty.app/Contents/MacOS/ghostty", arguments: ["ghostty"]),
      ])
      #expect(you.aiAgent == nil)
      #expect(you.displayName == "Ghostty")
      #expect(you.appKey == "/Applications/Ghostty.app")
    }

    // MARK: Helpers

    /// Signs a small file the way git does (`ssh-keygen -Y sign -n git` with the public key: the agent signs).
    func signFile(_ agent: VaultSSHAgent) async throws -> (URL, (status: Int32, output: String)) {
      let message = folder.appendingPathComponent("message-\(UUID().uuidString.prefix(6)).txt")
      try "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n\nA commit\n".write(to: message, atomically: true, encoding: .utf8)
      let key = folder.appendingPathComponent("agent.pub")
      try (agent.publicKeyLine! + "\n").write(to: key, atomically: true, encoding: .utf8)
      let result = try await run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", key.path, "-n", "git", message.path], socket: agent.socket)
      return (message, result)
    }

    /// Runs a tool off the main actor (the agent answers on it), with `SSH_AUTH_SOCK` set to `socket`.
    nonisolated func run(_ tool: String, _ arguments: [String], socket: URL?, input: URL? = nil) async throws -> (status: Int32, output: String) {
      try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = socket?.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        if let input { process.standardInput = try FileHandle(forReadingFrom: input) }
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
      }.value
    }
  }
#endif
