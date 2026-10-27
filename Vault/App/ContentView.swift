import ComponentKit
import SwiftUI
import VaultKit

#if DEBUG
  import DevScreenshots
#endif

struct ContentView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif
  /// iPhone: the welcome was opened past once ("Open Vault"); later launches start on the root list.
  @AppStorage("welcome.opened") private var welcomeOpened = false
  @Environment(\.scenePhase) private var scenePhase
  #if DEBUG
    // `--hide-sidebar`: iPad portrait screenshots.
    @State private var columnVisibility: NavigationSplitViewVisibility =
      LaunchOptions.flag("--hide-sidebar") ? .detailOnly : .all
  #else
    @State private var columnVisibility = NavigationSplitViewVisibility.all
  #endif
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  @State private var showsPhoneWelcome = LaunchOptions.flag("--welcome")
    || (!LaunchOptions.flag("--demo") && !UserDefaults.standard.bool(forKey: "welcome.opened"))

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
    // The kit's overlay on the Mac and iPad; the system sheet on iPhone, half height for the bottom sheets.
    .kitSheet(item: Binding(get: { app.sheet == .scanInvite && idiom == .phone ? nil : app.sheet }, set: { app.sheet = $0 })) { sheet in
      SheetContent(sheet: sheet)
        .presentationDetents(idiom == .phone && sheet.isBottomSheet ? [.medium, .large] : [.large])
    }
    #if os(iOS)
      // iPhone: the welcome is the first screen, full height, until "Open Vault" (the Mac and iPad show it inline).
      .fullScreenCover(isPresented: Binding(get: { showsPhoneWelcome && idiom == .phone }, set: { showsPhoneWelcome = $0 })) {
        WelcomeScreen(onOpen: {
          if !app.isDemo { welcomeOpened = true }
          showsPhoneWelcome = false
        })
        .environment(app)
        .componentKit(accent: .vaultAccent)
        .preferredColorScheme(LaunchOptions.colorScheme)
      }
      // iPhone: the scanner fills the screen.
      .fullScreenCover(isPresented: Binding(get: { app.sheet == .scanInvite && idiom == .phone }, set: { if !$0 { app.sheet = nil } })) {
        ScanInviteSheet()
          .environment(app)
          .componentKit(accent: .vaultAccent)
      }
    #endif
    .onChange(of: app.selection) { _, _ in compactColumn = .detail }
    .onOpenURL { url in app.sharing.open(url) }
    .onChange(of: scenePhase) { _, phase in
      // Leaving the screen: ask for a background turn to check remotes (iPhone and iPad; nothing on the Mac).
      if phase == .background, !app.isDemo { app.scheduleBackgroundRefresh() }
    }
    .task(id: [AnyHashable(app.vault.logins), AnyHashable(app.vault.passkeys)]) {
      // What the system offers in password and passkey fields (only once Vault is turned on in AutoFill settings).
      if !app.isDemo { await VaultAutoFill.publish(app.vault.logins, passkeys: app.vault.passkeys) }
    }
    .onAppear {
      // `--select` on iPhone opens that screen over the root list.
      if LaunchOptions.value("--select") != nil { compactColumn = .detail }
      #if os(macOS)
        if LaunchOptions.flag("--settings") { openSettings() }
      #endif
      #if DEBUG
        // Screenshots (.dev/screenshots.json): each scene sets the window up again from its own arguments.
        Screenshots.prepare(waitsForReady: false) { scene in
          LaunchOptions.arguments = scene.arguments
          app.sheet = nil
          app.selection = nil
          app.applyLaunchOptions()
        }
      #endif
    }
  }
}

/// The main pane: whatever the sidebar selection opens.
struct DetailView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if idiom == .phone {
      // Screens push their items (a login's page, a file's preview) on a stack of their own.
      NavigationStack { screen }
    } else {
      screen
    }
  }

  @ViewBuilder
  private var screen: some View {
    if let selection = app.selection {
      content(for: selection)
    } else {
      // Nothing selected: the welcome is the main screen (on iPhone the root list is).
      WelcomeScreen()
    }
  }

  @ViewBuilder
  private func content(for selection: SidebarItem) -> some View {
    switch selection {
    case .logins: LoginsView()
    case .cards: CardsView()
    case .notes: NotesView()
    case .hosts: HostsView()
    case .databases: DatabasesView()
    case .projects: ProjectsView()
    case .folder(let id): FolderScreen(folderID: id).id(id)
    case .location(let id): LocationView(locationID: id).id(id)
    case .devices: DevicesView()
    case .hub: HubView()
    case .recoveryKey: RecoveryKeyScreen()
    case .settings: TouchSettingsScreen()
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
    case .addHub: AddHubSheet()
    case .scanInvite: ScanInviteSheet()
    case .autoFillPreview: AutoFillPreview()
    }
  }
}

/// The AutoFill sheet as the extension shows it for atlas.example.com, over the demo logins.
private struct AutoFillPreview: View {
  @Environment(AppModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss
  @State private var model = AutoFillModel()

  var body: some View {
    AutoFillPicker(model: model)
      .onAppear {
        model.all = app.vault.logins.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        model.suggested = VaultAutoFill.logins(for: ["https://atlas.example.com/login"], in: model.all)
        model.host = "atlas.example.com"
        model.complete = { _ in dismiss() }
        model.cancel = { dismiss() }
      }
  }
}
