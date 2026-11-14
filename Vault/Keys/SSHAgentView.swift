#if os(macOS)
  import ComponentKit
  import SwiftUI
  import VaultKit
  import VaultUI

  /// Words the agent's screens share.
  enum SSHAgentText {
    /// "42 min left", "8 s left", "5 h 12 min left".
    static func left(until: Date, now: Date = .now) -> String {
      let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
      if seconds < 60 { return String(localized: "\(seconds) s left") }
      let minutes = (seconds + 59) / 60
      if minutes < 60 { return String(localized: "\(minutes) min left") }
      return String(localized: "\(minutes / 60) h \(minutes % 60) min left")
    }

    /// "42:10", "5:12:40": the big countdown.
    static func clock(until: Date, now: Date = .now) -> String {
      let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
      let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
      return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "8 s", "42 min", "5 h": the sidebar row's chip.
    static func short(until: Date, now: Date = .now) -> String {
      let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
      if seconds < 60 { return String(localized: "\(seconds) s") }
      if seconds < 3600 { return String(localized: "\((seconds + 59) / 60) min") }
      return String(localized: "\((seconds + 3599) / 3600) h")
    }

    static func length(_ length: VaultSSHAgent.Length?) -> String {
      length.map(VaultSSHAgent.lengthText) ?? String(localized: "Until turned off")
    }

    /// "10 sec", "10 min", "1 hour"… for the length buttons.
    static func lengthShort(_ length: VaultSSHAgent.Length?) -> String {
      switch length {
      case .tenSeconds: String(localized: "10 sec")
      case .tenMinutes: String(localized: "10 min")
      case .hour: String(localized: "1 hour")
      case .eightHours: String(localized: "8 hours")
      case .day: String(localized: "24 hours")
      case nil: String(localized: "Until turned off")
      }
    }

    static func key(_ choice: SSHAgentKeyChoice) -> String {
      choice == .agent ? String(localized: "Agent key") : String(localized: "This Mac’s key")
    }

    static let lengths: [VaultSSHAgent.Length?] = [.tenSeconds, .tenMinutes, .hour, .eightHours, .day, nil]
  }

  /// The SSH Agent row's trailing: Off, the time left, or On.
  struct SSHAgentTrail: View {
    @State private var agent = VaultSSHAgent.shared

    var body: some View {
      if let until = agent.until {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Chip(SSHAgentText.short(until: until, now: context.date), hue: .orange).controlSize(.small)
        }
      } else if agent.isOn {
        Chip("On", hue: .orange).controlSize(.small)
      } else {
        Text("Off").kitFont(.caption)
      }
    }
  }

  /// Board "SSH Agent: on for 1 hour": the state and its lengths, Terminal's setup, what asked; the key, asking and
  /// hosts beside them.
  struct SSHAgentView: View {
    @State private var agent = VaultSSHAgent.shared
    @Environment(AppModel.self) private var app
    @State private var error: String?
    @State private var newHost = ""

    var body: some View {
      ScrollView {
        HStack(alignment: .top, spacing: 24) {
          VStack(alignment: .leading, spacing: 18) {
            StatusCard(agent: agent)
            terminalCard
            requestsCard
          }
          .frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 18) {
            keyCard
            hostsCard
            askingCard
            FormCard {
              FormRow(
                "Runs inside Vault", help: "No helper or login item. Quitting Vault stops the agent and removes its socket.",
                systemImage: "macwindow", hue: .gray
              ) {}
            }
          }
          .frame(width: 360)
        }
        .padding(24)
      }
      .frame(maxWidth: .infinity)
      .kitPane(.content)
      .kitToolbar("SSH Agent", title: {
        KitTitle("SSH Agent", meta: titleMeta, systemImage: "key.horizontal", hue: agent.isOn ? .orange : .gray, status: titleStatus)
      }) {
      }
    }

    private var titleMeta: [String] {
      guard agent.isOn else { return [String(localized: "Off"), String(localized: "only v57 apps use your keys")] }
      return [
        String(localized: "On"), SSHAgentText.key(agent.keyChoice),
        agent.until.map { String(localized: "stops at \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "until turned off"),
      ]
    }

    private var titleStatus: WorkStatus { agent.fractionLeft.map { .working(progress: $0) } ?? .idle }

    // MARK: Terminal

    private var terminalCard: some View {
      VStack(alignment: .leading, spacing: 6) {
        Text("Use from Terminal").kitFont(.headline).padding(.leading, 4)
        FormCard {
          FormRow(
            "ssh and git in Terminal",
            help: "Vault keeps the agent’s hosts in ~/.ssh/vault.conf. Turning this off removes the file and its Include line.",
            systemImage: "terminal", hue: .gray
          ) {
            Toggle("ssh and git in Terminal", isOn: Binding(get: { agent.usesTerminal }, set: { on in
              do { try agent.setUseFromTerminal(on) } catch { self.error = error.localizedDescription }
            }))
            .labelsHidden().toggleStyle(.kitSwitch)
          }
          if agent.usesTerminal {
            VStack(alignment: .leading, spacing: 8) {
              KitCodeBlock(agent.config.contents(hosts: agent.servesEveryHost ? nil : agent.hosts), wraps: true)
              HStack(spacing: 8) {
                Circle().fill(Hue.green.fill).frame(width: 6, height: 6)
                Text("Line 1 of ~/.ssh/config: \(SSHAgentConfig.includeLine)").kitFont(.caption).foregroundStyle(.kitSecondary)
                Spacer()
                Button("Show in Finder") { KitDesktop.reveal([agent.config.vaultFile]) }.buttonStyle(.kitPlain).controlSize(.small)
              }
            }
            .padding(12)
          }
          ForEach(agent.config.otherAgents(), id: \.line) { other in
            FormRow(
              "\(other.name)’s agent is also set",
              help: String(localized: "Line \(other.line) of ~/.ssh/config. Vault’s Include comes first, so its hosts use Vault and the rest use \(other.name)."),
              systemImage: "exclamationmark.triangle", hue: .orange
            ) {}
          }
        }
        if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
        if let socket = agent.socketError { Text(socket).kitFont(.caption).foregroundStyle(Hue.red.text) }
      }
    }

    // MARK: Requests

    private var requestsCard: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Requests").kitFont(.headline)
          Spacer()
          Text("Since Vault opened · \(agent.requests.count)").kitFont(.caption).foregroundStyle(.kitSecondary)
        }
        .padding(.horizontal, 4)
        FormCard {
          if agent.requests.isEmpty {
            Text("Nothing asked yet. ssh, git and ssh-add show here when they use the agent.")
              .kitFont(.caption).foregroundStyle(.kitSecondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
          }
          ForEach(agent.requests.prefix(50)) { request in
            RequestRow(request: request)
          }
        }
      }
    }

    // MARK: Key

    private var keyCard: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("Key").kitFont(.headline).padding(.leading, 4)
        keyChoice(.agent, "Agent key", subtitle: "A second Secure Enclave key, made for the agent only. Add it to the servers ssh should reach. Turning the agent off never locks Shell or Git out.")
        keyChoice(.device, "This Mac’s key", subtitle: "The one Shell, Git and Database use. Every server that trusts it is open to what the agent lets in.")
        if let blob = agent.publicKeyBlob {
          Text(VaultIdentity.fingerprint(blob: blob)).kitFont(.monoSmall).foregroundStyle(.kitSecondary).padding(.leading, 4).textSelection(.enabled)
        }
        HStack(spacing: 8) {
          if let line = agent.publicKeyLine {
            KitCopyButton("Copy Public Key", value: line).buttonStyle(.kit)
          }
        }
        .controlSize(.small)
      }
    }

    private func keyChoice(_ choice: SSHAgentKeyChoice, _ title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
      ChoiceCard(isOn: Binding(get: { agent.keyChoice == choice }, set: { if $0 { agent.keyChoice = choice } })) {
        ChoiceCardLabel(title, subtitle: subtitle) {
          Tile(systemImage: choice == .agent ? "key.horizontal" : "laptopcomputer", hue: choice == .agent ? .orange : .blue, size: 28)
        }
      }
    }

    // MARK: Hosts

    private var hostsCard: some View {
      VStack(alignment: .leading, spacing: 6) {
        Text("Hosts").kitFont(.headline).padding(.leading, 4)
        FormCard {
          FormRow("Every host", help: "Off: only the hosts below use the agent; the rest keep your own keys.", systemImage: "globe", hue: .indigo) {
            Toggle("Every host", isOn: $agent.servesEveryHost).labelsHidden().toggleStyle(.kitSwitch)
          }
          if !agent.servesEveryHost {
            ForEach(agent.hosts, id: \.self) { host in
              FormRow(host, systemImage: "server.rack", hue: .indigo) {
                Button("Remove", systemImage: "minus.circle") { agent.hosts.removeAll { $0 == host } }
                  .buttonStyle(.kitIcon).labelStyle(.iconOnly)
              }
            }
            HStack(spacing: 8) {
              TextField("github.com", text: $newHost).textFieldStyle(.plain).kitFont(.mono).onSubmit(addHost)
              Button("Add", action: addHost).buttonStyle(.kit).controlSize(.small).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            let suggestions = suggestedHosts
            if !suggestions.isEmpty {
              KitFlowLayout(spacing: 6) {
                ForEach(suggestions, id: \.self) { host in
                  Button { agent.hosts.append(host) } label: { Label(host, systemImage: "plus").lineLimit(1) }
                    .buttonStyle(.kit).controlSize(.small)
                }
              }
              .padding(.horizontal, 12).padding(.bottom, 8)
            }
          }
        }
      }
    }

    private func addHost() {
      let host = newHost.trimmingCharacters(in: .whitespaces)
      guard !host.isEmpty, !agent.hosts.contains(host) else { return }
      agent.hosts.append(host)
      newHost = ""
    }

    /// GitHub and GitLab, then the vault's SSH hosts, minus those listed.
    private var suggestedHosts: [String] {
      var names = ["github.com", "gitlab.com"] + app.vault.hosts.map(\.hostname)
      names = names.filter { !$0.isEmpty && !agent.hosts.contains($0) }
      var seen: Set<String> = []
      return names.filter { seen.insert($0).inserted }.prefix(6).map { $0 }
    }

    // MARK: Asking

    private var askingCard: some View {
      VStack(alignment: .leading, spacing: 6) {
        Text("Asking").kitFont(.headline).padding(.leading, 4)
        FormCard {
          FormRow("Touch ID", help: "AI agents always ask.", systemImage: "touchid", hue: .red) {
            Picker("Touch ID", selection: $agent.confirmation) {
              Text("Each time").tag(VaultSSHAgent.Confirmation.eachSignature)
              Text("Once per turn-on").tag(VaultSSHAgent.Confirmation.once)
            }
            .labelsHidden().fixedSize()
          }
        }
      }
    }
  }

  /// The big state card: the ring and countdown, then the lengths (restart while on) and Stop.
  private struct StatusCard: View {
    let agent: VaultSSHAgent

    var body: some View {
      FormCard {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          HStack(spacing: 16) {
            LiveIcon(
              systemImage: "key.horizontal", hue: agent.isOn ? .orange : .gray,
              status: agent.isOn ? .working(progress: agent.fractionLeft ?? 1) : .idle, size: 44)
            VStack(alignment: .leading, spacing: 2) {
              Text(title).kitFont(.title3)
              Text(subtitle).kitFont(.caption).foregroundStyle(.kitSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
              if let until = agent.until {
                Text(SSHAgentText.clock(until: until, now: context.date)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                  .foregroundStyle(Hue.orange.text)
                Text("left").kitFont(.caption).foregroundStyle(.kitSecondary)
              } else if agent.isOn {
                Text("On").font(.system(size: 22, weight: .semibold)).foregroundStyle(Hue.orange.text)
              }
            }
          }
          .padding(16)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text(agent.isOn ? "Restart for" : "Turn on for").kitFont(.caption).foregroundStyle(.kitSecondary)
          HStack(spacing: 6) {
            ForEach(SSHAgentText.lengths, id: \.self) { length in
              let current = agent.isOn && currentLength == length
              Button(SSHAgentText.lengthShort(length)) {
                Task { await SSHAgentPanels.turnOn(agent, for: length) }
              }
              .buttonStyle(current ? .kitPrimary : .kit)
              .controlSize(.small)
            }
            Spacer(minLength: 8)
            if agent.isOn {
              Button("Stop Now", systemImage: "stop", role: .destructive) { agent.stop() }.buttonStyle(.kit).controlSize(.small)
            }
          }
          if let error = agent.turnOnError { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
      }
    }

    private var currentLength: VaultSSHAgent.Length? {
      if case .on(_, _, let length) = agent.state { return length }
      return nil
    }

    private var title: String {
      guard agent.isOn else {
        if let run = agent.lastRun { return String(localized: "Stopped at \(run.ended.formatted(date: .omitted, time: .shortened))") }
        return String(localized: "Off")
      }
      guard let length = currentLength else { return String(localized: "On until you turn it off") }
      return String(localized: "On for \(VaultSSHAgent.lengthText(length))")
    }

    private var subtitle: String {
      guard agent.isOn else {
        if let run = agent.lastRun {
          return String(localized: "On for \(SSHAgentText.length(run.length)) · \(run.signed) signed, \(run.denied) denied")
        }
        return String(localized: "Only v57 apps use your keys. ssh and git in Terminal can’t.")
      }
      let asking = agent.confirmation == .eachSignature ? String(localized: "Touch ID for each signature.") : String(localized: "Confirmed once.")
      if let until = agent.until {
        return String(localized: "ssh, git and other apps you run can sign with the \(SSHAgentText.key(agent.keyChoice)) until \(until.formatted(date: .omitted, time: .shortened)). \(asking)")
      }
      return String(localized: "Stops when you turn it off or quit Vault. \(asking)")
    }
  }

  /// One request: when, who and through what, what for, the result.
  private struct RequestRow: View {
    let request: VaultSSHAgent.Request

    var body: some View {
      HStack(spacing: 12) {
        Text(request.date.formatted(date: .omitted, time: .shortened)).kitFont(.caption).foregroundStyle(.kitSecondary)
          .frame(width: 64, alignment: .leading)
        Tile(
          systemImage: request.caller.aiAgent == nil ? "terminal" : "sparkles", hue: request.caller.aiAgent == nil ? .gray : .orange,
          size: 22)
        VStack(alignment: .leading, spacing: 1) {
          Text(request.caller.displayName).kitFont(.headline).lineLimit(1)
          Text(request.caller.chainLine).kitFont(.monoSmall).foregroundStyle(.kitSecondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 8)
        Text(purpose).kitFont(.caption).lineLimit(1).frame(width: 130, alignment: .leading)
        result.frame(width: 110, alignment: .leading)
      }
      .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var purpose: String {
      switch request.purpose {
      case .listed: String(localized: "listed keys")
      case .login(let user, let host): host ?? user
      case .signature(let namespace): namespace == "git" ? String(localized: "commit signature") : String(localized: "signature (\(namespace))")
      case .unknown: "—"
      }
    }

    @ViewBuilder private var result: some View {
      switch request.result {
      case .signed: Chip("Signed", hue: .green).controlSize(.small)
      case .denied: Chip("Denied", hue: .red).controlSize(.small)
      case .listed: Chip("Listed", hue: .gray).controlSize(.small)
      case .whileOff: Chip("Agent was off", hue: .gray).controlSize(.small)
      case .failed(let reason): Chip("Failed", hue: .red).controlSize(.small).help(reason)
      }
    }
  }

  /// Settings ▸ SSH Agent (board "Settings: SSH Agent").
  struct SSHAgentSettingsPane: View {
    @State private var agent = VaultSSHAgent.shared
    @State private var error: String?
    @State private var confirmReplace = false

    var body: some View {
      VStack(alignment: .leading, spacing: 18) {
        FormCard("Key the agent offers") {
          FormRow("Agent key", help: "A second Secure Enclave key, made for the agent only.", systemImage: "key.horizontal", hue: .orange) {
            Toggle("Agent key", isOn: Binding(get: { agent.keyChoice == .agent }, set: { agent.keyChoice = $0 ? .agent : .device }))
              .labelsHidden().toggleStyle(.kitSwitch)
          }
          FormRow("Replace Agent Key…", help: "Servers that trusted the old key no longer let the agent in.", systemImage: "arrow.triangle.2.circlepath", hue: .red) {
            Button("Replace…", role: .destructive) { confirmReplace = true }.buttonStyle(.kit).controlSize(.small)
          }
        }
        FormCard("Asking") {
          FormRow("Touch ID", help: "Each signature asks. “Once” asks when the agent turns on and covers its whole length.", systemImage: "touchid", hue: .red) {
            Picker("Touch ID", selection: $agent.confirmation) {
              Text("For each signature").tag(VaultSSHAgent.Confirmation.eachSignature)
              Text("Once per turn-on").tag(VaultSSHAgent.Confirmation.once)
            }
            .labelsHidden().fixedSize()
          }
          FormRow("AI agents always ask", help: "Requests started by Claude Code, Codex and other agents ask every time, whatever the setting above.", systemImage: "sparkles", hue: .orange) {
            Toggle("AI agents always ask", isOn: $agent.aiAgentsAlwaysAsk).labelsHidden().toggleStyle(.kitSwitch)
          }
          FormRow("Offer to turn on when asked while off", help: "At most once an hour for each app.", systemImage: "bell", hue: .gray) {
            Toggle("Offer to turn on", isOn: $agent.notifiesWhileOff).labelsHidden().toggleStyle(.kitSwitch)
          }
        }
        FormCard("Length") {
          FormRow("Usual length", help: "The menu bar’s quick switch.", systemImage: "clock", hue: .indigo) {
            Picker("Usual length", selection: $agent.usualLength) {
              ForEach(VaultSSHAgent.Length.allCases, id: \.self) { Text(VaultSSHAgent.lengthText($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
          }
          FormRow("Stop when the Mac locks", help: "Also on sleep and when you switch users.", systemImage: "lock", hue: .gray) {
            Toggle("Stop when the Mac locks", isOn: $agent.stopsOnLock).labelsHidden().toggleStyle(.kitSwitch)
          }
        }
        FormCard("Terminal and other apps") {
          FormRow("Use from Terminal", help: "One Include line at the top of ~/.ssh/config; Vault writes the rest into ~/.ssh/vault.conf and keeps it up to date. Off removes both.", systemImage: "terminal", hue: .gray) {
            Toggle("Use from Terminal", isOn: Binding(get: { agent.usesTerminal }, set: { on in
              do { try agent.setUseFromTerminal(on) } catch { self.error = error.localizedDescription }
            }))
            .labelsHidden().toggleStyle(.kitSwitch)
          }
          FormRow("Every host", help: "Off: only the hosts on the SSH Agent screen.", systemImage: "globe", hue: .indigo) {
            Toggle("Every host", isOn: $agent.servesEveryHost).labelsHidden().toggleStyle(.kitSwitch)
          }
          ForEach(agent.config.otherAgents(), id: \.line) { other in
            FormRow(
              "\(other.name)’s agent is also set",
              help: String(localized: "Line \(other.line) of ~/.ssh/config. Vault’s Include comes first, so its hosts use Vault."),
              systemImage: "exclamationmark.triangle", hue: .orange
            ) {}
          }
          FormRow("Show in menu bar", help: "While Vault runs, with or without a window.", systemImage: "menubar.rectangle", hue: .gray) {
            Toggle("Show in menu bar", isOn: $agent.showsInMenuBar).labelsHidden().toggleStyle(.kitSwitch)
          }
        }
        if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
        Text("No helper or login item: the agent is part of Vault and stops when Vault quits. The socket lives in Vault’s group container, readable by you only.")
          .kitFont(.caption).foregroundStyle(.kitSecondary).padding(.horizontal, 4)
      }
      .alert("Replace the Agent Key?", isPresented: $confirmReplace) {
        Button("Replace", role: .destructive) {
          do { try agent.replaceAgentKey() } catch { self.error = error.localizedDescription }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("The agent stops, and every server that trusted the old key needs the new one.")
      }
    }
  }

  /// The menu bar item's menu (board "SSH Agent: menu bar").
  struct SSHAgentMenu: View {
    @State private var agent = VaultSSHAgent.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
      if let until = agent.until {
        Text("SSH Agent · On · \(SSHAgentText.left(until: until))")
      } else {
        Text(agent.isOn ? "SSH Agent · On" : "SSH Agent · Off")
      }
      if agent.isOn {
        Button("Stop Now") { agent.stop() }
        Divider()
      }
      Section(agent.isOn ? "Restart for" : "Turn on for") {
        ForEach(SSHAgentText.lengths, id: \.self) { length in
          Button(length.map(VaultSSHAgent.lengthText) ?? String(localized: "Until Turned Off")) {
            Task { await SSHAgentPanels.turnOn(agent, for: length) }
          }
        }
      }
      Divider()
      Picker("Key", selection: Binding(get: { agent.keyChoice }, set: { agent.keyChoice = $0 })) {
        Text("Agent Key").tag(SSHAgentKeyChoice.agent)
        Text("This Mac’s Key").tag(SSHAgentKeyChoice.device)
      }
      Toggle("Touch ID for Each Signature", isOn: Binding(get: { agent.confirmation == .eachSignature }, set: { agent.confirmation = $0 ? .eachSignature : .once }))
      Divider()
      Button("Open SSH Agent…") { SSHAgentMenu.open(openWindow) }
    }

    /// Brings Vault forward on the agent's screen.
    static func open(_ openWindow: OpenWindowAction) {
      AppModel.all.first?.selection = .sshAgent
      SSHAgentPanels.bringForward()
      if AppModel.all.isEmpty { openWindow(value: VaultAccount.personal.id) }
    }
  }

  /// The menu bar item: the key glyph, with the minutes left while on (the menu bar host lays out again on every
  /// change, so the time is a state the task moves each minute, not a TimelineView, which kept it busy).
  struct SSHAgentMenuLabel: View {
    private let agent = VaultSSHAgent.shared
    @State private var now = Date.now

    var body: some View {
      Group {
        if let until = agent.until {
          Label(SSHAgentText.short(until: until, now: now), systemImage: "key.horizontal.fill").labelStyle(.titleAndIcon)
        } else {
          Image(systemName: agent.isOn ? "key.horizontal.fill" : "key.horizontal")
        }
      }
      .task(id: agent.until) {
        while !Task.isCancelled {
          now = .now
          try? await Task.sleep(for: .seconds(agent.until.map { $0.timeIntervalSinceNow < 120 ? 1 : 30 } ?? 3600))
        }
      }
    }
  }
#endif
