# VaultSync

Folder sync over plain storage: keeps a folder in step across a person's devices and the people it is shared with,
through a remote that only stores files (S3, a local disk, any `RemoteFileSystem`), with no server, locks or change
notifications. The remote copy is always encrypted.

VaultSync is the engine. It runs only when the app calls it (on open and on a timer; there is no background process),
it doesn't choose or store remotes (a `VaultRemote` record in [VaultKit](VaultKit.md) does, and
`RemoteConnections.fileSystem(for:secret:)` makes its file system), and it keeps a local copy either as plain files or
as an [encrypted folder](VaultFiles.md). The remote layout and the conflict rules are in the README's
[How it works](../README.md#how-it-works) ("Folder sync").

## Getting started

```swift
.package(url: "https://github.com/v57/Vault.git", branch: "main"),
// in the target:
.product(name: "VaultSync", package: "Vault"),
```

VaultSync depends on VaultKit and VaultFiles.

```swift
import Foundation
import VaultKit
import VaultSync

func syncFolder(_ record: VaultFolder, remote: any RemoteFileSystem, at url: URL) async throws {
  let identity = try VaultPersonalIdentity.current()
  let sync = try FolderSync(
    FolderSync.Configuration(
      folderID: record.id, remote: remote, remotePath: record.remotePath ?? record.id, local: try PlainSyncFolder(url: url),
      device: VaultDevice.id, identity: identity, ownerSigningKey: identity.publicIdentity.signingKey,
      mode: record.mode(for: VaultDevice.id)))
  await sync.observe { status in
    print(status.phase)   // hop to the main actor to show it
  }
  try await sync.sync()
}
```

`ownerSigningKey` is the user's own key for a folder of their own; for a folder someone shared, it is
`VaultFolder.ownerSigningKey`. A new folder's remote side is made once with
`FolderSync.createRemoteFolder(remote:remotePath:folderID:owner:ownerName:key:)`.

## Main API

| API | What it is |
|---|---|
| `FolderSync` | The engine, an actor, one per folder. `FolderSync(_:)` checks the configuration. |
| `FolderSync.Configuration(folderID:remote:remotePath:local:device:identity:ownerSigningKey:mode:stateURL:)` | The folder, the remote and the path on it, the local copy, this device's id, the person's identity, the owner's key, read-write or read-only, and where to keep the sync state (nil keeps it in memory). Also `chunkSize`, `snapshotAfter`, `gracePeriod`, `factsInterval`, `recentLimit`, `now`. |
| `FolderSync.createRemoteFolder(remote:remotePath:folderID:owner:ownerName:key:)` | Makes the remote folder's member list with the owner as its only member. Throws `folderExists`. |
| `sync()` | One pass: read the member list and other devices' changes, send this device's, apply theirs, tidy up. |
| `observe(_:)`, `status` | `FolderSyncStatus`: `phase` (`idle`, `checking`, `receiving`, `sending`, `cleaning`), files being received and sent, `changedHere`, `conflicts`, `receivedRecently`, `remote` facts, `lastError`. |
| `setMode(_:)` | Read-write or read-only (`VaultFolder.Mode`). |
| `addMember(_:name:role:)`, `setRole(_:for:)`, `removeMember(_:)` | Sharing, by the owner. Removing someone rotates the folder key. |
| `keepMine(_:)`, `revertToRemote(_:)`, `revertAll()` | A read-only device's answers to a file changed both here and on the remote. |
| `SyncLocalFolder`, `PlainSyncFolder(url:)`, `EncryptedSyncFolder(_:)` | This device's copy: ordinary files, or an `EncryptedFolder`. |
| `FolderMembers`, `FolderKeyring` | The owner-signed member list (roles, keys in epochs) and the keys a person holds. |
| `FileChange` | One signed change to a path, with the versions it replaces. |
| `FolderSyncError` | `notSignedByOwner`, `olderMemberList`, `notAMember`, `notOwner`, `missingKey`, `invalidDevice`, `folderExists` and others, each with a message for the user. |

## Platform notes

| Platform | State |
|---|---|
| macOS 14, iOS/iPadOS 17 | Everything. |
| Linux | Builds; the tests pass on Ubuntu 24.04. |
| Windows | Builds; the tests build. |
| Android | Not built or tested. |

The engine contacts only the `RemoteFileSystem` it is given. Today VaultKit has backends for S3-compatible storage and
local folders; SFTP is left to the app (from Database's `SFTPClient`), and SMB, FTP and iCloud have none yet.

No app runs the engine on real folders yet: the Vault app's folder screens use a stand-in with no sync behind it
(`--demo` shows sample sync data). The engine itself is covered by the tests below.

## Testing

```bash
swift test --filter VaultSyncTests   # member lists, several devices on a fake remote
```

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
