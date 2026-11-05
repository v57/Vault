import ComponentKit
import SwiftUI
import VaultKit

/// What an app can do for Lost Device beyond the vault: its Hubs and SSH, which VaultUI doesn't reach. Each runs when
/// the user clicks it, and returns what happened, in a line.
public struct VaultLostDeviceActions {
  public struct Action: Identifiable {
    public let id: String
    public let name: String
    public let systemImage: String
    /// Nothing to do here: why (a Hub that doesn't list the device).
    public let unavailable: String?
    public let run: @MainActor () async throws -> String

    public init(
      id: String, name: String, systemImage: String, unavailable: String? = nil,
      run: @escaping @MainActor () async throws -> String
    ) {
      self.id = id
      self.name = name
      self.systemImage = systemImage
      self.unavailable = unavailable
      self.run = run
    }
  }

  public var hubs: [Action]
  public var servers: [Action]

  /// `hubs` and `servers` empty: an app without them says to use the Vault app.
  public init(hubs: [Action] = [], servers: [Action] = []) {
    self.hubs = hubs
    self.servers = servers
  }
}

/// The steps of Lost Device and how each went. Nothing starts by itself: every step runs at its own click, and any of
/// them can be skipped or tried again, in any order.
@MainActor
@Observable
public final class VaultLostDeviceFlow {
  public enum Progress: Equatable {
    case waiting
    case working
    case done(String)
    case skipped
    case failed(String)
  }

  public let device: VaultDeviceKey
  public let hubs: [VaultLostDeviceActions.Action]
  public let servers: [VaultLostDeviceActions.Action]
  public private(set) var progress: [String: Progress] = [:]
  private let vaults: Vaults
  private let thisMac: VaultAuthorizedKeys?

  static let appleAccount = "appleAccount"
  static let trust = "trust"
  static let thisMacSweep = "thisMac"
  static let rotate = "rotate"

  /// - Parameter thisMac: this Mac's `authorized_keys`, when the app can change it.
  public init(
    device: VaultDeviceKey, vaults: Vaults = .shared, actions: VaultLostDeviceActions = .init(),
    thisMac: VaultAuthorizedKeys? = VaultLostDeviceFlow.defaultThisMac
  ) {
    self.device = device
    self.vaults = vaults
    hubs = actions.hubs
    servers = actions.servers
    self.thisMac = thisMac
  }

  public static var defaultThisMac: VaultAuthorizedKeys? {
    #if os(macOS)
      VaultThisMac.canManageSSH ? .user : nil
    #else
      nil
    #endif
  }

  public func state(_ id: String) -> Progress { progress[id] ?? .waiting }

  public var canSweepThisMac: Bool { thisMac != nil }

  /// Whether the user said the device left the Apple account.
  public var leftAppleAccount: Bool { if case .done = state(Self.appleAccount) { true } else { false } }

  public func skip(_ id: String) { progress[id] = .skipped }

  public func reset(_ id: String) { progress[id] = nil }

  /// The user removed it from the Apple account, which only they can do.
  public func confirmLeftAppleAccount() {
    progress[Self.appleAccount] = .done("You removed it from your Apple Account.")
  }

  public func stopTrusting() {
    run(Self.trust) { [device, vaults] in
      vaults.revokeDevice(device)
      if let error = vaults.personal.error { throw Failure(error) }
      return "It’s out of your vault and can’t publish itself again. If it tries, it shows as not trusted."
    }
  }

  public func sweepThisMac() {
    guard let thisMac else { return }
    run(Self.thisMacSweep) { [device] in
      let before = try thisMac.allowedDevices(among: [device]).isEmpty
      try thisMac.disallow(device)
      return before ? "It wasn’t in this \(KitDevice.name)’s authorized_keys." : "Taken out of this \(KitDevice.name)’s authorized_keys."
    }
  }

  public func rotateKeys() {
    run(Self.rotate) { [vaults] in
      let rotation = try vaults.rotateKeys()
      return "A new vault key is in use, and \(rotation.rewritten) records were sealed again. What’s written under the old "
        + "key is refused from now on."
    }
  }

  public func run(_ action: VaultLostDeviceActions.Action) { run(action.id, action.run) }

  /// Every server not done yet, one after another: one click for all of them.
  public func sweepAllServers() {
    for server in servers where server.unavailable == nil {
      switch state(server.id) {
      case .waiting, .failed: run(server)
      default: break
      }
    }
  }

  private func run(_ id: String, _ work: @escaping @MainActor () async throws -> String) {
    guard state(id) != .working else { return }
    progress[id] = .working
    Task {
      do {
        progress[id] = .done(try await work())
      } catch {
        progress[id] = .failed(error.localizedDescription)
      }
    }
  }

  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
  }

  /// What it could read, to change by hand: every vault key it held opens these, and a copy may have been made.
  public struct Secrets: Equatable {
    public var title: String
    public var names: [String]
  }

  public var secretsToChange: [Secrets] {
    let vaults = vaults.allAccounts.compactMap { self.vaults.vault(for: $0) }
    func names(_ list: (Vault) -> [String]) -> [String] { vaults.flatMap(list).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    return [
      Secrets(title: "Logins", names: names { $0.logins.map(\.displayName) }),
      Secrets(title: "Passkeys", names: names { $0.passkeys.map(\.relyingParty) }),
      Secrets(title: "Cards", names: names { $0.cards.map(\.title) }),
      Secrets(title: "Servers with a password", names: names { $0.hosts.filter { $0.auth == .password }.map(\.displayName) }),
      Secrets(title: "Databases", names: names { $0.databases.map(\.name) }),
    ].filter { !$0.names.isEmpty }
  }
}

/// Lost Device: for a device that's lost, stolen or sold without being wiped.
///
/// iCloud Keychain gives every device in the Apple account the vault keys, the old ones and any new one. So the steps
/// are in the order that works, and the sheet says so: nothing else here keeps out a device that's still in the account.
///
/// ```swift
/// .kitSheet(item: $lost) { VaultLostDeviceSheet(device: $0) }
/// ```
public struct VaultLostDeviceSheet: View {
  @State private var flow: VaultLostDeviceFlow
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  public init(device: VaultDeviceKey, vaults: Vaults = .shared, actions: VaultLostDeviceActions = .init()) {
    _flow = State(initialValue: VaultLostDeviceFlow(device: device, vaults: vaults, actions: actions))
  }

  init(flow: VaultLostDeviceFlow) {
    _flow = State(initialValue: flow)
  }

  /// What Lost Device… does, for its menu row's preview: it opens this sheet, whose steps each wait for a click.
  public static func menuPreview(_ deviceName: String) -> String {
    "Shows the steps to cut \(deviceName) off: your Apple Account, your vault, your servers, your keys. "
      + "Each runs only when you click it."
  }

  /// Where the user removes a device: it can't be done from here.
  static let appleAccountURL = URL(string: "https://account.apple.com/account/manage/section/devices")!

  public var body: some View {
    KitSheet(
      title: "Lost \(flow.device.deviceName)",
      meta: "Each step runs when you click it, and can be skipped or tried again.",
      systemImage: "exclamationmark.shield", hue: .red
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          appleAccountStep
          trustStep
          serversStep
          rotateStep
          secretsStep
        }
      }
      .frame(idealHeight: 620)
      .kitSheetFooterBar()
    } footer: {
      Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  private var appleAccountStep: some View {
    FormCard(
      "1. Remove It from Your Apple Account",
      footer: "This comes first, and only you can do it. Until then it keeps getting your vault keys and passwords through "
        + "iCloud Keychain, new ones included, whatever the steps below do."
    ) {
      FormRow(
        "Apple Account", help: help(VaultLostDeviceFlow.appleAccount, "Devices ▸ \(flow.device.deviceName) ▸ Remove from Account."),
        systemImage: "person.crop.circle.badge.xmark", hue: .red
      ) {
        HStack {
          Button("Open…") { openURL(Self.appleAccountURL) }.buttonStyle(.kit)
          trailing(VaultLostDeviceFlow.appleAccount, title: "I Removed It") { flow.confirmLeftAppleAccount() }
        }
      }
    }
  }

  private var trustStep: some View {
    FormCard(
      "2. Stop Trusting It",
      footer: flow.hubs.isEmpty
        ? "To revoke it on your Hubs too, do this step in the Vault app, which connects to them." : "A Hub stops letting it in at once."
    ) {
      FormRow(
        "Your Vault", help: help(VaultLostDeviceFlow.trust, "It goes from every app, and doesn’t come back by itself."),
        systemImage: "person.badge.minus", hue: .red
      ) {
        trailing(VaultLostDeviceFlow.trust, title: "Stop Trusting") { flow.stopTrusting() }
      }
      ForEach(flow.hubs) { hub in actionRow(hub, title: "Revoke") }
    }
  }

  private var serversStep: some View {
    FormCard(
      "3. Take It Off Your Servers",
      footer: flow.servers.isEmpty
        ? "To take it off other machines, do this step in the Vault app, which can sign in to them."
        : "Signs in with this \(KitDevice.name)’s key or the saved password and takes its lines out of ~/.ssh/authorized_keys. "
          + "Other lines stay. A server whose key you never accepted isn’t contacted."
    ) {
      if flow.canSweepThisMac {
        FormRow(
          "This \(KitDevice.name)", help: help(VaultLostDeviceFlow.thisMacSweep, "Its lines in ~/.ssh/authorized_keys."),
          systemImage: "desktopcomputer", hue: .blue
        ) {
          trailing(VaultLostDeviceFlow.thisMacSweep, title: "Take Out") { flow.sweepThisMac() }
        }
      }
      ForEach(flow.servers) { server in actionRow(server, title: "Take Out") }
      if flow.servers.count > 1 {
        FormRow("All of Them", help: "One after another.", systemImage: "square.stack.3d.up", hue: .blue) {
          Button("Take Out of All") { flow.sweepAllServers() }.buttonStyle(.kit)
        }
      }
    }
  }

  private var rotateStep: some View {
    FormCard(
      "4. Make a New Vault Key",
      footer: flow.leftAppleAccount
        ? "It keeps what it copied before, and can’t write to your vault after this."
        : "It’s still in your Apple Account as far as this \(KitDevice.name) knows, so it would get the new key too: step 1 first."
    ) {
      FormRow(
        "New Vault Key", help: help(VaultLostDeviceFlow.rotate, "Seals every record again. Your other devices get it through iCloud Keychain."),
        systemImage: "key.horizontal", hue: .orange
      ) {
        trailing(VaultLostDeviceFlow.rotate, title: "Make New Key") { flow.rotateKeys() }
      }
    }
  }

  private var secretsStep: some View {
    let secrets = flow.secretsToChange
    return FormCard(
      "5. Change These by Hand",
      footer: "It could read these, and a new vault key doesn’t change them. Nothing here can do it for you: each lives with the "
        + "site or server it belongs to."
    ) {
      if secrets.isEmpty {
        FormRow("Nothing Saved", help: "No logins, cards, passkeys or passwords in your vault.", systemImage: "checkmark", hue: .green)
      }
      ForEach(secrets, id: \.title) { group in
        FormRow(
          "\(group.title) (\(group.names.count))", help: group.names.joined(separator: ", "), systemImage: "exclamationmark.triangle",
          hue: .orange)
      }
    }
  }

  private func actionRow(_ action: VaultLostDeviceActions.Action, title: String) -> some View {
    FormRow(action.name, help: action.unavailable ?? help(action.id, nil), systemImage: action.systemImage, hue: .blue) {
      if action.unavailable == nil {
        trailing(action.id, title: title) { flow.run(action) }
      }
    }
  }

  /// What the step says: how it went, or what it does.
  private func help(_ id: String, _ waiting: String?) -> String? {
    switch flow.state(id) {
    case .waiting, .working: waiting
    case .done(let line): line
    case .skipped: "Skipped."
    case .failed(let line): line
    }
  }

  /// The step's buttons, for how it stands.
  @ViewBuilder
  private func trailing(_ id: String, title: String, run: @escaping () -> Void) -> some View {
    switch flow.state(id) {
    case .waiting:
      HStack {
        Button("Skip") { flow.skip(id) }.buttonStyle(.kit)
        Button(title, action: run).buttonStyle(.kit)
      }
    case .working:
      ProgressView().controlSize(.small)
    case .done:
      HStack {
        Button("Again", action: run).buttonStyle(.kit)
        Image(systemName: "checkmark").foregroundStyle(Hue.green.fill).accessibilityLabel("Done")
      }
    case .skipped:
      Button("Undo") { flow.reset(id) }.buttonStyle(.kit)
    case .failed:
      Button("Try Again", action: run).buttonStyle(.kit)
    }
  }
}
