#if os(macOS)
  import Foundation

  extension VaultThisMac {
    /// Whether sshd here lets someone sign in with this Mac's password (password, or keyboard-interactive through
    /// PAM), as its config files say: the first value of a setting wins, as in sshd, and `Match` blocks are left out.
    public static func passwordLoginIsOn(directory: URL = URL(fileURLWithPath: "/etc/ssh")) -> Bool {
      var values: [String: String] = [:]
      SSHDConfig.read(directory.appendingPathComponent("sshd_config"), directory: directory, into: &values)
      let password = values["passwordauthentication"] ?? "yes"
      let keyboard = values["kbdinteractiveauthentication"] ?? values["challengeresponseauthentication"] ?? "yes"
      return password != "no" || (keyboard != "no" && values["usepam"] == "yes")
    }

    /// The file the v57 apps write to turn password login off. Its name sorts before macOS's own `100-macos.conf`,
    /// and sshd keeps a setting's first value.
    public static let keysOnlyFile = "/etc/ssh/sshd_config.d/050-v57-keys-only.conf"

    /// Turns password login off (keys only: `keysOnlyFile`) or back on (the file goes), after macOS asks for an
    /// administrator's password. sshd reads its config for every new connection, so it holds from the next sign-in.
    /// Throws `CancellationError` when the user cancels the prompt.
    public static func setPasswordLogin(_ isOn: Bool) async throws {
      let file = keysOnlyFile
      let command =
        isOn
        ? "rm -f '\(file)'"
        : "printf '%s\\n' '# Written by the v57 apps (Settings > Remote): sign in with keys only.' "
          + "'PasswordAuthentication no' 'KbdInteractiveAuthentication no' > '\(file)' && chmod 644 '\(file)'"
      let prompt =
        isOn
        ? "Allow signing in to this Mac over SSH with its password again."
        : "Turn off signing in to this Mac over SSH with its password: only keys, like your devices', get in."
      let script =
        "do shell script \"\(appleScriptEscaped(command))\" with prompt \"\(appleScriptEscaped(prompt))\" "
        + "with administrator privileges"
      try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
          // -128: the user cancelled the password prompt.
          if message.contains("-128") { throw CancellationError() }
          throw SSHDConfigError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      }.value
    }

    private static func appleScriptEscaped(_ text: String) -> String {
      text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    public enum SSHDConfigError: LocalizedError {
      case failed(String)

      public var errorDescription: String? {
        switch self {
        case .failed(let message): "The SSH settings couldn’t be changed: \(message)"
        }
      }
    }
  }

  /// Reads sshd's config files as sshd does, for the settings the v57 apps look at.
  enum SSHDConfig {
    /// Adds each setting's first value (keys lowercased), following `Include`s; a `Match` block ends what is read
    /// from its file.
    static func read(_ file: URL, directory: URL, into values: inout [String: String], depth: Int = 0) {
      guard depth < 8, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
      for line in text.split(whereSeparator: \.isNewline) {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
        guard let key = words.first?.lowercased() else { continue }
        if key == "match" { return }
        if key == "include" {
          for pattern in words.dropFirst() {
            for included in files(matching: pattern, directory: directory) {
              read(included, directory: directory, into: &values, depth: depth + 1)
            }
          }
          continue
        }
        if values[key] == nil, words.count > 1 { values[key] = words[1].lowercased() }
      }
    }

    /// The files an `Include` names, in order: a path relative to `directory`, a `*` or `?` in its last part.
    static func files(matching pattern: String, directory: URL) -> [URL] {
      let url = pattern.hasPrefix("/") ? URL(fileURLWithPath: pattern) : directory.appendingPathComponent(pattern)
      let name = url.lastPathComponent
      guard name.contains("*") || name.contains("?") else { return [url] }
      let folder = url.deletingLastPathComponent()
      let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
      return names.filter { fnmatch(name, $0, 0) == 0 }.sorted().map { folder.appendingPathComponent($0) }
    }
  }
#endif
