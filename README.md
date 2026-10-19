# Vault

The data the v57 apps share, as a small Swift package: projects (Git, Code, Dev, Markdown, Shell), SSH hosts and
the device's SSH key (Shell, Database), database connections (Database, Shell), known hosts, and encrypted
notes (Markdown, Shell). Every app on a device reads the same store, sees the others'
changes within a second, and syncs through the user's iCloud. Nothing in it is readable by other apps or other
users.

```swift
import VaultKit

@main struct MyApp: App {
  init() { Vault.shared.startSync() }  // iCloud sync, when the user is signed in

  var body: some Scene {
    WindowGroup { ProjectList() }
  }
}

struct ProjectList: View {
  @State private var vault = Vault.shared

  var body: some View {
    List(vault.localProjects) { Text($0.name) }   // live: changes from any app or device appear
  }
}

// Writing
try Vault.shared.store?.addProject(path: url.path, remoteURL: origin)
Vault.shared.save(VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy"))
try VaultSecrets.setPassword(password, for: database.id)
```

## What each app declares

| Entitlement | Value |
|---|---|
| `com.apple.security.application-groups` | `$(TeamIdentifierPrefix)dev.v57` (macOS), `group.dev.v57` (iOS) |
| `keychain-access-groups` | `$(AppIdentifierPrefix)dev.v57.shared` |
| `com.apple.developer.icloud-container-identifiers` | `iCloud.dev.v57` |
| `com.apple.developer.icloud-services` | `CloudKit` |
| `com.apple.developer.aps-environment` (`aps-environment` on iOS) | `development` / `production`, for sync pushes |

A build without them (ad-hoc signed) still runs: the store falls back to the app's own Application Support and
keychain, and sync stays off.

## How it works

**One store per device.** `VaultStore` is a SQLite file in the app group container. Each item is one row: an id,
its kind, and its fields sealed with AES-GCM. The table never changes shape. Fields live inside the payload, so
apps of any version share the file, and an app that knows fewer fields than another (Shell's view of a Database
connection) keeps the ones it doesn't know.

**Encryption.** The AES-256 keys are iCloud Keychain items in the shared access group `dev.v57.shared`, which only
the team's apps that list it can read. Other apps, other users and CloudKit see ciphertext. Each item names its key,
so a device can hold several: if two devices make the first key at once, both keys reach both devices and the one
with the smaller id becomes everyone's key for new writes. Passwords are separate iCloud Keychain items
(`VaultSecrets`). Each device's SSH key is a Secure Enclave key (`VaultIdentity`) shared by the apps on that device.

**Merging.** Every field carries a hybrid logical clock (wall time, a counter, the device id). Merging two copies
of an item keeps each field's later write, so edits made on an iPhone and a Mac at once both survive unless they
changed the same field, and then every device keeps the same one. A delete is a write too, and loses to an edit made
after it.

**No duplicates.** Ids come from content where there is one: a project is a keyed hash of its remote URL and
folder name, so the same checkout added on two Macs is one record. If two ids for the same thing appear anyway
(made before the keys synced), every device folds them into the one with the smaller id.

**Sync without a helper.** Every app runs its own `CKSyncEngine` against the `Vault` zone of the private database.
A write puts the item in the outbox and leases it to the app that wrote it, which sends it. If that app quits
first, the lease runs out and any other app sends it. Every app fetches, and the store skips records it already
has, so a change is sent once and applied once. A conflict merges the server's copy and sends the merge on top.

**Project tree.** Projects sit in groups that nest (`VaultProjectGroup`), so every app's sidebar can show the same
arrangement on every device. A project's place is its `groupID` and `order`, a group's its `parentID` and `order`;
groups and projects share one order. `VaultProjectTree` builds the tree from the records alone, the same way
everywhere: an item whose group is gone sits at the top level, and a loop (two devices moving two groups into each
other at once) breaks at the group with the smallest id. Change it through the store (`moveProjects`,
`addProjectGroup`, `groupProjects`, `ungroupProjects`), which renumbers the items it touches and deletes the groups a
move leaves empty. `filter` gives what one device shows (`Vault.localProjectTree`). Collapsing a group is each app's
own state.

**Project kinds.** A project notes what its folder holds (`VaultProject.Kind`: `xcode` for an `.xcodeproj` at the top
or one folder down, `swiftPackage`), one `kind.<name>` field each, so an app can pick the projects it works on (Dev
lists only Xcode projects). `addProject` detects them, and `refreshProjectKinds` looks again at this device's
folders and saves only what changed. A project's `icon` is a small PNG of its app icon (at most 64 KB) that every app can show, even
where the folder isn't: an app that can find icons (Code's `ProjectIcon`) passes its finder and thumbnailer to
`refreshProjectIcons`, which makes it again only when the source file's hash (`iconSource`) changes.

**Live updates.** Every write posts a Darwin notification, and `Vault` reloads in every app on the device.

**Notes.** A note is a record (`VaultNote`: folder, name, text, and whether its local file is encrypted). It syncs like
everything else, encrypted titles included, with no need for iCloud Drive. Text that two devices edited at once merges
line by line (`TextMerge`) against the server copy both started from (the store keeps the last server copy of each
item), the same way on every device; lines both changed stay twice, between conflict markers.

On each device Markdown keeps the notes as files in a local folder: `NotesMirror` reconciles the folder and the
records both ways, so Finder, Files, other editors and git work on them. Each file carries its note's id in an
extended attribute (recovered from the last known path when an editor's atomic save drops it), and an index of the
last pass tells which side changed; edits on both sides merge against the last synced text. An encrypted note is
`Name.mdenc` on disk (`EncryptedNote`, only the v57 apps read it), a plain one `Name.md`. Other files, like images a
note links to, sync as `VaultNoteFile`. Shell edits the records directly. `NoteConflicts` still merges iCloud Drive
conflict versions of notes in folders the user adds to Markdown.

## Layout

| Folder | What |
|---|---|
| `Core/` | `JSONValue`, `HybridClock`, `ItemFields` (the merge), `VaultConfiguration` (identifiers) |
| `Keys/` | `VaultKeychain` (shared group), `VaultKeys` (AES keys, sealing), `VaultIdentity` (SSH key), `VaultSecrets`, `VaultDevice` |
| `Store/` | `VaultStore` (SQLite, outbox, merging records in), change notifications |
| `Records/` | Typed records: `VaultProject`, `VaultProjectGroup` (with `VaultProjectTree`), `VaultHost`, `VaultKnownHost`, `VaultDeviceKey`, `VaultDatabase`, `VaultNote`, `VaultNoteFile` |
| `Sync/` | `SyncCoordinator` (the sync rules, testable), `CloudSync` (the `CKSyncEngine` adapter) |
| `Notes/` | `NotesMirror`, `EncryptedNote`, `NoteConflicts`, `NoteBaseCache`, `TextMerge` |

`swift test` runs the merge, store and sync tests. The sync tests use a fake CloudKit (`Tests/.../FakeCloud.swift`)
with several devices and several apps per device.
