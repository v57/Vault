#if os(macOS)
  import AppKit
  import ComponentKit
  import LocalAuthentication
  import LocalAuthenticationEmbeddedUI
  import SwiftUI
  import VaultKit

  /// The SSH agent's floating panels: the request ("Terminal wants to sign in to github.com", answered with Touch ID),
  /// the offer when something asked while it was off, and the first-time question about `~/.ssh/config`. They float over
  /// every app without taking the user's app away (non-activating), so the terminal that asked keeps its window.
  @MainActor
  public enum SSHAgentPanels {
    /// Hooks the panels and the agent's lifecycle into the app: the request panel answers `approve`, the offer answers
    /// `askedWhileOff`, quitting closes the socket, and the socket opens now if the agent was ever on.
    public static func install(_ agent: VaultSSHAgent, accent: Color? = nil, openAgent: @escaping @MainActor () -> Void) {
      Self.accent = accent
      agent.approve = { approval in await request(approval, agent: agent) }
      agent.askedWhileOff = { caller in offer(caller, agent: agent, openAgent: openAgent) }
      NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { agent.shutdown() }
      }
      NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { if agent.stopsOnLock { agent.stop() } }
      }
      NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { if agent.stopsOnLock { agent.stop() } }
      }
      agent.startServing()
    }

    /// Turns the agent on, then asks once whether ssh in Terminal should use it too.
    public static func turnOn(_ agent: VaultSSHAgent, for length: VaultSSHAgent.Length?) async {
      await agent.turnOn(for: length)
      if agent.isOn, !agent.askedAboutTerminal, !agent.usesTerminal { askAboutTerminal(agent) }
    }

    private static var accent: Color?
    private static var open: [FloatingPanel] = []

    // MARK: The request

    static func request(_ approval: VaultSSHAgent.Approval, agent: VaultSSHAgent) async -> VaultSSHAgent.Answer {
      await withCheckedContinuation { continuation in
        var panel: FloatingPanel?
        var answered = false
        let finish: @MainActor (VaultSSHAgent.Answer) -> Void = { answer in
          guard !answered else { return }
          answered = true
          panel?.close()
          open.removeAll { $0 === panel }
          continuation.resume(returning: answer)
        }
        let view = RequestView(approval: approval, needsPresence: agent.needsPresence, finish: finish)
        panel = present(view, closes: { finish(.deny) })
      }
    }

    // MARK: Asked while off

    /// Brings Vault forward (Open Vault in the offer, the menu bar's Open SSH Agent…).
    public static func bringForward() {
      NSApp.activate()
      NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    static func offer(_ caller: SSHAgentCaller, agent: VaultSSHAgent, openAgent: @escaping @MainActor () -> Void) {
      var panel: FloatingPanel?
      let close: @MainActor () -> Void = {
        panel?.close()
        open.removeAll { $0 === panel }
      }
      let what = caller.sshDestination.map { String(localized: "\(caller.chainLine) to \($0)") } ?? caller.chainLine
      let view = NoticeView(
        title: String(localized: "\(caller.displayName) asked for an SSH key"),
        message: String(localized: "\(what). The SSH agent is off; run it again once it’s on."),
        primary: String(localized: "Turn On for 10 min"),
        secondary: String(localized: "Ignore"),
        primaryAction: {
          close()
          Task { await turnOn(agent, for: .tenMinutes) }
        },
        secondaryAction: close,
        detail: (String(localized: "Open Vault"), { close(); bringForward(); openAgent() }))
      panel = present(view, closes: close)
      // It goes away on its own, like a notification.
      Task {
        try? await Task.sleep(for: .seconds(20))
        close()
      }
    }

    // MARK: The first time

    static func askAboutTerminal(_ agent: VaultSSHAgent) {
      var panel: FloatingPanel?
      let close: @MainActor () -> Void = {
        panel?.close()
        open.removeAll { $0 === panel }
      }
      let view = TerminalQuestionView(
        add: {
          close()
          try? agent.setUseFromTerminal(true)
        },
        notNow: {
          close()
          agent.declineTerminal()
        })
      panel = present(view, closes: { agent.declineTerminal() })
    }

    // MARK: Panels

    private static func present(_ view: some View, closes: @escaping @MainActor () -> Void) -> FloatingPanel {
      let host = NSHostingView(rootView: view.componentKit(accent: accent).fixedSize())
      let size = host.fittingSize
      let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
      panel.contentView = host
      panel.onCancel = closes
      if let screen = NSScreen.main ?? NSScreen.screens.first {
        let frame = screen.visibleFrame
        let origin = NSPoint(
          x: frame.midX - size.width / 2,
          y: frame.maxY - size.height - 120 - CGFloat(open.count) * 24)
        panel.setFrameOrigin(origin)
      }
      open.append(panel)
      panel.orderFrontRegardless()
      panel.makeKey()
      return panel
    }

    final class FloatingPanel: NSPanel {
      var onCancel: (@MainActor () -> Void)?

      init(contentRect: NSRect) {
        super.init(
          contentRect: contentRect, styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
          backing: .buffered, defer: false)
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
      }

      override var canBecomeKey: Bool { true }

      override func cancelOperation(_ sender: Any?) {
        let cancel = onCancel
        onCancel = nil
        MainActor.assumeIsolated { cancel?() }
      }
    }
  }

  // MARK: Views

  /// The request panel (board "SSH Agent: asking"): who asked and through what, the server, a warning for an AI agent,
  /// "don't ask again", then Deny or Touch ID.
  private struct RequestView: View {
    let approval: VaultSSHAgent.Approval
    let needsPresence: Bool
    let finish: @MainActor (VaultSSHAgent.Answer) -> Void
    @State private var remember = false
    @State private var context = LAContext()
    @State private var asking = false
    @State private var failure: String?

    private var hasBiometrics: Bool {
      needsPresence && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          Tile(systemImage: "key.horizontal", hue: .orange, size: 36)
          VStack(alignment: .leading, spacing: 2) {
            Text(title).kitFont(.headline).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).kitFont(.caption).foregroundStyle(.kitSecondary).fixedSize(horizontal: false, vertical: true)
          }
        }
        FormCard {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(approval.caller.shownSteps.enumerated()), id: \.offset) { index, step in
              HStack(spacing: 8) {
                if index == 0 {
                  Tile(systemImage: approval.aiAgent == nil ? "terminal" : "sparkles", hue: approval.aiAgent == nil ? .gray : .orange, size: 20)
                  Text(approval.aiAgent ?? approval.caller.appName).kitFont(.headline)
                } else {
                  Circle().fill(.kitTertiary).frame(width: 6, height: 6).frame(width: 20)
                  Text(step.command).kitFont(.mono).lineLimit(2).truncationMode(.middle)
                }
              }
            }
          }
          .padding(.vertical, 8)
          .padding(.horizontal, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let agent = approval.aiAgent {
          Banner(
            "Started by \(agent), not typed by you.", message: "Allow only if you asked it to do this.",
            systemImage: "exclamationmark.triangle", hue: .orange
          ) {}
        }
        if approval.canRemember {
          Toggle("Don’t ask again for \(approval.caller.appName) until the agent stops", isOn: $remember).toggleStyle(.kitCheckbox)
        }
        if let failure { Text(failure).kitFont(.caption).foregroundStyle(Hue.red.text) }
        HStack(spacing: 10) {
          if hasBiometrics {
            TouchIDView(context: context).frame(width: 26, height: 26)
            Text(asking ? "Touch ID to allow" : "").kitFont(.caption).foregroundStyle(.kitSecondary)
          }
          Spacer()
          Button("Deny") { cancel() }.buttonStyle(.kit).keyboardShortcut(.cancelAction)
          Button(hasBiometrics ? "Use Password…" : "Allow") { askWithPassword() }
            .buttonStyle(hasBiometrics ? .kit : .kitPrimary)
        }
      }
      .padding(18)
      .frame(width: 440)
      .background(.background, in: RoundedRectangle(cornerRadius: 16))
      .task { if hasBiometrics { askWithTouchID() } }
    }

    private var title: String {
      let who = approval.aiAgent ?? approval.caller.appName
      switch approval.purpose {
      case .login(_, let host?): return String(localized: "\(who) wants to sign in to \(host)")
      case .login(let user, nil): return String(localized: "\(who) wants to sign in as \(user)")
      case .signature(let namespace) where namespace == "git": return String(localized: "\(who) wants to sign a commit")
      case .signature: return String(localized: "\(who) wants to sign with your SSH key")
      default: return String(localized: "\(who) wants to use your SSH key")
      }
    }

    private var subtitle: String {
      let key = approval.key == .agent ? String(localized: "Agent key") : String(localized: "This Mac’s key")
      if let until = approval.until {
        return String(localized: "With your \(key). The SSH agent is on until \(until.formatted(date: .omitted, time: .shortened)).")
      }
      return String(localized: "With your \(key). The SSH agent is on until you turn it off.")
    }

    private func cancel() {
      context.invalidate()
      finish(.deny)
    }

    /// Touch ID inside the panel: the sensor answers, no second dialog.
    private func askWithTouchID() {
      asking = true
      let context = context
      let reason = approval.reason
      Task {
        do {
          try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
          finish(.allow(SSHAgentProof(context: context), remember: remember))
        } catch let error as LAError where error.code == .userFallback || error.code == .biometryLockout {
          asking = false
          askWithPassword()
        } catch {
          asking = false
        }
      }
    }

    /// The system's dialog: Touch ID, a watch or the password.
    private func askWithPassword() {
      guard needsPresence else {
        finish(.allow(.none, remember: remember))
        return
      }
      let reason = approval.reason
      Task {
        do {
          let proof = try await SSHAgentProof.ask(reason: reason)
          context.invalidate()
          finish(.allow(proof, remember: remember))
        } catch {
          failure = String(localized: "Not confirmed. Allow again, or Deny.")
        }
      }
    }
  }

  private struct TouchIDView: NSViewRepresentable {
    let context: LAContext

    func makeNSView(context: Context) -> LAAuthenticationView { LAAuthenticationView(context: self.context, controlSize: .small) }
    func updateNSView(_ view: LAAuthenticationView, context: Context) {}
  }

  /// A short panel like a notification: a line, why, and two buttons.
  private struct NoticeView: View {
    let title: String
    let message: String
    let primary: String
    let secondary: String
    let primaryAction: @MainActor () -> Void
    let secondaryAction: @MainActor () -> Void
    let detail: (String, @MainActor () -> Void)

    var body: some View {
      HStack(alignment: .top, spacing: 10) {
        Tile(systemImage: "key.horizontal", hue: .red, size: 32, style: .solid)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).kitFont(.headline)
          Text(message).kitFont(.caption).foregroundStyle(.kitSecondary).fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 6) {
            Button(primary, action: primaryAction).buttonStyle(.kitPrimary)
            Button(secondary, action: secondaryAction).buttonStyle(.kit).keyboardShortcut(.cancelAction)
            Spacer()
            Button(detail.0, action: detail.1).buttonStyle(.kitPlain)
          }
          .controlSize(.small)
          .padding(.top, 4)
        }
      }
      .padding(14)
      .frame(width: 380)
      .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
  }

  /// "Use the agent from Terminal too?", asked once.
  private struct TerminalQuestionView: View {
    let add: @MainActor () -> Void
    let notNow: @MainActor () -> Void

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          Tile(systemImage: "terminal", hue: .gray, size: 36)
          VStack(alignment: .leading, spacing: 2) {
            Text("Use the agent from Terminal too?").kitFont(.headline)
            Text("Vault adds one line to the top of ~/.ssh/config and keeps the hosts it lists up to date. Settings ▸ SSH Agent turns it off.")
              .kitFont(.caption).foregroundStyle(.kitSecondary).fixedSize(horizontal: false, vertical: true)
          }
        }
        KitCodeBlock(SSHAgentConfig.includeLine, wraps: false)
        HStack {
          Spacer()
          Button("Not Now", action: notNow).buttonStyle(.kit).keyboardShortcut(.cancelAction)
          Button("Add Line", action: add).buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        }
      }
      .padding(18)
      .frame(width: 420)
      .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
  }
#endif
