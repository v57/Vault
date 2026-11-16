# VaultKit

The encrypted store every v57 app shares: projects, SSH hosts, database connections, known hosts, device keys,
logins, cards, notes, documents, folders, people, Hubs and accounts, with their secrets in the keychain and sync
through the user's iCloud.

## Purpose

VaultKit is a model and storage library. Every app on a device opens the same SQLite store, sees the other apps'
writes within a second, and syncs through the user's own iCloud: records are sealed with the vault keys before they
leave the device, and passwords and other secrets never go in records at all (they live in the keychain).

It has no views (those are in [VaultUI](VaultUI.md)), it doesn't connect to a Hub (that's [VaultHub](VaultHub.md)),
it doesn't encrypt folders on disk (that's [VaultFiles](VaultFiles.md)) and it doesn't sync folders
([VaultSync](VaultSync.md)). It never starts a helper process: each app syncs on its own while it runs. The design
(one store per device, the merge, encryption, the keychain groups, CloudKit, key epochs) is described in the README's
[How it works](../README.md#how-it-works); this page is about using the API.

## Platforms

<!-- platforms: macos ios linux=partial windows=partial -->

- **macOS 14, iOS/iPadOS 17**: everything. iCloud sync needs the entitlements below and an iCloud account. The SSH
  agent (`VaultSSHAgent`), `VaultAuthorizedKeys.user` and `VaultSSHDConfig` are macOS only.
- **Linux**: builds, and VaultKit's tests pass on Ubuntu 24.04. Keychain items go to the freedesktop Secret Service
  (the login keyring), note ids to extended attributes (the `CVaultLinux` target), and CryptoKit and SQLite3 come from
  v57/SwiftUI. This device's SSH key is v57/SwiftUI's stand-in for the Secure Enclave: a software key sealed to the
  user (AES-GCM under a key kept in the Secret Service), in memory while it's used.
- **Windows**: builds; the tests build. Keychain items go to the Credential Manager, a large item split into pieces.
  The device's SSH key is sealed with DPAPI. Changes are announced through a change file in the temporary folder
  instead of a Darwin notification.
- **Linux and Windows** have no iCloud (`CloudSync` keeps the same API and never runs), no app lock (`VaultAppLock`
  always unlocks) and no system AutoFill list. Records can still sync between devices through a Hub (`HubSync`).
  There are no keychain groups there, so **any program of the user can read the secrets**, as with other password
  stores on those systems; the README's [What each app declares](../README.md#what-each-app-declares) has the table.
- **Android**: not built or tested here. There is no keychain backend: a Debug build keeps items in a 0600 JSON file,
  a Release build throws.
- tvOS and visionOS aren't declared in `Package.swift`.

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

From the README's [What each app declares](../README.md#what-each-app-declares) and `VaultConfiguration`:

| Entitlement | Value |
|---|---|
| `com.apple.security.application-groups` | `$(TeamIdentifierPrefix)dev.v57` (macOS), `group.dev.v57` (iOS): the store's folder |
| `keychain-access-groups` | `$(AppIdentifierPrefix)dev.v57.records` in every app; `$(AppIdentifierPrefix)dev.v57.shared` in every app that connects to something (an app that only reads records, like Get and Player, leaves it out) |
| `com.apple.developer.icloud-container-identifiers` | `iCloud.dev.v57` |
| `com.apple.developer.icloud-services` | `CloudKit` |
| `com.apple.developer.icloud-container-environment` | `Production`, in debug builds too |
| `com.apple.developer.aps-environment` (`aps-environment` on iOS) | `development` / `production`, for sync pushes |

What the keychain groups hold (`VaultConfiguration`):

- `keychainGroup` (`dev.v57.shared`): the vault keys, the passwords apps log in with (hosts, databases, remotes), the
  device's SSH key and the GitHub token.
- `recordsGroup` (`dev.v57.records`): a copy of the vault keys and this device's id, for apps that read the records
  but hold no secrets. Apps in the shared group keep it current.
- `secretsGroup` (`dev.v57.secrets`): login passwords, one-time codes, cards, passkeys and the personal identity. Only
  Vault and its AutoFill extension list it.
- `deviceGroup` (`dev.v57.device`): this device's Hub keys. Only Vault and the Hub app list it.

All groups are team-prefixed, and `VaultConfiguration.teamID` is the v57 team's, so a build signed by another team
can't share the v57 apps' store. It still runs: the store falls back to the app's own Application Support, and sync
stays off. A Release build with no application identifier (ad-hoc signed) refuses the keychain
(`VaultKeychain.isAvailable` is false and every keychain call throws); a Debug build uses the old file keychain.

## Main API

### The vault model

| API | What it is |
|---|---|
| `Vault` | The observable model for one account's store (`@MainActor`): `projects`, `projectGroups`, `projectTree`, `projectPresets`, `hosts`, `databases`, `deviceKeys`, `knownHosts`, `logins`, `passkeys`, `cards`, `documents`, `documentCollections`, `holders`, `folders`, `remotes`, `people`, `hubs`, `accounts`, `appleTeams`, `profiles`, `gitSettings`, plus `error`, `revision`, `lastSynced`, `store` and `sync`. |
| `Vault.shared` | The Personal vault. `Vault(store:accountID:)` opens another (tests pass a store of their own). |
| `startSync()`, `reload(force:)` | Start iCloud sync once from the app's init (Personal only; it carries every account); reload by hand. |
| `save(_:)`, `delete(_:)`, `perform(_:)` | Write a record, remove one, or run several changes on the store and reload once. |
| `deviceID`, `localProjects`, `localProjectTree`, `localFolders` | This device's id; the projects and folders with a path on this device, the projects in the user's groups. |
| `host(id:)`, `folder(id:)`, `remote(id:)`, `hub(id:)`, `passkeys(forLogin:)` | Look-ups by id. |
| `hubHosts`, `deviceHosts`, `otherDeviceHosts`, `thisDeviceHost`, `knownHost(for:)`, `addresses(of:)` | Hosts reached through a Hub or published by a Mac, the pinned key for a host, every address a host may answer on. |
| `renameDevice(_:to:)`, `revokeDevice(_:)`, `trustAgain(_:)`, `removeDevice(_:)` | Device management, as the Vault app's Devices list does it. `appKeys`, `untrustedDeviceKeys` and `revokedDevices` list the rest. |
| `setStatus(_:ofProjectAt:)` | Keeps a repository's state (`VaultProject.Status`: branch, changes, ahead and behind, last commit and push) in its project for the user's other devices; writes only when it changed. |
| `findProjectIcons(with:thumbnail:)` | Keeps the small project icons (`VaultProject.icon`) current; apps pass Code's `ProjectIcon` functions. |
| `personalVault` | The Personal vault from an account's: Hubs and device hosts live there. |

```swift
@MainActor func moveToPort2222(_ id: String, in vault: Vault) {
  guard var host = vault.host(id: id) else { return }
  host.port = 2222
  vault.save(host)                       // only the changed field is written
  if let error = vault.error { print(error) }
}
```

### Accounts

| API | What it is |
|---|---|
| `Vaults.shared` | Every account's vault (`@MainActor`): `personal`, `accounts`, `allAccounts`, `account(id:)`, `vault(for:)`, `createAccount(name:color:)`, `save(_:)`, `delete(_:hubs:)`, `rotateKeys()`, `account(forTeam:)`, `account(forGitHubOwner:)`, `profile(for:)`. |
| `VaultAccount`, `VaultAccount.personal` | An account (an organization the user works for), each with its own store, CloudKit zone and Hub mailbox, sealed with the same vault keys. |
| `VaultProfile` | Who the user is in an account: name and email (`signature`, `gitEnvironment`). [VaultUI](VaultUI.md)'s `VaultProfileRequest` asks for it. |

```swift
@MainActor func vault(forRepositoryOwner owner: String) -> Vault {
  let vaults = Vaults.shared
  guard let account = vaults.account(forGitHubOwner: owner) else { return vaults.personal }
  return vaults.vault(for: account) ?? vaults.personal
}
```

The README's Accounts and Profiles paragraphs describe how accounts are kept apart.

### The store

`VaultStore` is the SQLite file underneath. Apps rarely make one: `Vault` opens `VaultStore.shared`, which code off
the main actor can use too.

| API | What it is |
|---|---|
| `VaultStore(directory:fileName:accountID:keys:deviceID:notifier:owner:)` | Opens or creates a store. Every parameter has a default (`VaultConfiguration.defaultDirectory()`, `VaultStore.defaultKeys()`, `VaultDevice.id`, `SystemChangeNotifier()`). |
| `records(_:)`, `record(_:id:)` | Typed records of one kind; one by id. |
| `save(_:)`, `delete(_:)`, `delete(id:)` | Saves only the fields that changed (returns whether anything did); fields this build doesn't know are kept. |
| `items(kind:)`, `item(id:)`, `save(id:kind:changes:)` | The same on raw fields (`[String: JSONValue]`), for code that has no record type. |
| `addProject(path:name:remoteURL:)`, `addProjects(_:)`, `removeProject(path:)` | Adds a folder on this device as a project (or this device's path to the same checkout added elsewhere). `addProjects` takes many `VaultProjectFolder`s against one read of the projects. |
| `arrangeProjects(_:roots:into:before:)` | Puts dropped repositories into groups named after the folders between a root and them. |
| `addProjectGroup(name:note:path:in:before:)`, `moveProjects(_:into:before:)`, `moveProjectsOut(_:)`, `groupProjects(_:name:note:)`, `ungroupProjects(_:)`, `projectTree()` | Projects' groups. |
| `trust(fingerprint:for:keyType:)`, `trust(fingerprint:host:port:keyType:)`, `knownFingerprint(for:)`, `knownFingerprint(host:port:)`, `untrust(fingerprint:for:)` | Pinned SSH host keys (`VaultKnownHost`), for a saved host or a bare address. |
| `setPassword(_:forLogin:now:)`, `setOneTimeCode(_:forLogin:now:)`, `setCardNumber(_:forCard:)`, `setCardCode(_:forCard:)`, `deleteLogin(id:)`, `deleteCard(id:)` | A login's or card's secret, with the record's change stamps. |
| `markDeviceSeen(now:model:calendar:)` | Notes in this device's key when it last ran a v57 app (`VaultDeviceKey.lastSeen`); `startSync()` calls it. |
| `revision` | Grows with every change; cheap to compare. |

```swift
// A folder of repositories dropped on the app: one read of the projects, then groups for the folders in between.
func addCheckouts(_ paths: [String], under root: String) throws {
  guard let store = VaultStore.shared else { return }
  try store.addProjects(paths.map { VaultProjectFolder(path: $0) })
  try store.arrangeProjects(paths, roots: [root])
}
```

### Records

Every record type conforms to `VaultRecord` (`kind`, `init(id:values:)`, `values`); add a type of your own the same
way. Records are value types; change one and save it.

| Record | Holds |
|---|---|
| `VaultProject`, `VaultProjectGroup`, `VaultProjectTree` | A project (path per device, remote URL, kinds, icon, each device's repository status) and the groups it sits in. |
| `VaultHost`, `VaultKnownHost`, `VaultDeviceKey` | An SSH host (with Hub and device routes, a jump host, build signing), a pinned host key, a device's public SSH key (with its model and when it was last seen). |
| `VaultDatabase` | A database connection (engine, host, port, user, database, an SSH host to tunnel through). |
| `VaultLogin`, `VaultCard`, `VaultPasskey` | Logins with one-time codes, cards, passkeys. Their secrets are in `VaultSecrets`. |
| `VaultNote` | A note (folder, name, text, whether its file is encrypted). |
| `VaultDocument`, `VaultDocumentCollection`, `VaultHolder` | A scanned or imported document with its files, the collections it's in, whose it is. |
| `VaultFolder`, `VaultRemote` | An encrypted or synced folder (its key wrapped by the vault key, path, mode and storage per device), and a remote it syncs through. |
| `VaultPerson`, `VaultInvite` | Someone the user shares with, and an invite. |
| `VaultHubServer`, `VaultHubDevice` | A Hub the user added and which devices connect to it; a device a Hub knows. |
| `VaultAccount`, `VaultAppleTeam`, `VaultProfile`, `VaultGitSettings`, `VaultProjectPreset` | Accounts and per-account settings. |
| `VaultRevokedDevice`, `VaultRecoveryKey`, `VaultRecoveryBlob` | A revoked device; the recovery key's records. |

```swift
struct Bookmark: VaultRecord {
  static let kind = "bookmark"
  var id: String
  var url: String

  init(id: String = UUID().uuidString, url: String) {
    self.id = id
    self.url = url
  }

  init(id: String, values: [String: JSONValue]) {
    self.id = id
    url = values["url"]?.stringValue ?? ""
  }

  var values: [String: JSONValue] { ["url": .string(url)] }
}
```

### Secrets and keys

| API | What it is |
|---|---|
| `VaultSecrets` | Passwords and other secrets by item id: `password(for:)`, `setPassword(_:for:)`, `loginPassword(for:)`, `setLoginPassword(_:for:)`, `secret(_:)`, `setSecret(_:named:)`, `secretText(_:)`, `setSecretText(_:named:)`, `deleteSecrets(forItem:)`. `useInMemoryStore()` keeps them in memory for the rest of the process. |
| `VaultSecretTiers` | Where each secret goes. A login's password, one-time codes, cards, passkeys and a document's secret fields are Vault's own: an app outside the secrets group reads them as nil (never "there's none") and a write there throws `TierError.vaultOnlyHere`. |
| `VaultKeychain(service:accessGroup:)` | The keychain wrapper behind them; `isAvailable` says whether this build can use it. |
| `KeychainKeyProvider`, `MemoryKeyProvider` | The vault's AES-256 keys: from the keychain, or made in memory (tests, previews, demos). Both are `VaultKeyProvider`s. |
| `VaultCrypto` | Seals and opens data with the vault keys (AES-GCM). |
| `VaultIdentity` | This device's SSH key, a P-256 key in the Secure Enclave on Apple platforms: `key()`, `exists`, `publicKeyLine(_:comment:)`, `fingerprint(blob:)`, `signature(for:key:)`, and the presence check (`confirmPresence(reason:)`). A key made since 2026-11-04 signs only after Touch ID, Face ID or the password, where the device has one; `key()` and `signature(for:key:)` never ask. |
| `VaultDevice` | This device: `id`, `name`, `model`, `addresses`. |
| `VaultPersonalIdentity`, `PersonalIdentity`, `PublicIdentity` | The person's own keys for sharing (X25519 and Ed25519); `current()` makes it on first use and, outside Vault and its AutoFill extension, throws. The shareable public half reads as `v57id:…`. |
| `SafetyCode`, `KeyWrap` | The 60-digit code two people compare; a key sealed to a person (X25519, HKDF-SHA256, AES-256-GCM). |
| `VaultRecovery`, `RecoveryKit`, `VaultBackup`, `VaultAppLock` | The optional recovery key, backups, and the app lock. |

```swift
func saveDatabasePassword(_ password: String, for database: VaultDatabase) throws {
  try VaultSecrets.setPassword(password, for: database.id)   // the keychain, never the record
}
// Later, in any app on any of the user's devices: database.password
```

### Sync and change notifications

| API | What it is |
|---|---|
| `CloudSync` | The `CKSyncEngine` adapter `startSync()` creates: `start()`, `syncNow()`, `isEntitled`, `isRunning`, `lastSynced`, `lastError`. |
| `HubSync`, `HubMailbox` | Record sync through a Hub's `hub-vault` service, for devices without iCloud: the Hub only carries records sealed under a vault key. [VaultHub](VaultHub.md) wires it up. |
| `VaultICloud` | The device's Use iCloud switch, shared by every v57 app: `isSupported`, `isOff`, `setOff(_:)`. `VaultICloudStatus.shared` observes it. |
| `VaultBackgroundRefresh` | On iPhone and iPad, asks the system for a later turn in the background (`identifier`, used with SwiftUI's `.backgroundTask(.appRefresh(_:))`); nothing elsewhere. |
| `VaultChangeObserver`, `VaultChangeNotifier`, `SystemChangeNotifier` | The notification posted after every write (`VaultConfiguration.changeNotification`); `Vault` already observes it. |
| `VaultConfiguration` | The identifiers: `teamID`, `appGroup`, `keychainGroup`, `secretsGroup`, `recordsGroup`, `deviceGroup`, `ownGroup`, `cloudContainer`, `notesContainer`, `changeNotification`, `defaultDirectory()`. |

```swift
@MainActor func syncNowIfAllowed() {
  guard !VaultICloud.isOff else { return }   // the user turned iCloud off for every v57 app on this device
  Vault.shared.sync?.syncNow()
}
```

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
| `S3FileSystem`, `S3Configuration`, `S3Transport`, `URLSessionS3Transport` | S3-compatible storage (AWS S3, Cloudflare R2, MinIO), with an injectable transport. |
| `RemoteConnections.fileSystem(for:secret:transport:)` | The file system for a `VaultRemote` record; nil for kinds without a backend yet (SFTP, SMB, FTP, iCloud). |

```swift
func listRemote(_ remote: VaultRemote) async throws -> [RemoteFileInfo] {
  guard let files = try RemoteConnections.fileSystem(for: remote, secret: remote.secret) else { return [] }
  return try await files.list("")
}
```

### Passwords, passkeys, documents and notes

| API | What it is |
|---|---|
| `OneTimeCode`, `Base32` | Time-based one-time codes (TOTP) from an `otpauth://totp` URL or a base32 key; `OneTimeCode.hotp` is the counter code underneath. |
| `PasswordGenerator`, `PasswordStrength` | Generated passwords (groups of easy-to-read letters and digits, `-` between) and a strength estimate. |
| `WebAuthn`, `VaultAutoFill` | Passkey signatures; which logins fit a site and what the system's AutoFill list shows. |
| `DocumentReader`, `MachineReadableZone`, `DocumentReminders` | Fields suggested from a page's recognized text (a passport's machine-readable zone among them), and the dates a document asks you to act on. |
| `NotesMirror`, `EncryptedNote`, `TextMerge`, `NoteConflicts` | Notes as files (Markdown and Shell), their encryption, and line merges. |

```swift
if let code = OneTimeCode("otpauth://totp/Example:me?secret=JBSWY3DPEHPK3PXP&issuer=Example") {
  print(code.code(), "valid for", code.secondsRemaining(), "s")
}
let password = PasswordGenerator().generate()
```

### SSH agent (macOS)

`VaultSSHAgent.shared` lends a Secure Enclave key to `ssh`, `git` and `ssh-add` for a length the user picks
(`Length`: 10 seconds to 24 hours, or until turned off), asking before each signature or once per turn-on. It lives in
the app's own process (no helper): its Unix socket sits in the store's folder, readable only by the user, and answers
with no keys while the agent is off. `startServing()`, `turnOn(for:)`, `stop()`, `shutdown()`; the app answers
requests through `approve`, which [VaultUI](VaultUI.md)'s `SSHAgentPanels.install` sets. `SSHAgentConfig` writes
`~/.ssh/vault.conf` for the hosts it serves and one `Include` line at the top of `~/.ssh/config`. The Vault app is the one that runs it.

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
fake CloudKit; the sync rules live in `SyncCoordinator` so they can run against it), `FakeS3`, `FakeDatabase`,
`FlakyKeys` and `OldBuildStore`. They are test-only, not part of the library. `MemoryRemoteFileSystem` is public.

Rules for changes to VaultKit, from the repo's CLAUDE.md: the record format never changes in place, saves write only
changed fields and never drop unknown ones, and nothing adds a helper process.

## Related

- [VaultUI](VaultUI.md): the account, device, trust and projects screens over this data.
- [VaultFiles](VaultFiles.md): encrypted folders, whose keys `VaultFolder` records hold.
- [VaultSync](VaultSync.md): folder sync over the `RemoteFileSystem`s here.
- [VaultHub](VaultHub.md): the user's own Hubs, as hosts and as a record sync without iCloud.
- The README's [How it works](../README.md#how-it-works): the store, keys, merging and sync in depth.
