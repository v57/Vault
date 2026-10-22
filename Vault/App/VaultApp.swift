import ComponentKit
import SwiftUI
import VaultKit

#if os(macOS)
  import UpdateKit
#endif

@main
struct VaultApp: App {
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
    WindowGroup {
      ContentView()
        .environment(app)
        .kitToasts()
        .componentKit(accent: .vaultAccent)
        .preferredColorScheme(LaunchOptions.colorScheme)
    }
    .defaultSize(width: 1440, height: 900)
    #if os(iOS)
      .backgroundTask(.appRefresh(VaultBackgroundRefresh.identifier)) { await app.refreshInBackground() }
    #endif
    .commands {
      VaultCommands(app: app)
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

/// Menu commands; each acts on the app's model.
struct VaultCommands: Commands {
  let app: AppModel

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
      Button("Lock All Folders") { app.folders.lockAll() }
        .keyboardShortcut("l", modifiers: [.command, .control])
        .disabled(!app.folders.hasDecrypted)
    }
  }
}

extension Color {
  /// Vault's accent: the system blue, like Shell and Markdown (an open question on the design board).
  static let vaultAccent = Color(.sRGB, red: 0, green: 0.478, blue: 1)
}
