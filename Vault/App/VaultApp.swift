import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

#if os(macOS)
  import UpdateKit
#endif

@main
struct VaultApp: App {
  /// Personal's model (the demo's with `--demo`): the Settings window's, and the menu commands' while no window is
  /// focused. Each window shows its own account's (`MainWindow`).
  @State private var app: AppModel

  #if os(macOS)
    /// Updates for the Mac app from GitHub Releases (Vault.zip): checked only once the user turns on automatic
    /// checks (never before), installed in place with a relaunch. The iPad app updates through the App Store.
    private let updater = AppUpdater(github: "v57/Vault", assetName: "Vault.zip")
  #endif

  init() {
    _app = State(initialValue: AppModel.launch())
    #if os(macOS)
      updater.start()
    #endif
  }

  var body: some Scene {
    // Each window shows one account, kept as the window's value, so Open … in a New Window opens one on an account.
    WindowGroup(for: String.self) { $account in
      MainWindow(accountID: $account, personal: app)
        .kitToasts()
        .componentKit(accent: .vaultAccent)
        .preferredColorScheme(LaunchOptions.colorScheme)
    } defaultValue: {
      VaultAccount.personal.id
    }
    .defaultSize(width: 1440, height: 900)
    #if os(iOS)
      .backgroundTask(.appRefresh(VaultBackgroundRefresh.identifier)) { await AppModel.refreshInBackground() }
    #endif
    .commands {
      VaultCommands(personal: app)
      #if os(macOS)
        UpdaterCommands(updater: updater)
      #endif
    }
    #if os(macOS)
      Settings {
        SettingsView(updater: updater)
          .environment(app)
          .componentKit(accent: .vaultAccent)
      }
    #endif
  }
}

/// A main window: the account it shows, through `VaultAccountScope`, and that account's model. `--demo` shows the
/// demo vault alone, without accounts: the scope always opens the user's own vaults (`Vaults.shared`).
struct MainWindow: View {
  @Binding var accountID: String
  let personal: AppModel
  @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
  @Environment(\.openWindow) private var openWindow
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif

  var body: some View {
    Group {
      if personal.isDemo {
        AccountWindow(vault: personal.vault)
      } else {
        VaultAccountScope(
          selection: $accountID, manage: manageAccounts,
          openInNewWindow: supportsMultipleWindows ? { [openWindow] in openWindow(value: $0) } : nil
        ) { vault in
          AccountWindow(vault: vault)
        }
        .onChange(of: Vaults.shared.accounts) { AppModel.dropDeletedAccounts() }
      }
    }
    .task(id: [AnyHashable(personal.vault.logins), AnyHashable(personal.vault.passkeys)]) {
      // What the system offers in password and passkey fields (only once Vault is turned on in AutoFill settings):
      // Personal's, the store the AutoFill extension reads, whichever account the window shows.
      if !personal.isDemo { await VaultAutoFill.publish(personal.vault.logins, passkeys: personal.vault.passkeys) }
    }
  }

  /// Manage Accounts…: Settings on its Accounts pane (the Settings window on the Mac, pushed in the window elsewhere).
  private var manageAccounts: @MainActor @Sendable () -> Void {
    #if os(macOS)
      { [openSettings] in
        UserDefaults.standard.set("Accounts", forKey: "settings.pane")
        openSettings()
      }
    #else
      { [accountID] in
        UserDefaults.standard.set("Accounts", forKey: "settings.pane")
        AppModel.all.first { $0.vault.accountID == accountID }?.selection = .settings
      }
    #endif
  }
}

/// One account's window: its model, shared by the windows showing that account. `AppModel.model(for:)` starts a new
/// account's Hubs, which writes to its vault, so it runs once the view appears, not in the body.
private struct AccountWindow: View {
  let vault: Vault
  @State private var app: AppModel?

  init(vault: Vault) {
    self.vault = vault
    // An account a window already showed (Personal from launch) has its model from the first frame.
    _app = State(initialValue: AppModel.all.first { $0.vault === vault })
  }

  var body: some View {
    if let app {
      ContentView()
        .environment(app)
        .environment(\.vault, vault)
    } else {
      Color.clear.onAppear { app = AppModel.model(for: vault) }
    }
  }
}

extension FocusedValues {
  /// The focused window's model, for the menu commands.
  @Entry var appModel: AppModel?
}

/// Menu commands; each acts on the focused window's account (Personal's while no window is focused).
struct VaultCommands: Commands {
  let personal: AppModel
  @FocusedValue(\.appModel) private var focused

  private var app: AppModel { focused ?? personal }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Login…") { app.sheet = .newItem(.login) }
        .keyboardShortcut("n")
      Button("New Encrypted Folder…") { app.sheet = .newItem(.folder) }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Button("Add Remote…") { app.sheet = .addRemote }
    }
    CommandMenu("Vault") {
      Button("Sync Now") { app.syncNow() }
        .keyboardShortcut("r")
      // Every account's, not only the window's.
      Button("Lock All Folders") { AppModel.all.forEach { $0.folders.lockAll() } }
        .keyboardShortcut("l", modifiers: [.command, .control])
        .disabled(!AppModel.all.contains { $0.folders.hasDecrypted })
    }
  }
}

extension Color {
  /// Vault's accent: the system blue, like Shell and Markdown (an open question on the design board).
  static let vaultAccent = Color(.sRGB, red: 0, green: 0.478, blue: 1)
}
