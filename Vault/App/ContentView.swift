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
  @KitStorage("welcome.opened") private var welcomeOpened = false
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
        .kitSidebarColumn()
    } detail: {
      DetailView()
        .kitSidebarToggle(columnVisibility: $columnVisibility)
    }
    // While the iPhone's welcome covers the window, it presents the sheets its actions open: from the window they
    // went behind it, and the welcome stopped answering.
    .modifier(SheetHost(isActive: !(showsPhoneWelcome && idiom == .phone)))
    #if os(iOS)
      // iPhone: the welcome is the first screen, full height, until "Open Vault" (the Mac and iPad show it inline).
      .fullScreenCover(isPresented: Binding(get: { showsPhoneWelcome && idiom == .phone }, set: { showsPhoneWelcome = $0 })) {
        WelcomeScreen(onOpen: {
          if !app.isDemo { welcomeOpened = true }
          showsPhoneWelcome = false
        })
        .modifier(SheetHost(isActive: true))
        .environment(app)
        .componentKit(accent: .vaultAccent)
        .preferredColorScheme(LaunchOptions.colorScheme)
      }
    #endif
    .modifier(SelectionFollower(compactColumn: $compactColumn))
    .onOpenURL { url in
      // Open in Vault: a PDF or picture goes to Add Document; anything else is an invite link.
      if url.isFileURL { app.importDocuments([url]) } else { app.sharing.open(url) }
    }
    // Documents shared from other apps while Vault wasn't running: read their pages on this device.
    .task(id: app.vault.documents.filter(\.needsReading).map(\.id)) { await app.readSharedDocuments() }
    .onChange(of: scenePhase) { _, phase in
      // Leaving the screen: ask for a background turn to check remotes (iPhone and iPad; nothing on the Mac).
      if phase == .background, !app.isDemo, !AppModel.isSandbox { AppModel.scheduleBackgroundRefresh() }
      if phase == .active, !app.isDemo, !AppModel.isSandbox { AppModel.moveSecrets() }
      // Back in front: check the remotes synced folders use.
      if phase == .active, !app.isDemo { app.folders.checkRemotes() }
    }
    // The menu commands act on the focused window's account.
    .focusedSceneValue(\.appModel, app)
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

/// The window's sheets. A modifier of its own: read in the window's body, the sheet (and the binding the kit's sheet
/// takes reads it when made) updated the whole split view each time it changed. `isActive` false leaves them to
/// another host (the iPhone's welcome while it covers the window).
private struct SheetHost: ViewModifier {
  var isActive: Bool
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom

  func body(content: Content) -> some View {
    // The kit's overlay on the Mac and iPad; the system sheet on iPhone, half height for the bottom sheets.
    content.kitSheet(item: Binding(get: { !isActive || app.sheet == .scanInvite && idiom == .phone ? nil : app.sheet }, set: { app.sheet = $0 })) { sheet in
      SheetContent(sheet: sheet)
        .presentationDetents(idiom == .phone && sheet.isBottomSheet ? [.medium, .large] : [.large])
    }
    #if os(iOS)
      // iPhone: the scanner fills the screen.
      .fullScreenCover(isPresented: Binding(get: { isActive && app.sheet == .scanInvite && idiom == .phone }, set: { if !$0 { app.sheet = nil } })) {
        ScanInviteSheet()
          .environment(app)
          .componentKit(accent: .vaultAccent)
      }
    #endif
  }
}

/// A new selection, or an item opened again (`AppModel.open`), shows the detail column (iPhone). A modifier of its own,
/// so a selection change updates it, not the window's body with the split view and both its columns.
private struct SelectionFollower: ViewModifier {
  @Binding var compactColumn: NavigationSplitViewColumn
  @Environment(AppModel.self) private var app

  func body(content: Content) -> some View {
    content
      .onChange(of: app.selection) { _, _ in compactColumn = .detail }
      .onChange(of: app.openCount) { _, _ in compactColumn = .detail }
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
    case .documents(let scope): DocumentsScreen(scope: scope)
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
    case .editHost(let id): EditHostSheet(hostID: id)
    case .editLogin(let id): EditLoginSheet(loginID: id)
    case .addRemote: AddRemoteSheet()
    case .syncFolder(let id): SyncFolderSheet(folderID: id)
    case .decrypt(let id): DecryptSheet(folderID: id)
    case .share(let id): ShareSheet(folderID: id)
    case .invite: InviteSheet()
    case .addDevice: InviteSheet(forDevice: true)
    case .addHub: AddHubSheet()
    case .scanInvite: ScanInviteSheet()
    case .autoFillPreview: AutoFillPreview()
    case .sharePreview: SharePreview()
    case .addDocument: AddDocumentSheet()
    case .editDocument(let id): AddDocumentSheet(editing: id)
    case .shareCopy(let id): ShareCopySheet(documentID: id)
    }
  }
}

/// The share sheet as the extension shows it for two pictures, from the demo documents' thumbnails. Add closes it
/// without saving.
private struct SharePreview: View {
  @Environment(AppModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss
  @State private var model = ShareModel()

  var body: some View {
    ShareView(model: model)
      .onAppear {
        model.files = app.vault.documents.filter { $0.thumbnail != nil }.prefix(2).enumerated().map { index, document in
          SharedFile(
            name: "IMG_04\(12 + index).jpeg", contentType: "public.jpeg", data: Data(), width: 1240, height: 1754,
            thumbnail: document.thumbnail)
        }
        model.isLoading = false
        model.add = { dismiss() }
        model.cancel = { dismiss() }
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
