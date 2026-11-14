#if os(macOS)
  import Foundation
  import Observation

  /// Vault's SSH agent: lends a Secure Enclave key to `ssh`, `git` and other processes for a length the user picks (10
  /// seconds to 24 hours, or until turned off), asking before each signature or once. Off unless the user turns it on.
  ///
  /// It lives in the Vault app's process: no helper or login item. Once turned on the first time, its socket stays open
  /// while Vault runs, answering with no keys while off (so ssh falls back to the user's own) and offering to turn on
  /// (`askedWhileOff`). Quitting Vault (`shutdown()`) removes the socket; after a relaunch it's off.
  @MainActor
  @Observable
  public final class VaultSSHAgent {
    /// The real agent, or one with software keys and its own files in a run with secrets in memory (the demo).
    public static let shared: VaultSSHAgent = VaultSecrets.isInMemory ? .demo() : .live()

    // MARK: Settings (this device's)

    public var keyChoice: SSHAgentKeyChoice { didSet { save(keyChoice.rawValue, "key"); offered = nil } }
    public var confirmation: Confirmation { didSet { save(confirmation.rawValue, "confirmation") } }
    /// Requests an AI agent started (Claude Code, Codex…) ask every time, whatever `confirmation` says.
    public var aiAgentsAlwaysAsk: Bool { didSet { save(aiAgentsAlwaysAsk, "aiAgentsAlwaysAsk") } }
    /// A notification when something asks while the agent is off, offering to turn it on for 10 minutes.
    public var notifiesWhileOff: Bool { didSet { save(notifiesWhileOff, "notifiesWhileOff") } }
    /// The length the menu bar's and the page's quick switch use.
    public var usualLength: Length { didSet { save(usualLength.rawValue, "usualLength") } }
    /// Stops when the screen locks.
    public var stopsOnLock: Bool { didSet { save(stopsOnLock, "stopsOnLock") } }
    /// The servers ssh reaches through the agent (`servesEveryHost` off): written into `~/.ssh/vault.conf`.
    public var hosts: [String] { didSet { save(hosts, "hosts"); updateConfig() } }
    public var servesEveryHost: Bool { didSet { save(servesEveryHost, "servesEveryHost"); updateConfig() } }
    public var showsInMenuBar: Bool { didSet { save(showsInMenuBar, "showsInMenuBar") } }
    /// Whether "Use the agent from Terminal too?" was answered (it's asked once).
    public private(set) var askedAboutTerminal: Bool { didSet { save(askedAboutTerminal, "askedAboutTerminal") } }
    /// Set the first time the agent turns on: from then the socket opens with Vault.
    public private(set) var hasBeenOn: Bool { didSet { save(hasBeenOn, "hasBeenOn") } }

    public enum Confirmation: String, Sendable, CaseIterable {
      /// Touch ID for each signature (the default).
      case eachSignature
      /// Once, when the agent turns on; the yes covers its whole length.
      case once
    }

    public enum Length: Int, Sendable, CaseIterable {
      case tenSeconds = 10, tenMinutes = 600, hour = 3600, eightHours = 28_800, day = 86_400

      public var seconds: TimeInterval { TimeInterval(rawValue) }
    }

    // MARK: State

    public enum State: Equatable, Sendable {
      case off
      /// On since `since`, until `until` (nil: until turned off).
      case on(since: Date, until: Date?, length: Length?)
    }

    public private(set) var state: State = .off
    public var isOn: Bool { state != .off }
    /// The last run that ended: when, how long it was on for, and what it signed.
    public private(set) var lastRun: Run?
    /// What asked, newest first (this launch only, never saved).
    public private(set) var requests: [Request] = []
    /// Why the socket couldn't open, if it couldn't.
    public private(set) var socketError: String?
    /// Why turning on failed (Touch ID cancelled for "once").
    public private(set) var turnOnError: String?

    public struct Run: Equatable, Sendable {
      public var ended: Date
      public var length: Length?
      public var signed: Int
      public var denied: Int
    }

    public struct Request: Identifiable, Equatable, Sendable {
      /// The connection: one `ssh` run is one request, however many messages it sends.
      public let id: Int
      public var date: Date
      public var caller: SSHAgentCaller
      public var purpose: Purpose
      public var key: SSHAgentKeyChoice?
      public var result: Result

      public enum Purpose: Equatable, Sendable {
        /// Listed the keys and nothing more (`ssh-add -l`, or ssh finding no key it wanted).
        case listed
        /// Signed in to a server as `user`.
        case login(user: String, host: String?)
        /// Signed something (`ssh-keygen -Y sign`): "git" for a commit or tag.
        case signature(namespace: String)
        case unknown
      }

      public enum Result: Equatable, Sendable {
        case listed
        case signed(asked: Bool)
        case denied
        case whileOff
        case failed(String)
      }
    }

    /// What the request panel shows.
    public struct Approval: Sendable {
      public var caller: SSHAgentCaller
      public var purpose: Request.Purpose
      public var key: SSHAgentKeyChoice
      /// The AI agent that started it, if any: its panel warns.
      public var aiAgent: String?
      /// Whether the panel offers "don't ask again for this app": not for an AI agent's request while they always ask.
      public var canRemember: Bool
      public var until: Date?
      /// What Touch ID's own prompt says after "Vault is trying to".
      public var reason: String
    }

    public enum Answer: Sendable {
      case deny
      /// Allowed with this proof; `remember`: don't ask again for this app until the agent stops.
      case allow(SSHAgentProof, remember: Bool)
    }

    /// Shows the request panel and returns the user's answer (the UI asks for Touch ID itself). Unset: every signature
    /// is denied.
    public var approve: (@MainActor (Approval) async -> Answer)?
    /// Something asked while off (at most once an hour per app, when `notifiesWhileOff`).
    public var askedWhileOff: (@MainActor (SSHAgentCaller) -> Void)?

    // MARK: Parts

    public let socket: URL
    public let config: SSHAgentConfig
    private let keys: any SSHAgentKeys
    private let defaults: UserDefaults
    @ObservationIgnored private var server: SSHAgentServer?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var onceProof: SSHAgentProof?
    /// Apps the user said not to ask again for, with the yes they gave: until the agent stops.
    @ObservationIgnored private var remembered: [String: SSHAgentProof] = [:]
    @ObservationIgnored private var callers: [Int: SSHAgentCaller] = [:]
    @ObservationIgnored private var notified: [String: Date] = [:]
    /// One panel at a time: requests that arrive together wait for the one before.
    @ObservationIgnored private var asking: Task<Void, Never>?
    @ObservationIgnored private var lockObserver: NSObjectProtocol?
    /// The offered key's blob and comment, read once per key.
    @ObservationIgnored private var offered: (blob: Data, comment: String)?

    public init(keys: any SSHAgentKeys, socket: URL, home: URL, defaults: UserDefaults) {
      self.keys = keys
      self.socket = socket
      self.config = SSHAgentConfig(home: home, socket: socket)
      self.defaults = defaults
      func value<T>(_ name: String, _ fallback: T) -> T { defaults.object(forKey: "sshAgent." + name) as? T ?? fallback }
      keyChoice = SSHAgentKeyChoice(rawValue: value("key", "")) ?? .agent
      confirmation = Confirmation(rawValue: value("confirmation", "")) ?? .eachSignature
      aiAgentsAlwaysAsk = value("aiAgentsAlwaysAsk", true)
      notifiesWhileOff = value("notifiesWhileOff", true)
      usualLength = Length(rawValue: value("usualLength", Length.hour.rawValue)) ?? .hour
      stopsOnLock = value("stopsOnLock", true)
      hosts = value("hosts", [String]())
      servesEveryHost = value("servesEveryHost", false)
      showsInMenuBar = value("showsInMenuBar", true)
      askedAboutTerminal = value("askedAboutTerminal", false)
      hasBeenOn = value("hasBeenOn", false)
    }

    /// The user's agent: Secure Enclave keys, its socket beside the store, the real `~/.ssh`.
    static func live() -> VaultSSHAgent {
      VaultSSHAgent(
        keys: SecureEnclaveAgentKeys(),
        socket: VaultConfiguration.defaultDirectory().appendingPathComponent("ssh-agent.sock"),
        home: FileManager.default.homeDirectoryForCurrentUser, defaults: .standard)
    }

    /// The demo's: software keys, settings in memory, a socket and a home of its own in /tmp (a Unix socket's path has
    /// to be short), so it never touches the user's agent or `~/.ssh`.
    static func demo() -> VaultSSHAgent {
      let folder = URL(fileURLWithPath: "/tmp/v57-agent-demo-\(getpid())", isDirectory: true)
      let defaults = UserDefaults(suiteName: "dev.v57.vault.demo-agent")!
      defaults.removePersistentDomain(forName: "dev.v57.vault.demo-agent")
      return VaultSSHAgent(
        keys: SoftwareAgentKeys(), socket: folder.appendingPathComponent("agent.sock"),
        home: folder.appendingPathComponent("home", isDirectory: true), defaults: defaults)
    }

    private func save(_ value: Any, _ name: String) { defaults.set(value, forKey: "sshAgent." + name) }

    // MARK: Turning on and off

    /// Opens the socket if the agent was ever on: call at launch.
    public func startServing() {
      guard hasBeenOn else { return }
      openSocket()
    }

    /// At quit: stops, closes the socket and removes its file.
    public func shutdown() {
      stop()
      server?.stop()
      server = nil
    }

    /// Turns on for `length` (nil: until turned off), or restarts the clock from now when on. With `confirmation` set to
    /// `.once`, asks first (a no leaves it as it was).
    public func turnOn(for length: Length?) async {
      turnOnError = nil
      if confirmation == .once, onceProof == nil {
        let reason = length.map { String(localized: "let ssh and git sign with your SSH key for \(Self.lengthText($0))") }
          ?? String(localized: "let ssh and git sign with your SSH key until you turn the agent off")
        do {
          onceProof = try await askProof(reason)
        } catch {
          turnOnError = String(localized: "The agent stays off: you didn’t confirm it’s you.")
          return
        }
      }
      let now = Date.now
      let since: Date = if case .on(let since, _, _) = state { since } else { now }
      state = .on(since: since, until: length.map { now.addingTimeInterval($0.seconds) }, length: length)
      if !hasBeenOn { hasBeenOn = true }
      openSocket()
      watchLock()
      timer?.cancel()
      if let length {
        timer = Task { [weak self] in
          try? await Task.sleep(for: .seconds(length.seconds))
          guard !Task.isCancelled else { return }
          self?.stop()
        }
      }
    }

    /// Stops now: forgets every yes, and from the next request ssh gets no keys.
    public func stop() {
      timer?.cancel()
      timer = nil
      guard case .on(_, _, let length) = state else { return }
      let started = requests.filter { request in
        if case .on(let since, _, _) = state { return request.date >= since }
        return false
      }
      lastRun = Run(
        ended: .now, length: length,
        signed: started.filter { if case .signed = $0.result { return true } else { return false } }.count,
        denied: started.filter { $0.result == .denied }.count)
      state = .off
      onceProof?.invalidate()
      onceProof = nil
      remembered.values.forEach { $0.invalidate() }
      remembered = [:]
    }

    /// When an on agent stops on its own, nil when it's on until turned off or off.
    public var until: Date? {
      if case .on(_, let until, _) = state { return until }
      return nil
    }

    /// How much of the length is left, 0…1: nil while off or on until turned off.
    public var fractionLeft: Double? {
      guard case .on(_, let until?, let length?) = state else { return nil }
      return max(0, min(1, until.timeIntervalSinceNow / length.seconds))
    }

    /// The offered key's SSH wire blob ("SHA256:…" through `VaultIdentity.fingerprint`), nil if it can't be read.
    public var publicKeyBlob: Data? { offeredKey()?.blob }

    /// "ecdsa-sha2-nistp256 AAAA… comment", for a server's `authorized_keys`.
    public var publicKeyLine: String? {
      offeredKey().map { "ecdsa-sha2-nistp256 \($0.blob.base64EncodedString()) \($0.comment)" }
    }

    /// Whether a yes needs Touch ID or the password: false for the demo's software keys.
    public var needsPresence: Bool { !(keys is SoftwareAgentKeys) }

    /// Throws the agent key away and makes another.
    public func replaceAgentKey() throws {
      stop()
      try keys.replaceAgentKey()
      offered = nil
    }

    // MARK: Terminal

    /// Whether `~/.ssh/config` includes Vault's file.
    public var usesTerminal: Bool { config.isInstalled }

    /// Adds the Include line and the file, or takes both out.
    public func setUseFromTerminal(_ on: Bool) throws {
      askedAboutTerminal = true
      if on { try config.install(hosts: servesEveryHost ? nil : hosts) } else { try config.remove() }
    }

    /// "Not Now" on the first-time question.
    public func declineTerminal() { askedAboutTerminal = true }

    private func updateConfig() {
      try? config.update(hosts: servesEveryHost ? nil : hosts)
    }

    // MARK: Requests

    private func openSocket() {
      guard server == nil else { return }
      let server = SSHAgentServer(
        path: socket,
        handle: { [weak self] request, context in
          guard let self else { return SSHAgentProtocol.failureMessage }
          return await self.handle(request, context: context)
        },
        closed: { [weak self] connection in
          Task { @MainActor in self?.callers[connection] = nil }
        })
      do {
        try server.start()
        self.server = server
        socketError = nil
      } catch {
        socketError = error.localizedDescription
      }
    }

    /// Answers one request.
    public func handle(_ request: SSHAgentProtocol.Request, context: SSHAgentServer.Context) async -> Data {
      if let until, until <= .now { stop() }
      switch request {
      case .identities:
        guard isOn else {
          note(context, purpose: .listed, result: .whileOff)
          offerToTurnOn(caller(context))
          return SSHAgentProtocol.identities([])
        }
        note(context, purpose: .listed, result: .listed)
        guard let key = offeredKey() else { return SSHAgentProtocol.identities([]) }
        return SSHAgentProtocol.identities([key])
      case .sign(let blob, let data, _):
        guard isOn else {
          note(context, purpose: .unknown, result: .whileOff)
          return SSHAgentProtocol.failureMessage
        }
        guard let key = offeredKey(), key.blob == blob else { return SSHAgentProtocol.failureMessage }
        return await sign(data, context: context)
      case .sessionBind:
        return SSHAgentProtocol.successMessage
      case .otherExtension, .other:
        return SSHAgentProtocol.failureMessage
      }
    }

    private func sign(_ data: Data, context: SSHAgentServer.Context) async -> Data {
      let caller = caller(context)
      let purpose: Request.Purpose =
        switch SSHAgentProtocol.payload(data) {
        case .login(let user): .login(user: user, host: caller.sshDestination)
        case .signature(let namespace): .signature(namespace: namespace)
        case .unknown: .unknown
        }
      let choice = keyChoice
      let mustAsk = aiAgentsAlwaysAsk && caller.aiAgent != nil
      // A yes that covers this: the app's remembered one, or the one given when the agent turned on.
      if !mustAsk, let proof = remembered[caller.appKey] ?? (confirmation == .once ? onceProof : nil) {
        if let rs = try? keys.sign(data, with: choice, proof: proof) {
          note(context, purpose: purpose, key: choice, result: .signed(asked: false))
          return SSHAgentProtocol.ecdsaSignature(rs)
        }
        // The system stopped honoring it (the Mac locked): ask again.
        remembered[caller.appKey] = nil
      }
      let answer = await ask(Approval(
        caller: caller, purpose: purpose, key: choice, aiAgent: caller.aiAgent, canRemember: !mustAsk, until: until,
        reason: Self.reason(caller: caller, purpose: purpose)))
      guard isOn, case .allow(let proof, let remember) = answer else {
        if case .allow(let proof, _) = answer { proof.invalidate() }
        note(context, purpose: purpose, key: choice, result: .denied)
        return SSHAgentProtocol.failureMessage
      }
      do {
        let rs = try keys.sign(data, with: choice, proof: proof)
        if remember, !mustAsk { remembered[caller.appKey] = proof } else { proof.invalidate() }
        note(context, purpose: purpose, key: choice, result: .signed(asked: true))
        return SSHAgentProtocol.ecdsaSignature(rs)
      } catch {
        proof.invalidate()
        note(context, purpose: purpose, key: choice, result: .failed(error.localizedDescription))
        return SSHAgentProtocol.failureMessage
      }
    }

    /// The panel, one at a time.
    private func ask(_ approval: Approval) async -> Answer {
      let previous = asking
      let answer = Task { @MainActor [approve] in
        await previous?.value
        guard let approve else { return Answer.deny }
        return await approve(approval)
      }
      asking = Task { _ = await answer.value }
      return await answer.value
    }

    /// Tests: every request reads as coming from `caller`.
    @ObservationIgnored private var callerForTesting: SSHAgentCaller?
    func setCallerForTesting(_ caller: SSHAgentCaller?) { callerForTesting = caller }

    private func caller(_ context: SSHAgentServer.Context) -> SSHAgentCaller {
      if let callerForTesting { return callerForTesting }
      if let known = callers[context.connection] { return known }
      let caller = SSHAgentCaller.of(pid: context.pid)
      callers[context.connection] = caller
      return caller
    }

    /// Adds or updates the connection's row: a sign after a list replaces "Listed".
    private func note(_ context: SSHAgentServer.Context, purpose: Request.Purpose, key: SSHAgentKeyChoice? = nil, result: Request.Result) {
      if let index = requests.firstIndex(where: { $0.id == context.connection }) {
        if result == .listed || (result == .whileOff && requests[index].result == .whileOff) { return }
        requests[index].purpose = purpose == .unknown ? requests[index].purpose : purpose
        requests[index].key = key ?? requests[index].key
        requests[index].result = result
        requests[index].date = .now
        return
      }
      requests.insert(Request(id: context.connection, date: .now, caller: caller(context), purpose: purpose, key: key, result: result), at: 0)
      if requests.count > 200 { requests.removeLast(requests.count - 200) }
    }

    private func offerToTurnOn(_ caller: SSHAgentCaller) {
      guard notifiesWhileOff, let askedWhileOff else { return }
      let key = caller.appKey
      if let last = notified[key], Date.now.timeIntervalSince(last) < 3600 { return }
      notified[key] = .now
      askedWhileOff(caller)
    }

    private func offeredKey() -> (blob: Data, comment: String)? {
      if let offered { return offered }
      guard let blob = try? keys.publicKeyBlob(keyChoice) else { return nil }
      let comment = keyChoice == .agent ? "Vault agent key" : "This Mac's key (Vault)"
      offered = (blob, comment)
      return offered
    }

    private func askProof(_ reason: String) async throws -> SSHAgentProof {
      if keys is SoftwareAgentKeys { return .none }
      return try await SSHAgentProof.ask(reason: reason)
    }

    private func watchLock() {
      guard lockObserver == nil else { return }
      lockObserver = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.stopsOnLock else { return }
          self.stop()
        }
      }
    }

    // MARK: Words

    /// "1 hour", "10 seconds"…
    public static func lengthText(_ length: Length) -> String {
      switch length {
      case .tenSeconds: String(localized: "10 seconds")
      case .tenMinutes: String(localized: "10 minutes")
      case .hour: String(localized: "1 hour")
      case .eightHours: String(localized: "8 hours")
      case .day: String(localized: "24 hours")
      }
    }

    /// Touch ID's line: "let Terminal sign in to github.com".
    static func reason(caller: SSHAgentCaller, purpose: Request.Purpose) -> String {
      switch purpose {
      case .login(_, let host?): String(localized: "let \(caller.displayName) sign in to \(host)")
      case .signature(let namespace) where namespace == "git": String(localized: "let \(caller.displayName) sign a commit")
      case .signature: String(localized: "let \(caller.displayName) sign with your SSH key")
      default: String(localized: "let \(caller.displayName) use your SSH key")
      }
    }
  }
#endif
