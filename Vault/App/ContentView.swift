import ComponentKit
import SwiftUI
import VaultKit

#if DEBUG
  import DevScreenshots
#endif

struct ContentView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.openWindow) private var openWindow
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif
  @AppStorage("showWelcome") private var showWelcome = true
  #if DEBUG
    // `--hide-sidebar`: iPad portrait screenshots.
    @State private var columnVisibility: NavigationSplitViewVisibility =
      LaunchOptions.flag("--hide-sidebar") ? .detailOnly : .all
  #else
    @State private var columnVisibility = NavigationSplitViewVisibility.all
  #endif
  @State private var compactColumn = NavigationSplitViewColumn.sidebar

  var body: some View {
    @Bindable var app = app
    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
      SidebarView(columnVisibility: $columnVisibility)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 360)
    } detail: {
      DetailView()
        .kitSidebarToggle(columnVisibility: $columnVisibility)
    }
    .sheet(item: $app.sheet) { sheet in
      SheetContent(sheet: sheet)
        .environment(app)
        .componentKit(accent: .vaultAccent)
    }
    .onChange(of: app.selection) { _, _ in compactColumn = .detail }
    .onOpenURL { url in app.sharing.open(url) }
    .task(id: app.vault.logins) {
      // What the system offers in password fields (only once Vault is turned on in AutoFill settings).
      if !app.isDemo { await VaultAutoFill.publish(app.vault.logins) }
    }
    .onAppear {
      #if os(macOS)
        if LaunchOptions.flag("--welcome") || (showWelcome && !app.isDemo) { openWindow(id: "welcome") }
        if LaunchOptions.flag("--settings") { openSettings() }
      #endif
      #if DEBUG
        // Screenshots (.dev/screenshots.json): each scene sets the window up again from its own arguments.
        Screenshots.prepare(waitsForReady: false) { scene in
          LaunchOptions.arguments = scene.arguments
          app.sheet = nil
          app.selection = .logins
          app.applyLaunchOptions()
        }
      #endif
    }
  }
}

/// The main pane: whatever the sidebar selection opens.
struct DetailView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    switch app.selection ?? .logins {
    case .logins: LoginsView()
    case .cards: CardsView()
    case .notes: NotesView()
    case .hosts: HostsView()
    case .databases: DatabasesView()
    case .projects: ProjectsView()
    case .folder(let id): FolderScreen(folderID: id).id(id)
    case .location(let id): LocationView(locationID: id).id(id)
    case .devices: DevicesView()
    case .recoveryKey: RecoveryKeyScreen()
    }
  }
}

/// The sheet for `AppSheet`.
struct SheetContent: View {
  let sheet: AppSheet

  var body: some View {
    switch sheet {
    case .newItem(let kind): NewItemSheet(kind: kind)
    case .addRemote: AddRemoteSheet()
    case .decrypt(let id): DecryptSheet(folderID: id)
    case .share(let id): ShareSheet(folderID: id)
    case .invite: InviteSheet()
    case .addDevice: InviteSheet(forDevice: true)
    case .scanInvite: ScanInviteSheet()
    }
  }
}
