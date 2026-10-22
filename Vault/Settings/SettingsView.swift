import ComponentKit
import SwiftUI
import VaultKit

#if os(macOS)
  import UpdateKit
#endif

/// How often remotes are checked while Vault is open.
enum RemoteCheck: Int, KitOption, CaseIterable {
  case one = 1, five = 5, fifteen = 15, hour = 60

  var title: String { self == .hour ? "Every hour" : "Every \(rawValue) min" }
}

/// Boards 11 and 12: Vault's settings. iCloud is on (turning iCloud on was the consent); remotes are checked only
/// while Vault is open; Hub starts off; the recovery key is off until the user makes one.
struct SettingsView: View {
  #if os(macOS)
    let updater: AppUpdater
  #endif
  @Environment(\.kitIdiom) private var idiom
  @Environment(AppModel.self) private var app
  @AppStorage("settings.pane") private var pane = LaunchOptions.value("--settings-pane") ?? "Sync"
  @AppStorage("iCloudSync") private var iCloud = true

  /// The connected Hubs' names, or Off.
  private var hubValue: String {
    let names = app.hubs.hubs.filter { $0.status == .connected }.map(\.name)
    return names.isEmpty ? "Off" : ListFormatter.localizedString(byJoining: names)
  }

  var body: some View {
    // The values show on iPhone, where the panes are rows.
    KitSettings(selection: $pane, window: .titled) {
      SettingsPane("General", systemImage: "gearshape", hue: .gray) { GeneralPane() }
      SettingsPane("Sync", systemImage: "arrow.triangle.2.circlepath", hue: .blue, value: iCloud ? "iCloud" : "Off") { SyncPane() }
      SettingsPane("Recovery Key", systemImage: "key", hue: .orange, value: app.recovery.isOn ? "On" : "Off") { RecoveryKeyPane() }
      SettingsPane("AutoFill", systemImage: "rectangle.and.pencil.and.ellipsis", hue: .gray, value: "Off") { AutoFillPane() }
      SettingsPane("Hub", systemImage: "point.3.connected.trianglepath.dotted", hue: .purple, value: hubValue) { HubPane() }
      #if os(macOS)
        SettingsPane("Updates", systemImage: "arrow.down.circle", hue: .gray) { UpdatesPane(updater: updater) }
      #else
        SettingsPane("About", systemImage: "info.circle", hue: .gray) { AboutPane() }
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
  @AppStorage("defaultLockMinutes") private var lockMinutes = LockAfter.thirty.rawValue

  var body: some View {
    FormCard {
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
  @AppStorage("iCloudSync") private var iCloud = true
  @AppStorage("remoteCheckMinutes") private var checkMinutes = RemoteCheck.five.rawValue
  @AppStorage("notifyConflicts") private var notifyConflicts = true

  var body: some View {
    FormCard {
      FormRow(
        "iCloud", help: "Records sync through your iCloud (\(VaultConfiguration.cloudContainer)). On while iCloud is on for this \(ThisDevice.word).",
        systemImage: "icloud", hue: .blue
      ) {
        Toggle("iCloud", isOn: $iCloud).toggleStyle(.kitSwitch).kitLabelsHidden()
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
          help: [
            hub.syncsRecords ? (hub.recordSyncLine.isEmpty ? "Waiting for the connection." : hub.recordSyncLine + ".") : "Off.",
            idiom == .phone
              ? "Turned on on the Hub screen"
              : "Per device and per Hub, off until turned on on the Hub screen; this \(ThisDevice.word) carries changes between iCloud and the Hub.",
          ].joined(separator: " "),
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
}

/// Board 12: off by default, made only on request. What it brings back, and what it doesn't.
struct RecoveryKeyPane: View {
  @Environment(AppModel.self) private var app
  @State private var words: [String]?
  @State private var error: String?

  var body: some View {
    let isOn = app.recovery.isOn
    VStack(alignment: .leading, spacing: 18) {
      FormCard(footer: "If iCloud Keychain loses your keys and there’s no recovery key, your encrypted folders, notes and passwords can’t be opened. There’s no other way in, by design.") {
        FormRow("Recovery key", help: isOn ? "On. Keep the kit somewhere safe." : "Off. iCloud Keychain holds the only copy of your keys.", systemImage: "key", hue: .orange, error: error) {
          if !isOn {
            Button("Create Recovery Key…") { create() }.buttonStyle(.kit)
              .disabled(!app.recovery.isAvailable)
              .help(app.recovery.isAvailable ? "Shows 24 words once" : "The recovery key comes in a later version")
          }
        }
      }
      if let words {
        FormCard("Your recovery kit") {
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
        FormRow("Not device SSH keys", help: "They never leave their Secure Enclave. A recovered device makes a new one.", systemImage: "shield", hue: .gray)
      }
      FormCard("When it’s on") {
        FormRow("Check Recovery Key…", help: "Type the words or scan the kit to make sure it still works.", systemImage: "checkmark", hue: .green) {
          Button("Check…") {}.buttonStyle(.kit)
        }
        FormRow("Replace Recovery Key…", help: "For a lost or leaked kit: re-wraps everything and deletes the old copies.", systemImage: "arrow.clockwise", hue: .blue) {
          Button("Replace…") { create() }.buttonStyle(.kit)
        }
        FormRow("Turn Off", help: "Deletes every wrapped copy, in iCloud and on your remotes.", systemImage: "trash", hue: .red) {
          Button("Turn Off…") {}.buttonStyle(.kit)
        }
      }
      .disabled(!isOn)
      .opacity(isOn ? 1 : 0.5)
    }
  }

  private var check: some View {
    Image(systemName: "checkmark").foregroundStyle(Hue.green.fill).accessibilityLabel("Included")
  }

  private func create() {
    do { words = try app.recovery.create() } catch { self.error = error.localizedDescription }
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
    @ObservedObject var updater: AppUpdater

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
