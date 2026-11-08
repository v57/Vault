# VaultKit

The encrypted store every v57 app shares: projects, SSH hosts, database connections, known hosts, device keys,
logins, cards, notes, documents, folders, people, Hubs and accounts, with their secrets in the keychain and sync
through the user's iCloud.

VaultKit is a model and storage library. It has no views (those are in [VaultUI](VaultUI.md)), it doesn't connect to
a Hub (that's [VaultHub](VaultHub.md)), and it doesn't encrypt folders on disk (that's [VaultFiles](VaultFiles.md)).
The design (one store per device, the merge, encryption, the keychain groups, CloudKit, key epochs) is described in
the README's [How it works](../README.md#how-it-works); this page is about using the API.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Vault.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "VaultKit", package: "Vault")]),
]
```

To build against a `Vault` checkout next to your app instead of GitHub, the v57 apps use a `<App>-Local.xcworkspace`
that lists `../Vault` (Xcode's local-package override). Vault's own `Package.swift` reads `V57_LOCAL=1` to take its
dependencies (Hub's SDK, ComponentKit, and v57/SwiftUI on Linux and Windows) from the checkouts next to it. On Apple
platforms VaultKit depends on nothing outside the package.

### Reading and writing

`Vault.shared` is the Personal vault: an `@Observable` model on the main actor whose arrays reload whenever any app
on the device writes.

```swift
import SwiftUI
import VaultKit

@main struct MyApp: App {
  init() { Vault.shared.startSync() }   // iCloud sync, when the user is signed in and has it on

  var body: some Scene {
    WindowGroup { HostList() }
  }
}

struct HostList: View {
  @State private var vault = Vault.shared

  var body: some View {
    List(vault.hosts) { host in Text(host.name) }   // changes from other apps and devices appear here
      .toolbar {
        Button("Add") { vault.save(VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy")) }
      }
  }
}
```

`Vault.save(_:)` and `Vault.delete(_:)` report failures in `vault.error`. For writes that should throw, use the
store: `try vault.store?.save(record)`, `try vault.store?.addProject(path:name:remoteURL:)`. Passwords never go in
records: `try VaultSecrets.setPassword(password, for: database.id)`.

### What the app must declare

Taken from the README's [What each app declares](../README.md#what-each-app-declares) and `VaultConfiguration`:

| Entitlement | Value |
|---|---|
| `com.apple.security.application-groups` | `$(TeamIdentifierPrefix)dev.v57` (macOS), `group.dev.v57` (iOS): the store's folder |
| `keychain-access-groups` | `$(AppIdentifierPrefix)dev.v57.shared`; Vault and its AutoFill extension also `$(AppIdentifierPrefix)dev.v57.secrets` |
| `com.apple.developer.icloud-container-identifiers` | `iCloud.dev.v57` |
| `com.apple.developer.icloud-services` | `CloudKit` |
| `com.apple.developer.icloud-container-environment` | `Production`, in debug builds too |
| `com.apple.developer.aps-environment` (`aps-environment` on iOS) | `development` / `production`, for sync pushes |

`VaultConfiguration` names two more keychain groups: `recordsGroup` (`dev.v57.records`, for apps that read the
records but hold no secrets: Get, Player, Hub) and `deviceGroup` (`dev.v57.device`, this device's Hub keys, listed only
by Vault and the Hub app). An app outside those roles doesn't list them.

All groups are team-prefixed, and `VaultConfiguration.teamID` is the v57 team's, so a build signed by another team
can't share the v57 apps' store. It still runs: the store falls back to the app's own Application Support, and sync
stays off. A Release build with no application identifier (ad-hoc signed) refuses the keychain
(`VaultKeychain.isAvailable` is false and every keychain call throws); a Debug build uses the old file keychain.

## Main API

### The vault model

| API | What it is |
|---|---|
| `Vault` | The observable model for one account's store: `projects`, `projectGroups`, `projectTree`, `hosts`, `databases`, `deviceKeys`, `knownHosts`, `logins`, `cards`, `documents`, `folders`, `remotes`, `people`, `hubs`, `accounts`, `profiles`, plus `error`, `store` and `sync`. |
| `Vault.shared` | The Personal vault. `Vault(store:accountID:)` opens another (tests pass a store of their own). |
| `startSync()`, `reload(force:)` | Start iCloud sync once from the app's init (Personal only; it carries every account); reload by hand. |
| `save(_:)`, `delete(_:)`, `perform(_:)` | Write a record, remove one, or run several changes on the store and reload once. |
| `localProjects`, `localProjectTree` | Projects with a folder on this device; the same in the user's groups. |
| `hubHosts`, `deviceHosts`, `otherDeviceHosts`, `host(id:)`, `knownHost(for:)` | Hosts reached through a Hub or published by a Mac, a host by id, the pinned key for an address. |
| `renameDevice`, `revokeDevice`, `removeDevice` | Device management, as the Vault app's Devices list does it. |
| `findProjectIcons(...)` | Keeps the small project icons (`VaultProject.icon`) current; apps pass Code's `ProjectIcon` functions. |
| `personalVault` | The Personal vault from an account's: Hubs and device hosts live there. |

### Accounts

| API | What it is |
|---|---|
| `Vaults.shared` | Every account's vault: `personal`, `accounts`, `allAccounts`, `vault(for:)`, `createAccount(name:color:)`, `delete(_:hubs:)`, `rotateKeys()`, `account(forTeam:)`, `account(forGitHubOwner:)`, `profile(for:)`. |
| `VaultAccount`, `VaultAccount.personal` | An account (an organization the user works for), each with its own store and keys. |
| `VaultProfile` | Who the user is in an account: name and email. [VaultUI](VaultUI.md)'s `VaultProfileRequest` asks for it. |

The README's Accounts and Profiles paragraphs describe how accounts are kept apart.

### The store

`VaultStore` is the SQLite file underneath. Apps rarely make one: `Vault` opens `VaultStore.shared`.

| API | What it is |
|---|---|
| `VaultStore(directory:fileName:accountID:keys:deviceID:notifier:owner:)` | Opens or creates a store. Every parameter has a default (`VaultConfiguration.defaultDirectory()`, `VaultStore.defaultKeys()`, `VaultDevice.id`, `SystemChangeNotifier()`). |
| `records(_:)`, `record(_:id:)` | Typed records of one kind; one by id. |
| `save(_:)`, `delete(_:)`, `delete(id:)` | Saves only the fields that changed (returns whether anything did); fields this build doesn't know are kept. |
| `items(kind:)`, `item(id:)`, `save(id:kind:changes:)` | The same on raw fields (`[String: JSONValue]`), for code that has no record type. |
| `addProject(path:name:remoteURL:)`, `addProjectGroup(...)`, `moveProjects`, `groupProjects`, `ungroupProjects` | Projects and their groups. |
| `trust(fingerprint:for:keyType:)`, `knownFingerprint(for:)`, `untrust` | Pinned SSH host keys (`VaultKnownHost`). |
| `setPassword(_:forLogin:now:)`, `setOneTimeCode`, `setCardNumber`, `setCardCode` | A login's or card's secret, with the record's change stamps. |
| `revision` | Grows with every change; cheap to compare. |

### Records

Every record type conforms to `VaultRecord` (`kind`, `init(id:values:)`, `values`); add a type of your own the same
way. Records are value types; change one and save it.

| Record | Holds |
|---|---|
| `VaultProject`, `VaultProjectGroup`, `VaultProjectTree` | A project (path per device, remote URL, kinds, icon) and the groups it sits in. |
| `VaultHost`, `VaultKnownHost`, `VaultDeviceKey` | An SSH host (with Hub and device routes, a jump host, build signing), a pinned host key, a device's public SSH key. |
| `VaultDatabase` | A database connection (engine, host, port, user, database). |
| `VaultLogin`, `VaultCard`, `VaultPasskey` | Logins with one-time codes, cards, passkeys. Their secrets are in `VaultSecrets`. |
| `VaultNote` | A note (folder, name, text, whether its file is encrypted). |
| `VaultDocument` | A scanned or imported document with its files. |
| `VaultFolder`, `VaultRemote` | An encrypted or synced folder (its key wrapped by the vault key, path, mode and storage per device), and a remote it syncs through. |
| `VaultPerson`, `VaultInvite` | Someone the user shares with, and an invite. |
| `VaultHubServer` | A Hub the user added, and which devices connect to it. |
| `VaultAccount`, `VaultProfile`, `VaultGitSettings`, `VaultProjectPreset` | Accounts and per-account settings. |
| `VaultRevokedDevice`, `VaultRecoveryKey`, `VaultRecoveryBlob` | A revoked device; the recovery key's records. |

### Secrets and keys

| API | What it is |
|---|---|
| `VaultSecrets` | Passwords and other secrets by item id: `password(for:)`, `setPassword(_:for:)`, `loginPassword(for:)`, `setLoginPassword`, `secret(_:)`, `setSecret(_:named:)`, `secretText`, `setSecretText`, `deleteSecrets(forItem:)`. `useInMemoryStore()` keeps them in memory for the rest of the process. |
| `VaultKeychain(service:accessGroup:)` | The keychain wrapper behind them; `isAvailable` says whether this build can use it. |
| `KeychainKeyProvider`, `MemoryKeyProvider` | The vault's AES keys: from the keychain, or made in memory (tests, previews, demos). Both are `VaultKeyProvider`s. |
| `VaultCrypto` | Seals and opens data with the vault keys. |
| `VaultIdentity` | This device's SSH key in the Secure Enclave: `key()`, `exists`, `publicKeyLine(_:comment:)`, `fingerprint(blob:)`, signing, and the presence check (`confirmPresence(reason:)`). |
| `VaultDevice` | This device: `id`, `name`, `addresses`. |
| `VaultPersonalIdentity`, `PersonalIdentity`, `PublicIdentity` | The person's own keys for sharing (X25519 and Ed25519), `current()` makes it on first use; the shareable public half (`v57id:`). |
| `SafetyCode`, `KeyWrap` | The code two people compare; a key sealed to a person. |
| `VaultRecovery`, `RecoveryKit`, `VaultBackup`, `VaultAppLock` | The optional recovery key, backups, and the app lock. |

### Sync and change notifications

| API | What it is |
|---|---|
| `CloudSync` | The `CKSyncEngine` adapter `startSync()` creates: `start()`, `syncNow()`, `isEntitled`, `isRunning`. |
| `HubSync`, `HubMailbox` | Record sync through a Hub's `hub-vault` service, for devices without iCloud. [VaultHub](VaultHub.md) wires it up. |
| `VaultICloud` | The device's Use iCloud switch, shared by every v57 app: `isSupported`, `isOff`, `setOff(_:)`. `VaultICloudStatus.shared` observes it. |
| `VaultChangeObserver`, `VaultChangeNotifier`, `SystemChangeNotifier` | The notification posted after every write (`VaultConfiguration.changeNotification`); `Vault` already observes it. |
| `VaultConfiguration` | The identifiers: `appGroup`, `keychainGroup`, `secretsGroup`, `recordsGroup`, `deviceGroup`, `cloudContainer`, `notesContainer`, `changeNotification`, `defaultDirectory()`. |

### Sandbox and folders

| API | What it is |
|---|---|
| `AppSandbox` | Whether the app runs sandboxed (`isOn`), its `supportDirectory` and `documentsDirectory`, and `carryOverContainer()` (call first thing at launch). |
| `FolderGrants` | Folders the user let a sandboxed Mac app open (security-scoped bookmarks). [VaultUI](VaultUI.md)'s `VaultFolderAccess.request` asks for one. |

See the README's [With and without the sandbox](../README.md#with-and-without-the-sandbox).

### Remote storage

| API | What it is |
|---|---|
| `RemoteFileSystem` | Plain storage: `list`, `stat`, `read(_:range:)`, `write(_:to:)`, `createDirectory`, `rename`, `delete`. [VaultSync](VaultSync.md) syncs folders over it. |
| `MemoryRemoteFileSystem`, `LocalRemoteFileSystem(root:)` | In memory (tests), a local folder. |
| `S3FileSystem`, `S3Configuration`, `S3Transport`, `URLSessionS3Transport` | S3-compatible storage (AWS S3, R2, B2, MinIO), with an injectable transport. |
| `RemoteConnections.fileSystem(for:secret:transport:)` | The file system for a `VaultRemote` record; nil for kinds without a backend yet (SFTP, SMB, FTP, iCloud). |

### Passwords, passkeys and notes

| API | What it is |
|---|---|
| `OneTimeCode`, `Base32` | TOTP and HOTP codes, `otpauth://` URLs. |
| `PasswordGenerator`, `PasswordStrength` | Generated passwords and a strength estimate. |
| `WebAuthn`, `VaultAutoFill` | Passkey signatures; which logins fit a site and what the system's AutoFill list shows. |
| `NotesMirror`, `EncryptedNote`, `TextMerge`, `NoteConflicts` | Notes as files (Markdown and Shell), their encryption, and line merges. |

## Platform notes

| Platform | State |
|---|---|
| macOS 14, iOS/iPadOS 17 | Everything. iCloud sync needs the entitlements above and an iCloud account. |
| Linux | Builds; VaultKit's tests pass on Ubuntu 24.04. Keychain items go to the freedesktop Secret Service (login keyring), note ids to extended attributes (the `CVaultLinux` target), CryptoKit and SQLite3 come from v57/SwiftUI. No iCloud. |
| Windows | Builds; the tests build. Keychain items go to the Credential Manager, a large item split into pieces. Changes are announced through a change file. No iCloud. |
| Android | Not built or tested here. There is no keychain backend: Debug keeps items in a 0600 JSON file, Release throws. |
| tvOS, visionOS | Not declared in `Package.swift`. |

On Linux and Windows any program of the user can read the secrets, as with other password stores there; the README's
[What each app declares](../README.md#what-each-app-declares) has the full table. Records can sync between devices
without iCloud through a Hub (`HubSync`).

## Testing

```bash
swift test                    # merge, store, sync with a fake CloudKit, notes
swift build --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
```

Tests never touch the user's keychain or store. Call `VaultSecrets.useInMemoryStore()` before anything else (it
keeps both the secrets and the personal identity in memory), and open the store with `MemoryKeyProvider` in a
temporary folder:

```swift
import Foundation
import Testing
import VaultKit

@Test func savesAHost() throws {
  VaultSecrets.useInMemoryStore()
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let store = try VaultStore(directory: directory, keys: MemoryKeyProvider(), deviceID: "mac", notifier: nil, owner: "test")
  try store.save(VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy"))
  #expect(try store.records(VaultHost.self).map(\.name) == ["prod"])
}
```

With secrets in memory, `VaultConfiguration.defaultDirectory()` is a temporary folder too, so even `Vault.shared` in
a test or a demo run can't write to the user's store. In a Debug build, `VAULT_DIRECTORY` points the store at a folder
of your choice (a second "device" on one Mac).

VaultKit's own tests have fakes in `Tests/VaultKitTests/Support/`: `FakeCloud` (several devices and apps against one
fake CloudKit; the sync rules live in `SyncCoordinator` so they can run against it), `FakeS3`, `FakeDatabase` and
`FlakyKeys`. They are test-only, not part of the library. `MemoryRemoteFileSystem` is public.

Rules for changes to VaultKit, from the repo's CLAUDE.md: the record format never changes in place, saves write only
changed fields and never drop unknown ones, and nothing adds a helper process.
