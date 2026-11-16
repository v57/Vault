# VaultUI

The vault's screens that every v57 app shows the same way, built on ComponentKit: the window's account and its picker,
Settings ▸ Accounts, Devices, Privacy's iCloud switch and Remote, the Your Name sheet, the question about a server's SSH
key on first contact, Lost Device, the import sheet for dropped folders, the shared projects list and the SSH agent's
panels.

## Purpose

VaultUI holds views and the small request objects behind them. The data is [VaultKit](VaultKit.md)'s; VaultUI adds
no records of its own and nothing app-specific, so an account, a device or a project looks and behaves the same in
every app.

It doesn't connect to Hubs ([VaultHub](VaultHub.md)), and, like every ComponentKit view, its sheets are kit overlays,
so they need ComponentKit's root modifier (`.componentKit()`) on the window.

## Platforms

<!-- platforms: macos ios linux=partial windows=partial -->

- **macOS 14**: everything.
- **iOS/iPadOS 17**: everything but the SSH agent's panels (`SSHAgentPanels`) and Settings ▸ Remote's SSH access:
  there `VaultRemoteSettings` lists the user's devices. `VaultFolderAccess` has no open panel: it returns a folder only
  once granted.
- **Linux, Windows**: builds, through ComponentKit on v57/SwiftUI (Git ships with it there). As on iOS,
  `VaultRemoteSettings` lists the devices only and there are no SSH agent panels. The iCloud card says the platform
  has no iCloud.
- **Android**: not built or tested.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Vault.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "VaultUI", package: "Vault")]),
]
```

VaultUI depends on VaultKit and ComponentKit (`https://github.com/v57/Component.git`; with `V57_LOCAL=1`, Vault's
`Package.swift` takes the `../Component` checkout).

```swift
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

@main struct NotesApp: App {
  init() { Vault.shared.startSync() }

  var body: some Scene {
    WindowGroup { MainWindow() }
    #if os(macOS)
      Settings { SettingsWindow() }   // on iPhone and iPad, show SettingsWindow from the app's own Settings button
    #endif
  }
}

struct SettingsWindow: View {
  @State private var pane = "Accounts"

  var body: some View {
    KitSettings(selection: $pane) {
      SettingsPane("Accounts", systemImage: "person.2", hue: .indigo, section: "v57") { VaultAccountsSettings() }
      SettingsPane("Privacy", systemImage: "hand.raised", hue: .blue) { VaultICloudCard() }
    }
    .componentKit()
  }
}

struct MainWindow: View {
  @SceneStorage("vault.account") private var accountID = VaultAccount.personal.id
  @State private var profiles = VaultProfileRequest()

  var body: some View {
    VaultAccountScope(selection: $accountID) { vault in
      HostList(vault: vault)                 // rebuilt for each account, so nothing of one shows in another
    }
    .vaultHostKeyRequests()                  // asks before trusting a server's key, in any window that connects
    .vaultProfileRequests(profiles)          // the Your Name sheet, when the app asks for a profile
    .componentKit()
  }
}

struct HostList: View {
  let vault: Vault

  var body: some View {
    List {
      VaultAccountPicker()                   // draws nothing while Personal is the only account
      ForEach(vault.hosts) { Text($0.name) }
    }
  }
}
```

## Main API

### Accounts and profiles

| API | What it is |
|---|---|
| `VaultAccountScope(selection:rebuildsContent:manage:openInNewWindow:content:)` | Put at a window's root: resolves the window's account to its vault, hands it to the content and to `@Environment(\.vault)`, and rebuilds the content when the account changes. `rebuildsContent: false` for a window whose work must survive a switch. |
| `\.vault`, `\.vaultAccountWindow` (environment) | The window's vault and its account switch (`VaultAccountWindow`); nil outside a scope. |
| `VaultAccountPicker(meta:style:)` | The account picker (ComponentKit's `KitAccountPicker`), first in the sidebar. |
| `VaultAccountSheet(account:done:)` | New Account (`account: nil`), or editing one: name, colour, Apple developer teams. Present with `.kitSheet`. |
| `VaultAccountsSettings(vaults:)`, `VaultAccountsSheet()` | Settings ▸ Accounts; the same over a window for an app with no Settings window. |
| `VaultProfileRequest`, `.vaultProfileRequests(_:)` | `profile(for:vaults:reason:gitHub:)` returns the account's name and email, asking with the Your Name sheet only when they're missing. Call it right before the action that needs them, never at launch. `answer(for:vaults:reason:gitHub:option:)` also asks a yes/no option (`VaultProfileOption`, `VaultProfileAnswer`). |
| `VaultProfileSheet(account:vaults:gitHub:reason:done:)` | The Your Name sheet itself, for editing a profile. |

```swift
@MainActor func commit(in vault: Vault, profiles: VaultProfileRequest) async {
  let account = Vaults.shared.account(id: vault.accountID) ?? .personal
  guard let profile = await profiles.profile(for: account, reason: "Commits are signed with your name and email.")
  else { return }                            // the user cancelled
  print(profile.signature ?? "")             // "Name <email>"
}
```

### Devices and trust

| API | What it is |
|---|---|
| `VaultHostKeyRequest.shared`, `.vaultHostKeyRequests(_:)` | Before trusting a server's SSH key on first contact: `approve(_:keyType:for:in:)` for a `VaultHost`, `approve(_:keyType:host:port:in:)` for an address, `ask(name:address:port:fingerprint:keyType:)` for anything else. Returns whether the user trusted it, and pins the key on a yes. A key already trusted passes without asking; a different pinned key is refused without asking (the user clears it in Vault). With no window showing the requests the answer is no, so put the modifier inside `componentKit()` on every window that can start a connection. |
| `VaultDevicesSettings(vaults:)`, `VaultDevicesSettings(vaults:note:control:)` | The user's devices, this one first, with an optional control per row. |
| `VaultDeviceNameSheet(vault:device:)` | Renames this device (no `device`) or another one. |
| `VaultLostDeviceSheet(device:vaults:actions:)`, `VaultLostDeviceActions`, `VaultLostDeviceFlow` | Lost Device: each step runs at its own click. The app adds steps VaultUI can't reach (its Hubs, its SSH servers) as actions. |
| `VaultRemoteSettings(vaults:keys:)` | Settings ▸ Remote on the Mac: which of the user's devices may sign in to this Mac over SSH (`~/.ssh/authorized_keys`). Elsewhere `VaultRemoteSettings(vaults:)` lists the devices. |

```swift
import SSHKit

// The trust for SSHKit's SSHServer: the question runs after the handshake, before any password or signature leaves.
@MainActor func trust(for host: VaultHost, in vault: Vault) -> SSHHostTrust {
  .known(vault.knownHost(for: host)?.fingerprint, otherwise: .ask { key in
    await VaultHostKeyRequest.shared.approve(key.fingerprint, keyType: key.type, for: host, in: vault)
  })
}
```

### Settings, folders and projects

| API | What it is |
|---|---|
| `VaultICloudCard()` | Settings ▸ Privacy's Use iCloud switch, shared by every v57 app on the device (`VaultICloud`). |
| `VaultFolderAccess.request(_:name:among:message:grants:)` | A folder ready to open: as it is without the sandbox, else with a remembered grant, else after the open panel (which starts on the folder around the app's projects). Nil when cancelled. |
| `VaultImportSheet(_:vault:app:alternative:decide:onAdd:)` | What a drop found that the vault doesn't have yet (projects, database files), offered before saving. It adds the projects with one `addProjects` call. |
| `VaultOtherPlacesMenu(root:)` | "On Other Devices": a project folder's places on the user's other devices that a Hub reaches, each with an SSH command. |
| `VaultProjectsSection(_:selection:layout:sort:key:collapsedGroups:content:menu:)` | The shared projects list in a `KitSidebar`, in the vault's groups, with the picked project's content below the list, below a list that folds away, or under its row (`VaultProjectsLayout`: `separate`, `folding`, `inline`; order: `VaultProjectsSort`). The user's layout and order are kept under `key`. Without `content:` it's the list alone. |
| `RelativeTimeSchedule(_:)` | A `TimelineView` schedule that redraws a "3 min ago" line only when its text changes. |

Several projects can be picked together, as in Finder: ⌘-click adds one or takes it out, ⇧-click picks the range from
the last click, ⇧⌘-click adds that range. The picked rows are tinted and their context menu acts on them all (Copy
Paths, Remove from List, and the app's `selectionMenu` items); the project shown stays the one last clicked plainly.

Modifiers add the app's parts: `.title`, `.recent`, `.trailing`, `.rowSubtitle`, `.rowProgress`, `.rowDimmed`,
`.rowContent`, `.icon`, `.rowMenu`, `.selectionMenu`, `.openWith`, `.projectHeader`, `.removable`, `.renamableGroups`,
`.groupTrailing`, `.groupStatus`, `.groupHelp`, `.groupMenu`, `.accessory`, `.emptyState`, `.isExpanded`,
`.contentSticky`.

```swift
struct Projects: View {
  let vault: Vault
  @State private var projectID: String?
  @State private var collapsed: Set<String> = []
  @State private var hidden: Set<String> = []

  var body: some View {
    VaultProjectsSection(
      vault.localProjectTree.filter { !hidden.contains($0.id) }, selection: $projectID, layout: .inline,
      collapsedGroups: $collapsed
    ) { project in
      Text(project.localPath ?? "")            // the picked project's rows
    } menu: {
      EmptyView()                              // the app's own items in the header's menu
    }
    .rowSubtitle { $0.remoteURL }
    .selectionMenu { projects in               // the context menu of several picked projects
      Button("Hide \(projects.count) Projects") { hidden.formUnion(projects.map(\.id)) }
    }
    .removable { ids in hidden.formUnion(ids) } // Remove from List, Remove All Projects from List
  }
}
```

### SSH agent (macOS)

| API | What it is |
|---|---|
| `SSHAgentPanels.install(_:accent:openAgent:)` | Hooks VaultKit's `VaultSSHAgent` into the app: the request panel (who asked, the server, a warning for an AI agent, then Deny or Touch ID), the offer when something asked while the agent was off, and closing the socket on quit. The panels float over every app without taking focus. |
| `SSHAgentPanels.turnOn(_:for:)`, `SSHAgentPanels.bringForward()` | Turns the agent on, then asks once whether ssh in Terminal should use it; brings the app forward. |

## Testing

```bash
swift test --filter VaultUITests
```

`VaultUITests` covers the request objects and flows, not drawing: `HostKeyRequestTests`, `LostDeviceFlowTests`,
`ProfileRequestTests`, `ProjectClicksTests` (picking several projects) and `RelativeTimeScheduleTests`. They follow
VaultKit's rule: `VaultSecrets.useInMemoryStore()` and a store on `MemoryKeyProvider`, never the user's keychain. To
see the screens, run the Vault app with `--demo` (see the repo's README, "The Vault app").

## Related

- [VaultKit](VaultKit.md): the accounts, devices, hosts and projects these screens show.
- [VaultHub](VaultHub.md): the Hub steps an app adds to Lost Device.
- ComponentKit (`https://github.com/v57/Component`): the design these screens are built with.
