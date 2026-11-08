import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

#if os(macOS)
  import UpdateKit
#endif

/// How often remotes are checked while Vault is open.
enum RemoteCheck: Int, KitOption, CaseIterable {
  case one = 1, five = 5, fifteen = 15, hour = 60

  var title: String { self == .hour ? String(localized: "Every hour") : String(localized: "Every \(rawValue) min") }
}

/// Boards 11 and 12: Vault's settings. iCloud is on (turning iCloud on was the consent); remotes are checked only
/// while Vault is open; Hub starts off; the recovery key is off until the user makes one.
struct SettingsView: View {
  #if os(macOS)
    let updater: AppUpdater
  #endif
  @Environment(\.kitIdiom) private var idiom
  @Environment(AppModel.self) private var app
  @KitStorage("settings.pane") private var pane = LaunchOptions.value("--settings-pane") ?? "Sync"
  @State private var iCloud = VaultICloudStatus.shared

  /// The connected Hubs' names, or Off.
  private var hubValue: LocalizedStringKey {
    let names = app.hubs.hubs.filter { $0.status == .connected }.map(\.name)
    return names.isEmpty ? "Off" : "\(ListFormatter.localizedString(byJoining: names))"
  }

  var body: some View {
    // The values show on iPhone, where the panes are rows.
    KitSettings(selection: $pane, window: .titled) {
      SettingsPane("General", systemImage: "gearshape", hue: .gray) { GeneralPane() }
      SettingsPane("Documents", systemImage: "doc.text.image", hue: .blue, value: "\(app.vault.documentCollections.count) collections") { DocumentsSettingsPane() }
      SettingsPane("Sync", systemImage: "arrow.triangle.2.circlepath", hue: .blue, value: iCloud.isOff ? "Off" : "iCloud") { SyncPane() }
      SettingsPane("Recovery Key", systemImage: "key", hue: .orange, value: app.recovery.isOn ? "On" : "Off") { RecoveryKeyPane() }
      SettingsPane("Backup", systemImage: "externaldrive", hue: .green) { BackupPane() }
      SettingsPane("AutoFill", systemImage: "rectangle.and.pencil.and.ellipsis", hue: .gray, value: "Off") { AutoFillPane() }
      SettingsPane("Hub", systemImage: "point.3.connected.trianglepath.dotted", hue: .purple, value: hubValue) { HubPane() }
      SettingsPane("Privacy", systemImage: "hand.raised", hue: .blue) { VaultICloudCard() }
      // The accounts every v57 app shares; not in demo runs, which never open the user's vaults.
      if !app.isDemo {
        SettingsPane("Accounts", systemImage: "person.2", hue: .indigo, section: "v57") { VaultAccountsSettings() }
        #if !os(macOS)
          SettingsPane("Devices", systemImage: "laptopcomputer", hue: .blue, section: "v57") { VaultDevicesSettings() }
        #endif
      }
      #if os(macOS)
        // Your devices, and your iPhone and iPad sign in to this Mac over SSH; it writes the real ~/.ssh, so never in the demo.
        if !app.isDemo {
          SettingsPane("Remote", systemImage: "network", hue: .teal, section: "v57") { VaultRemoteSettings() }
        }
      #endif
      #if os(macOS)
        SettingsPane("Updates", systemImage: "arrow.down.circle", hue: .gray, section: "v57") { UpdatesPane(updater: updater) }
      #else
        SettingsPane("About", systemImage: "info.circle", hue: .gray, section: "v57") { AboutPane() }
      #endif
    }
    .frame(minWidth: idiom == .mac ? 760 : nil, minHeight: idiom == .mac ? 600 : nil)
  }
}

#if !os(macOS)
  /// Settings pushed from the root list's bar (iPhone and iPad).
  struct TouchSettingsScreen: View {
    var body: some View {
      SettingsView()
        .kitPane(.content)
        .kitToolbar("Settings", meta: ["Vault"], systemImage: "gearshape", hue: .gray) {}
        .navigationBarBackButtonHidden(true)
    }
  }

  /// The App Store updates the app; no Updates pane.
  private struct AboutPane: View {
    var body: some View {
      FormCard {
        FormRow("Vault \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")", help: "Updates through the App Store", systemImage: "info.circle", hue: .gray)
      }
    }
  }
#else
  struct TouchSettingsScreen: View {
    var body: some View { EmptyView() }
  }
#endif

private struct GeneralPane: View {
  @KitStorage("defaultLockMinutes") private var lockMinutes = LockAfter.thirty.rawValue
  @State private var locks = VaultAppLock.isEnabled

  var body: some View {
    FormCard {
      // Security audit M13: on by default; turning it off asks first (`VaultAppLock.setEnabled`).
      FormRow(
        "Ask for Touch ID or Face ID",
        help: "When Vault opens or comes back after 5 minutes, and before a password, card or document number is shown or copied. One unlock lasts 5 minutes, AutoFill included.",
        systemImage: "faceid", hue: .green
      ) {
        Toggle("Ask for Touch ID or Face ID", isOn: Binding(get: { locks }, set: { on in
          Task {
            let changed = await VaultAppLock.setEnabled(on, reason: String(localized: "turn off the app lock"))
            locks = VaultAppLock.isEnabled
            if changed { AppLock.shared.enabledChanged() }
          }
        }))
        .toggleStyle(.kitSwitch)
        .kitLabelsHidden()
      }
      FormRow("Lock decrypted folders after", help: "What the Decrypt sheet picks first.", systemImage: "lock", hue: .orange) {
        KitSegmented(selection: Binding(get: { LockAfter(rawValue: lockMinutes) ?? .thirty }, set: { lockMinutes = $0.rawValue }))
          .controlSize(.small)
      }
    }
  }
}

private struct SyncPane: View {
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @KitStorage("remoteCheckMinutes") private var checkMinutes = RemoteCheck.five.rawValue
  @KitStorage("notifyConflicts") private var notifyConflicts = true
  @State private var replaced: [VaultSecretMove.Superseded] = []
  @State private var isShowingReplaced = false

  var body: some View {
    VaultICloudCard()
      .task { replaced = (try? VaultSecretMove.superseded()) ?? [] }
    if app.vault.store?.formatStatus.note != nil || !replaced.isEmpty {
      FormCard {
        if let note = app.vault.store?.formatStatus.note {
          FormRow("Other devices", help: "\(note)", systemImage: "clock", hue: .orange)
        }
        if !replaced.isEmpty {
          FormRow(
            "Replaced values",
            help: "A password or code changed on two devices at once. The later value is in use, and the other is kept here. It’s never deleted.",
            systemImage: "clock.arrow.circlepath", hue: .orange
          ) {
            Button("Show \(replaced.count)…") {
              Task { if await AppLock.shared.allow(String(localized: "Replaced values")) { isShowingReplaced = true } }
            }
            .buttonStyle(.kit)
          }
        }
      }
      .sheet(isPresented: $isShowingReplaced) {
        KitSheet(title: "Replaced Values", systemImage: "clock.arrow.circlepath", onClose: { isShowingReplaced = false }) {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(replaced) { value in
              VStack(alignment: .leading, spacing: 2) {
                Text(value.secret).font(.caption).foregroundStyle(.secondary)
                Text(String(data: value.value, encoding: .utf8) ?? value.value.base64EncodedString())
                  .font(.body.monospaced()).textSelection(.enabled)
              }
            }
          }
        }
      }
    }
    FormCard("Remotes") {
      FormRow("Check remotes", help: "When Vault opens, then on this schedule while it’s open. Only remotes your folders use.", systemImage: "clock", hue: .indigo) {
        KitPicker(selection: Binding(get: { RemoteCheck(rawValue: checkMinutes) ?? .five }, set: { checkMinutes = $0.rawValue }))
      }
      FormRow(
        "In the background",
        help: ThisDevice.isTouch
          ? "When \(ThisDevice.system) runs Vault’s background refresh. No helper."
          : "No helper or login item: the v57 app that makes a change sends it, or the next one that opens.",
        systemImage: ThisDevice.word == "iPhone" ? "iphone" : ThisDevice.word == "iPad" ? "ipad" : "desktopcomputer", hue: .gray)
    }
    FormCard("Hub") {
      ForEach(app.hubs.hubs.filter { $0.status != .off }) { hub in
        FormRow(
          idiom == .phone ? "Records through \(hub.name)" : "Vault records through \(hub.name)",
          help: "\(recordsHelp(hub))",
          systemImage: "point.3.connected.trianglepath.dotted", hue: .purple
        ) {
          Toggle("Records through \(hub.name)", isOn: Binding(get: { hub.syncsRecords }, set: { app.hubs.setSyncs(hub.id, $0) }))
            .toggleStyle(.kitSwitch).kitLabelsHidden()
        }
      }
      FormRow(
        "Live changes from your Hub",
        help: idiom == .phone
          ? "Not yet: folder changes still come with Check remotes"
          : "Not yet. Your own Hub will tell your devices at once when a folder changes. The files still go through the remote.",
        systemImage: "point.3.connected.trianglepath.dotted", hue: .purple
      ) {
        Toggle("Live changes from your Hub", isOn: .constant(false)).toggleStyle(.kitSwitch).kitLabelsHidden()
          .disabled(true)
      }
    }
    FormCard("Conflicts") {
      FormRow("Notify about conflicts", help: "A file changed here and elsewhere, or edited in a read-only folder.", systemImage: "exclamationmark.triangle", hue: .orange) {
        Toggle("Notify about conflicts", isOn: $notifyConflicts).toggleStyle(.kitSwitch).kitLabelsHidden()
      }
    }
  }

  /// How a Hub's record sync stands, then what turns it on; localized here since the sentences are joined.
  private func recordsHelp(_ hub: HubItem) -> String {
    [
      hub.syncsRecords
        ? (hub.recordSyncLine.isEmpty ? String(localized: "Waiting for the connection.") : hub.recordSyncLine + ".")
        : String(localized: "Off."),
      idiom == .phone
        ? String(localized: "Turned on on the Hub screen")
        : String(localized: """
          Per device and per Hub, off until turned on on the Hub screen; this \(ThisDevice.word) carries changes \
          between iCloud and the Hub.
          """),
    ].joined(separator: " ")
  }
}

/// Board 12: off by default, made only on request. What it brings back, and what it doesn't.
struct RecoveryKeyPane: View {
  @Environment(AppModel.self) private var app
  @State private var words: [String]?
  @State private var error: String?
  @State private var wordsSheet: RecoveryWordsSheet.Mode?
  @State private var replacing = false
  @State private var turningOff = false
  @State private var working = false

  var body: some View {
    let isOn = app.recovery.isOn
    VStack(alignment: .leading, spacing: 18) {
      FormCard(footer: "If iCloud Keychain loses your keys and there’s no recovery key, your encrypted folders, notes and passwords can’t be opened. There’s no other way in, by design.") {
        FormRow("Recovery key", help: isOn ? "On. Keep the kit somewhere safe." : "Off. iCloud Keychain holds the only copy of your keys.", systemImage: "key", hue: .orange, error: error.map { "\($0)" }) {
          if !isOn {
            Button("Create Recovery Key…") { create() }.buttonStyle(.kit)
              .disabled(!app.recovery.isAvailable || working)
              .help(app.recovery.isAvailable ? "Shows 24 words once" : "The vault on this device couldn’t be opened")
          }
        }
        FormRow("Recover with Key…", help: "On a device that lost its keys: type the 24 words or the kit’s code to bring back the vault keys, your identity and the passwords.", systemImage: "arrow.uturn.backward", hue: .blue) {
          Button("Recover…") { wordsSheet = .recover }.buttonStyle(.kit)
            .disabled(!app.recovery.isAvailable || working)
        }
      }
      if let words {
        FormCard("Your recovery kit", footer: "Write the words down or print them, and keep them away from this device. They aren’t shown again.") {
          HStack(alignment: .top, spacing: 14) {
            KitWordGrid(words)
            KitQRCode(words.joined(separator: " "), size: 120, correction: .high)
          }
          .padding(10)
        }
      }
      FormCard("What it brings back") {
        FormRow("Vault keys", help: "Records, notes and passwords on every device.", systemImage: "key.horizontal", hue: .blue) { check }
        FormRow("Your identity", help: "So shared folders and the people you share with still know you.", systemImage: "person", hue: .purple) { check }
        FormRow("Every folder key", help: "Also stored next to each folder on its remote, so a folder comes back even without your Apple ID.", systemImage: "lock.rectangle.stack", hue: .teal) { check }
        FormRow("Passwords and passkeys", help: "Logins, one-time codes, cards, passkeys and saved server and database passwords. Sealed so that only this kit opens them, not the vault key.", systemImage: "lock", hue: .orange) { check }
        FormRow("Imported SSH keys", help: "The ones you added to a connection.", systemImage: "key", hue: .orange) { check }
        FormRow("Not device SSH keys", help: "They never leave their Secure Enclave. A recovered device makes a new one.", systemImage: "shield", hue: .gray)
        FormRow("Not Hub keys or your GitHub sign-in", help: "You sign in again, and approve this device on your Hubs. Nor what Shell keeps in its own keychain.", systemImage: "shield", hue: .gray)
      }
      FormCard("When it’s on") {
        FormRow("Check Recovery Key…", help: "Type the words or scan the kit to make sure it still works.", systemImage: "checkmark", hue: .green) {
          Button("Check…") { wordsSheet = .check }.buttonStyle(.kit)
        }
        FormRow("Replace Recovery Key…", help: "For a lost or leaked kit: makes a new vault key, seals everything to the new kit and deletes the old copies. A leaked kit still opens the copies someone already took, so change the passwords too.", systemImage: "arrow.clockwise", hue: .blue) {
          Button("Replace…") { replacing = true }.buttonStyle(.kit)
        }
        FormRow("Turn Off", help: "Deletes every wrapped copy, in iCloud and on your remotes.", systemImage: "trash", hue: .red) {
          Button("Turn Off…") { turningOff = true }.buttonStyle(.kit)
        }
      }
      .disabled(!isOn || working)
      .opacity(isOn ? 1 : 0.5)
    }
    .kitSheet(item: $wordsSheet) { mode in RecoveryWordsSheet(mode: mode) }
    .kitConfirmation(
      "Replace the Recovery Key?", isPresented: $replacing,
      message: "The old kit stops opening the current vault key. Every device gets the new vault key through iCloud Keychain.",
      systemImage: "arrow.clockwise", confirm: "Replace", role: nil
    ) { run { words = try await app.recovery.replace() } }
    .kitConfirmation(
      "Turn Off the Recovery Key?", isPresented: $turningOff,
      message: "Every sealed copy is deleted, here and in iCloud. iCloud Keychain then holds the only copy of your keys.",
      systemImage: "trash", confirm: "Turn Off"
    ) { run { try await app.recovery.turnOff(); words = nil } }
  }

  private var check: some View {
    Image(systemName: "checkmark").foregroundStyle(Hue.green.fill).accessibilityLabel("Included")
  }

  private func create() {
    do { words = try app.recovery.create(); error = nil } catch { self.error = error.localizedDescription }
  }

  private func run(_ work: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      do { try await work(); error = nil } catch { self.error = error.localizedDescription }
      working = false
    }
  }
}

/// Typing or scanning the kit: to check it, or to recover with it.
private struct RecoveryWordsSheet: View {
  enum Mode: String, Identifiable {
    case check, recover
    var id: String { rawValue }
  }

  let mode: Mode
  @Environment(AppModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss
  @State private var text = ""
  @State private var result: String?
  @State private var isError = false
  @State private var working = false

  var body: some View {
    KitSheet(
      title: mode == .check ? "Check Recovery Key" : "Recover with Key",
      meta: "The 24 words, or the code under the QR code", systemImage: "key", hue: .orange, width: 520
    ) {
      TextEditor(text: $text)
        .font(.body.monospaced())
        .frame(minHeight: 110)
        .scrollContentBackground(.hidden)
        .padding(6)
        .kitSurface(.field)
        .kitTextContent(.verbatim)
      if let result {
        SheetStatus(result, systemImage: isError ? "xmark.octagon" : "checkmark.shield", hue: isError ? .red : .green)
      }
    } footer: {
      Spacer()
      Button(result == nil || isError ? "Cancel" : "Done") { dismiss() }.buttonStyle(.kit).keyboardShortcut(.cancelAction)
      Button(mode == .check ? "Check" : "Recover") { go() }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
    }
  }

  private func go() {
    working = true
    Task {
      defer { working = false }
      do {
        switch mode {
        case .check:
          let matches = try app.recovery.check(text)
          result =
            matches
            ? String(localized: "This is the current recovery key.")
            : String(localized: "These words are a recovery key, but not the current one.")
          isError = !matches
        case .recover:
          result = try await app.recovery.recover(text)
          isError = false
        }
      } catch {
        result = error.localizedDescription
        isError = true
      }
    }
  }
}

private struct AutoFillPane: View {
  var body: some View {
    FormCard(footer: "The credential provider is an extension the system starts when a password field asks; it isn’t a helper and isn’t registered with launchctl.") {
      FormRow("AutoFill passwords and codes", help: "In Safari and apps, through a credential provider extension. Comes in a later version.", systemImage: "rectangle.and.pencil.and.ellipsis", hue: .gray) {
        Toggle("AutoFill", isOn: .constant(false)).toggleStyle(.kitSwitch).kitLabelsHidden().disabled(true)
      }
    }
  }
}

/// The Hubs this device knows, each opening the Hub screen; Add Hub when there's none.
private struct HubPane: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    FormCard(footer: "Vault never contacts a server on its own. A Hub is yours: it runs where you choose, and Vault reaches it only once you add it.") {
      ForEach(app.hubs.hubs) { hub in
        FormRow(hub.name, help: HubStatusText.line(hub), systemImage: "point.3.connected.trianglepath.dotted", hue: hub.status == .connected ? .purple : .gray) {
          Button("Open Hub") { app.selection = .hub }.buttonStyle(.kit)
        }
      }
      if app.hubs.hubs.isEmpty {
        FormRow("Hub", help: "Off. Add your own Hub to see all your devices, Linux, Windows and Android included, and reach them over SSH.", systemImage: "point.3.connected.trianglepath.dotted", hue: .purple) {
          Button("Add Hub…") { app.sheet = .addHub }.buttonStyle(.kit)
        }
      }
    }
  }
}

#if os(macOS)
  private struct UpdatesPane: View {
    @Bindable var updater: AppUpdater

    var body: some View {
      FormCard(footer: "Vault checks GitHub Releases only once this is on.") {
        FormRow("Check for updates automatically", help: updater.lastCheckDate.map { "Last checked \(RelativeTime.short($0))" } ?? "Never checked", systemImage: "arrow.down.circle", hue: .blue) {
          Toggle("Check automatically", isOn: $updater.automaticallyChecksForUpdates).toggleStyle(.kitSwitch).kitLabelsHidden()
        }
        FormRow("Check now", systemImage: "arrow.clockwise", hue: .gray) {
          Button("Check Now") { updater.checkForUpdates() }.buttonStyle(.kit).disabled(updater.isBusy)
        }
      }
    }
  }
#endif
