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
(`VaultSecrets`; a demo run or a test keeps them in memory instead with `VaultSecrets.useInMemoryStore()`). Each
device's SSH key is a Secure Enclave key (`VaultIdentity`) shared by the apps on that device.

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

**Encrypted folders.** The `VaultFiles` library keeps whole folders encrypted, names included, so a folder can
sit on any disk or remote and show only ciphertext there. Each folder has its own key (`FolderKey`), which the vault
keeps wrapped by the vault key in the folder's record. A file is sealed in 64 KB chunks (`EncryptedFile`, like age
or Tink's streaming AEAD): it streams in and out, any range reads without decrypting the rest, and changed,
reordered or truncated chunks fail to open. Each file's chunks are bound to its place (its folder's id and its name),
and so is each folder's sealed id, so someone who can write to the disk but has no key can't swap files or folders or
move one elsewhere: it fails to open, and `move` re-seals for the new place (format 2; format 1 never shipped and is
refused). Names are encrypted deterministically under their parent folder's
random id, so paths resolve without an index and renaming a folder rewrites one name (`NameCipher`).
`EncryptedFolder` lists, reads, writes, moves and removes by plaintext path. For tools that can't read it (git,
Xcode, other apps), `DecryptSession` decrypts a working copy, hidden from Spotlight and backups, seals changes back
when the app asks (or as they happen, with `FolderWatcher` on macOS), and deletes the copy when it locks; copies a
crash left behind are sealed and deleted at the next launch.

**Recovery key.** Optional and off until the user makes one (`VaultRecovery.create`); nothing in VaultKit
prompts or reminds, `isOn` is the only state. The user keeps a random 256-bit secret, shown once as 24 BIP-39 words
or 14 groups of base32, both with a checksum, and as a QR code on a printable kit (`RecoveryKit`, `V57R1:…`).
Devices keep only the X25519 public key derived from it (HKDF), so any device seals a new vault key, identity or
folder key to it (HPKE) without the secret: one `VaultRecoveryBlob` record per key, synced like everything else but
sealed with a key derived from the recovery public key instead of the vault key, so a device that lost the vault
keys can still read them. A synced folder's remote keeps its folder keys' blobs too, in `<folder>/recovery/` next to
`members`, so the folder comes back with only the remote and the kit. `recover` opens every blob with the typed or
scanned kit and `RecoveredKeys.restore` writes the vault keys and identity back to iCloud Keychain; `replace` makes
a new kit and deletes the old blobs, `turnOff` deletes them everywhere.

## The Vault app

`Vault/` is a Mac and iPad app on VaultKit and VaultFiles (`Vault.xcodeproj`, bundle `dev.v57.vault`; build it against
the checkouts next to this one with `Vault-Local.xcworkspace`). It imports only SwiftUI, ComponentKit, VaultKit and
VaultFiles, plus UpdateKit on the Mac. It shows the records every v57 app already shares (logins, cards, notes, SSH
hosts, databases, projects, devices) and the newer pieces: encrypted folders with timed decryption for other apps,
people and safety codes, remotes. What VaultKit doesn't do yet is drawn against protocols in `Vault/Engine/`
(`FolderSyncEngine`, `RemoteService` backends, `RecoveryService`), each saying plainly what isn't there yet.

`--demo` opens a demo vault in a temporary folder: in-memory keys, secrets and identity, real encrypted folders, and
sample data only for folder sync and remote listings. It never touches the user's vault. Other launch arguments
(`--select logins|hosts|folder:<name>|…`, `--login`, `--host`, `--person`, `--sheet decrypt|share|new-login|add-remote`,
`--welcome`, `--waiting-for-keys`, `--settings`, `--settings-pane`, `--dark`, `--light`) open any screen;
`.dev/screenshots.json` lists the screenshot scenes.

## Layout

| Folder | What |
|---|---|
| `Core/` | `JSONValue`, `HybridClock`, `ItemFields` (the merge), `VaultConfiguration` (identifiers) |
| `Keys/` | `VaultKeychain` (shared group), `VaultKeys` (AES keys, sealing), `VaultIdentity` (SSH key), `VaultSecrets`, `VaultDevice`, the recovery key (`VaultRecovery`, `RecoverySecret` and `RecoveryWordList`, `RecoveryKit`, the `VaultRecoveryKey` and `VaultRecoveryBlob` records) |
| `Store/` | `VaultStore` (SQLite, outbox, merging records in), change notifications, `VaultFieldChange` (each field's last write: when, which device) |
| `Records/` | Typed records: `VaultProject`, `VaultProjectGroup` (with `VaultProjectTree`), `VaultHost`, `VaultKnownHost`, `VaultDeviceKey`, `VaultDatabase`, `VaultNote`, `VaultNoteFile`, `VaultLogin`, `VaultCard`, `VaultFolder`, `VaultRemote` |
| `Remote/` | `RemoteFileSystem` (list, stat, read range, write, rename, delete), `MemoryRemoteFileSystem`, `LocalRemoteFileSystem`, `S3FileSystem` (AWS S3, R2, B2, MinIO; `AWSSignatureV4`, an injectable `S3Transport`), `RemoteConnections` (the file system for a `VaultRemote`) |
| `Sharing/` | `PersonalIdentity` (X25519 + Ed25519, one per person, `VaultPersonalIdentity`), `PublicIdentity` (`v57id:`), `SafetyCode`, `KeyWrap` (a key sealed to a person), `VaultPerson`, `VaultInvite` (`v57vault://invite`) |
| `Sync/` | `SyncCoordinator` (the sync rules, testable), `CloudSync` (the `CKSyncEngine` adapter) |
| `Passwords/` | `OneTimeCode` (TOTP/HOTP, `otpauth://` URLs), `Base32`, `PasswordGenerator`, `PasswordStrength` |
| `Notes/` | `NotesMirror`, `EncryptedNote`, `NoteConflicts`, `NoteBaseCache`, `TextMerge` |
| `VaultFiles/Format/` | `EncryptedFile` (chunked file format, `EncryptedFileReader` for ranges), `NameCipher` and `DiskName` (encrypted names, long-name sidecars), `FolderSubkeys` |
| `VaultFiles/Folder/` | `FolderKey` (wrapped by the vault key), `EncryptedFolder` |
| `Vault/` | The app: `App/` (model, window), `Sidebar/`, `Items/` (logins, hosts, databases, projects, cards, notes, New), `Folders/`, `Locations/`, `Keys/` (devices, people), `Settings/`, `Welcome/`, `Engine/` (folders on VaultFiles, people, the protocols), `Demo/` |
| `VaultFiles/Session/` | `DecryptSession` (temporary decryption, crash recovery), `FolderActivity` (progress for the UI), `FolderWatcher` (macOS) |

`swift test` runs the merge, store and sync tests. The sync tests use a fake CloudKit (`Tests/.../FakeCloud.swift`)
with several devices and several apps per device.
