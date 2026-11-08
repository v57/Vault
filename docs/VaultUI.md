# VaultUI

The vault's screens that every v57 app shows the same way, built on ComponentKit: the window's account and its picker,
Settings ▸ Accounts, Devices, Privacy's iCloud switch and Remote, the Your Name sheet, the question about a server's SSH
key on first contact, Lost Device, the import sheet for dropped folders and the shared projects list.

VaultUI holds views and the small request objects behind them. The data is [VaultKit](VaultKit.md)'s; VaultUI adds
no records of its own and nothing app-specific. It doesn't connect to Hubs ([VaultHub](VaultHub.md)) and, like every
ComponentKit view, its sheets are kit overlays, so they need ComponentKit's root modifier on the window.

## Getting started

```swift
.package(url: "https://github.com/v57/Vault.git", branch: "main"),
// in the target:
.product(name: "VaultUI", package: "Vault"),
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
| `\.vault`, `\.vaultAccountWindow` (environment) | The window's vault and its account switch; nil outside a scope. |
| `VaultAccountPicker(meta:style:)` | The account picker (ComponentKit's `KitAccountPicker`), first in the sidebar. |
| `VaultAccountSheet(account:done:)` | New Account, or editing one: name, colour, Apple developer teams. Present with `.kitSheet`. |
| `VaultAccountsSettings(vaults:)`, `VaultAccountsSheet()` | Settings ▸ Accounts; the same over a window for an app with no Settings window. |
| `VaultProfileRequest`, `.vaultProfileRequests(_:)` | `profile(for:vaults:reason:gitHub:)` returns the account's name and email, asking with the Your Name sheet only when they're missing. Call it right before the action that needs them, never at launch. `answer(...)` also asks a yes/no option (`VaultProfileOption`, `VaultProfileAnswer`). |
| `VaultProfileSheet` | The Your Name sheet itself, for editing a profile. |

### Devices and trust

| API | What it is |
|---|---|
| `VaultHostKeyRequest.shared`, `.vaultHostKeyRequests(_:)` | Before trusting a server's SSH key on first contact: `approve(_:keyType:for:in:)` for a `VaultHost`, `approve(_:keyType:host:port:in:)` for an address, `ask(name:address:port:fingerprint:keyType:)` for anything else. Returns whether the user trusted it, and pins the key on a yes. A key already trusted passes without asking; a different pinned key is refused without asking (the user clears it in Vault). Put the modifier inside `componentKit()` on every window that can start a connection. |
| `VaultDevicesSettings(vaults:)`, `VaultDevicesSettings(vaults:note:control:)` | The user's devices, this one first, with an optional control per row. |
| `VaultDeviceNameSheet(vault:device:)` | Renames this device (no `device`) or another one. |
| `VaultLostDeviceSheet(device:vaults:actions:)`, `VaultLostDeviceActions`, `VaultLostDeviceFlow` | Lost Device: each step runs at its own click. The app adds steps VaultUI can't reach (its Hubs, its SSH servers) as actions. |
| `VaultRemoteSettings(vaults:keys:)` | Settings ▸ Remote on the Mac: which of the user's devices may sign in to this Mac over SSH (`~/.ssh/authorized_keys`). macOS only. |

### Settings, folders and projects

| API | What it is |
|---|---|
| `VaultICloudCard()` | Settings ▸ Privacy's Use iCloud switch, shared by every v57 app on the device (`VaultICloud`). |
| `VaultFolderAccess.request(_:name:among:message:grants:)` | A folder ready to open: as it is without the sandbox, else with a remembered grant, else after the open panel (which starts on the folder around the app's projects). Nil when cancelled. |
| `VaultImportSheet(_:vault:app:alternative:decide:onAdd:)` | What a drop found that the vault doesn't have yet (projects, database files), offered before saving. |
| `VaultOtherPlacesMenu(root:)` | "On Other Devices": a project folder's places on the user's other devices that a Hub reaches. |
| `VaultProjectsSection(_:selection:layout:sort:key:collapsedGroups:content:menu:)` | The shared projects list in a `KitSidebar`, in the vault's groups, with the picked project's content below, in a list that folds away, or under its row (`VaultProjectsLayout`; order: `VaultProjectsSort`). Modifiers add the app's parts: `.title`, `.trailing`, `.rowSubtitle`, `.rowProgress`, `.icon`, `.rowMenu`, `.openWith`, `.removable`, `.accessory`, `.emptyState` and more. |

## Platform notes

| Platform | State |
|---|---|
| macOS 14 | Everything. |
| iOS/iPadOS 17 | Everything but `VaultRemoteSettings` (macOS only). `VaultFolderAccess` has no open panel there: it returns a folder only once granted. |
| Linux, Windows | Not built or tested. Vault's `Package.swift` adds v57/SwiftUI only to the other targets, so VaultUI relies on ComponentKit's own support for those platforms. |
| Android | Not built or tested. |

## Testing

```bash
swift test --filter VaultUITests
```

`VaultUITests` covers the request objects and flows, not drawing: `HostKeyRequestTests`, `LostDeviceFlowTests`,
`ProfileRequestTests`. They follow VaultKit's rule: `VaultSecrets.useInMemoryStore()` and a store on
`MemoryKeyProvider`, never the user's keychain. To see the screens, run the Vault app with `--demo` (see the repo's
README, "The Vault app").
