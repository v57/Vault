# VaultSync

Folder sync over plain storage: keeps a folder in step across a person's devices and the people it is shared with,
through a remote that only stores files (S3, a local disk, any `RemoteFileSystem`), with no server, locks or change
notifications. The remote copy is always encrypted.

## Purpose

VaultSync is the engine. On the remote it keeps a member list signed by the folder's owner (with the folder keys
wrapped to each member), and content-addressed chunks written once, one change log per device that only that device
appends to, and snapshots, all sealed with the folder key. Two devices never write the same object, so nothing needs a
lock.

It runs only when the app calls it (on open and on a timer; there is no background process). It doesn't choose or
store remotes (a `VaultRemote` record in [VaultKit](VaultKit.md) does, and `RemoteConnections.fileSystem(for:secret:)`
makes its file system), and it keeps a local copy either as plain files or as an [encrypted folder](VaultFiles.md).
The remote layout and the conflict rules are in the README's [How it works](../README.md#how-it-works) ("Folder
sync"); the user's side is in [Folder Sync](Folder-Sync.md).

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS 14, iOS/iPadOS 17**: everything.
- **Linux**: builds, and the tests pass on Ubuntu 24.04.
- **Windows**: builds; the tests build.
- **Android**: not built or tested.

The engine contacts only the `RemoteFileSystem` it is given. Today VaultKit has backends for S3-compatible storage and
local folders; SFTP, SMB, FTP and iCloud have none yet (`RemoteConnections` returns nil for them), so an app that
wants one passes a `RemoteFileSystem` of its own.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Vault.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "VaultSync", package: "Vault")]),
]
```

VaultSync depends on VaultKit and VaultFiles.

```swift
import Foundation
import VaultKit
import VaultSync

func syncFolder(_ record: VaultFolder, remote: any RemoteFileSystem, at url: URL, state: URL) async throws {
  let sync = try FolderSync(
    FolderSync.Configuration(
      folder: record, remote: remote, local: try PlainSyncFolder(url: url), device: VaultDevice.id,
      identity: try VaultPersonalIdentity.current(), stateDirectory: state))
  await sync.observe { status in
    print(status.phase)   // hop to the main actor to show it
  }
  try await sync.sync()
}
```

The record gives the rest: its path on the remote (`syncPath`), the owner's key (the user's own, or the inviter's on a
folder someone shared), this device's mode, and one state file per folder in `stateDirectory`. A new folder's remote
side is made once with `FolderSync.createRemoteFolder(remote:remotePath:folderID:owner:ownerName:key:)`; a folder
someone shares arrives as `VaultFolder.shared(by:)` from their invite.

`VaultPersonalIdentity.current()` is readable only by Vault and its AutoFill extension (it's in the secrets keychain
group); elsewhere it throws. The Vault app is the one that runs folder sync (`App/Sources/VaultApp/Engine/LiveFolderSync.swift`): one
engine per folder that syncs through an enabled S3 remote, on open, on Sync Now, when the app comes to the front,
every few minutes while it's open, and in iOS background refresh. `--demo` shows sample sync data instead.

## Main API

### Setting up a folder

| API | What it is |
|---|---|
| `FolderSync` | The engine, an actor, one per folder. `FolderSync(_:)` checks the configuration (throws `invalidDevice` for a bad device id). |
| `FolderSync.Configuration(folder:remote:local:device:identity:stateDirectory:)` | From a `VaultFolder` record: `syncPath`, the owner's key, this device's mode, `<stateDirectory>/<folder id>.v57sync`. Throws `damaged` when the record's owner key isn't one. |
| `FolderSync.Configuration(folderID:remote:remotePath:local:device:identity:ownerSigningKey:mode:stateURL:)` | The same by hand: the folder, the remote and the path on it, the local copy, this device's id, the person's identity, the owner's key, read-write or read-only, and where to keep the sync state (nil keeps it in memory). Also `chunkSize` (1 MB), `snapshotAfter`, `gracePeriod` (24 h), `factsInterval`, `recentLimit`, `now`. |
| `FolderSync.createRemoteFolder(remote:remotePath:folderID:owner:ownerName:key:)` | Makes the remote folder's member list with the owner as its only member. Throws `folderExists`. |
| `VaultFolder.shared(by:)`, `syncPath`, `isOwned(by:)`, `ownerSigningKey(for:)` | A folder record from someone's invite (read-only until they add you), the folder's path on the remote, and whose it is. |
| `SyncLocalFolder`, `PlainSyncFolder(url:)`, `EncryptedSyncFolder(_:)` | This device's copy: ordinary files, or an `EncryptedFolder`. |

```swift
func shareNewFolder(_ id: String, on remote: any RemoteFileSystem, as owner: PersonalIdentity) async throws {
  _ = try await FolderSync.createRemoteFolder(
    remote: remote, remotePath: "sync/\(id)", folderID: id, owner: owner, ownerName: "Me")
}
```

### Syncing and status

| API | What it is |
|---|---|
| `sync()` | One pass: read the member list and other devices' changes, send this device's, apply theirs, tidy up. |
| `observe(_:)`, `status` | `FolderSyncStatus`: `phase` (`idle`, `checking`, `receiving`, `sending`, `cleaning`), files being received and sent, `changedHere`, `conflicts`, `conflictCopies`, `receivedRecently`, `remote` facts, `ignoredChanges`. |
| `setMode(_:)` | Read-write or read-only (`VaultFolder.Mode`). |
| `keepMine(_:)`, `revertToRemote(_:)`, `revertAll()` | A read-only device's answers to a file changed both here and on the remote. |

When several devices edit one file at once, every device resolves it the same way: an edit beats a delete, text merges
line by line when that merges cleanly, and otherwise the later write wins and the other becomes a conflict copy next
to it.

### Sharing

| API | What it is |
|---|---|
| `addMember(_:name:role:)`, `setRole(_:for:)`, `removeMember(_:)` | Sharing, by the owner. Removing someone starts a new key epoch: a new folder key, wrapped to everyone left. |
| `memberList`, `FolderMembers`, `FolderKeyring` | The owner-signed member list (roles, keys in epochs) and the keys a person holds. |
| `FileChange` | One signed change to a path, with the versions it replaces. Changes not signed by a member with write access are ignored. |
| `FolderSyncError` | `notSignedByOwner`, `olderMemberList`, `notAMember`, `notOwner`, `missingKey`, `invalidDevice`, `folderExists` and others, each with a message for the user. |

```swift
func invite(_ friend: PublicIdentity, to sync: FolderSync) async throws {
  try await sync.addMember(friend, name: "Sam", role: .readOnly)
}
```

## Testing

```bash
swift test --filter VaultSyncTests   # member lists, several devices on a fake remote
VAULT_SYNC_S3="http://127.0.0.1:9317 hub <key> <secret>" swift test --filter SyncedFolderLiveTests   # a real S3 server
```

`SyncedFolderTests` runs the app's flow from records (owner, invite, a read-only friend) on a memory remote;
`SyncedFolderLiveTests` does it against the S3 server `VAULT_SYNC_S3` names (endpoint, bucket, access key, secret),
for example Hub's `hub-s3-local`, and is skipped without it.

The tests run several people and devices against a `MemoryRemoteFileSystem` with a clock they move by hand
(`Tests/VaultSyncTests/Support/SyncWorld.swift`, test-only). The same works in an app's tests:

```swift
import Testing
import VaultFiles
import VaultKit
import VaultSync

@Test func createsAFolder() async throws {
  let remote = MemoryRemoteFileSystem()
  let owner = PersonalIdentity()
  let members = try await FolderSync.createRemoteFolder(
    remote: remote, remotePath: "sync/folder-1", folderID: "folder-1", owner: owner, ownerName: "Owner")
  #expect(members.role(of: owner.publicIdentity.signingKey) != nil)
}
```

## Related

- [VaultKit](VaultKit.md): `VaultFolder` and `VaultRemote` records, `RemoteFileSystem` and its S3 backend, the
  personal identity.
- [VaultFiles](VaultFiles.md): the encrypted folder a device can keep as its copy.
- [Folder Sync](Folder-Sync.md): the same feature in the Vault app, for users.
