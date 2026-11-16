# VaultFiles

Encrypted folders: whole folders kept encrypted on disk, names included, each with its own key, and a way to decrypt
one for a while for tools that can't read it.

## Purpose

VaultFiles is the on-disk format and the code that reads and writes it. A folder's contents are sealed with AES-256-GCM
in 64 KB chunks, each file under its own key derived from the folder key, and every file and folder name is encrypted
too, so the disk shows only ciphertext.

It doesn't sync folders between devices (that's [VaultSync](VaultSync.md)) and it doesn't keep folder records (a
`VaultFolder` in [VaultKit](VaultKit.md) holds a folder's wrapped key and its path per device). The format and its
guarantees are in the README's [How it works](../README.md#how-it-works) ("Encrypted folders"); the user's side is in
[Encrypted Folders](Encrypted-Folders.md).

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS 14**: everything. `FolderWatcher` uses FSEvents.
- **iOS/iPadOS 17**: everything but `FolderWatcher` and `DecryptSession.watch`: call `sealChanges()` on a timer
  instead.
- **Linux**: builds, and the tests pass on Ubuntu 24.04. `FolderWatcher` uses inotify (v57/SwiftUI's
  `SwiftUIPortability`); CryptoKit comes from v57/SwiftUI.
- **Windows**: builds; the tests build. No `FolderWatcher`: seal on a timer. A crashed session can't be told from a
  running one there (no `flock`), so recover leftovers only at launch.
- **Android**: not built or tested.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Vault.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "VaultFiles", package: "Vault")]),
]
```

VaultFiles depends on VaultKit, which it uses for the vault keys that wrap a folder key.

```swift
import Foundation
import VaultFiles
import VaultKit

@MainActor func makeFolder(at url: URL, vault: Vault) throws -> EncryptedFolder {
  let key = FolderKey()
  let folder = try EncryptedFolder(url: url, key: key)   // makes it when nothing is there yet
  try folder.write(Data("hello".utf8), to: "notes/hello.txt")

  // The vault keeps the folder key sealed with the vault key, in the folder's record.
  var record = VaultFolder(name: url.lastPathComponent, wrappedKey: try key.wrapped(with: KeychainKeyProvider()))
  record.setPath(url.path, for: vault.deviceID)
  vault.save(record)
  return folder
}

func readNotes(_ record: VaultFolder, at url: URL) throws -> [String] {
  let key = try FolderKey(wrapped: record.wrappedKey ?? "", keys: KeychainKeyProvider())
  let folder = try EncryptedFolder(url: url, key: key)
  return try folder.list("notes").map(\.name)   // plaintext names; the disk shows only ciphertext
}
```

## Main API

### Folders and keys

| API | What it is |
|---|---|
| `FolderKey()`, `FolderKey(id:keyData:)` | A folder's own key: a new random one, or one from its bytes. |
| `wrapped(with:)`, `FolderKey(wrapped:keys:)` | The key sealed with the vault key (base64, as `VaultFolder.wrappedKey` stores it), and opened again. Throws `VaultCrypto.CryptoError.missingKey` until the vault key reached this device. |
| `EncryptedFolder(url:key:)` | Opens the folder at `url`, or makes one in an empty place. Throws `wrongKey` for another key and `notEncrypted` for an ordinary folder. |
| `list(_:)`, `walk(_:)`, `stat(_:)`, `exists(_:)` | Entries by plaintext path (`EncryptedFolder.Entry`: name, path, isDirectory, size, modified). Names that don't decrypt are skipped. |
| `read(_:)`, `readFile(_:to:)`, `reader(_:)` | A whole file, a file decrypted to a URL, or ranges without decrypting the rest (`EncryptedFileReader.read(range:)`). |
| `write(_:to:)`, `writeFile(from:to:)`, `write(to:produce:)`, `beginWrite(to:)` | Writing from data, a file, a streaming writer, or a `PendingWrite` you `append` to and then `commit()` or `cancel()`. |
| `createDirectory(_:)`, `move(_:to:)`, `remove(_:)` | Folders, renames (re-sealed for the new place), deletes. |
| `exportDecrypted(to:)` | A plain copy of the whole folder. |
| `EncryptedFolder.isEncryptedFolder(_:)`, `EncryptedFolder.keyID(at:)` | Whether a folder is one, and which key it needs, read without a key. |

```swift
func appendLog(_ lines: [String], to folder: EncryptedFolder) throws {
  let write = try folder.beginWrite(to: "logs/today.txt")
  do {
    for line in lines { try write.append(Data((line + "\n").utf8)) }
    _ = try write.commit()   // the plaintext's SHA-256
  } catch {
    write.cancel()
    throw error
  }
}
```

### Temporary decryption

| API | What it is |
|---|---|
| `DecryptSession.start(_:in:name:duration:onActivity:)` | Decrypts a folder into a working copy in `parent` for tools like git and Xcode. The copy is kept out of Spotlight (a `.metadata_never_index` file) and, on Apple platforms, out of backups. `duration` (30 minutes by default) sets `lockDate`; the app locks the session when `isExpired`. |
| `sealChanges()`, `extend(by:)`, `lock()` | Seals what changed in the copy back into the folder (`DecryptSession.Report`: edited, added, deleted); more time; seal and delete the copy. |
| `watch(latency:onSeal:)` | macOS and Linux: seals whenever the copy changes, through a `FolderWatcher` you keep and stop before `lock()`. |
| `DecryptSession.leftovers(in:)`, `DecryptSession.recoverLeftovers(in:folder:)` | Copies a crash left behind; seal them back and delete them at the next launch. A live session holds a lock, so another app sharing the folder never recovers it. |
| `FolderWatcher(url:latency:handler:)` | Calls the handler when anything under a folder changes (macOS and Linux). |
| `FolderActivity` | Progress for the UI: phase, current file, bytes, files done of total, `fraction`, `summary`. |

While a folder is decrypted any process the user runs can read it, and deleted plaintext can't be reliably wiped from
an SSD, so show the session as a visible, timed state ("Decrypted, locks in 30 min").

```swift
func decryptForGit(_ folder: EncryptedFolder, in parent: URL) throws -> DecryptSession {
  let session = try DecryptSession.start(folder, in: parent, duration: 15 * 60)
  // … the user works in session.copyURL …
  return session   // later: try session.sealChanges(), and try session.lock() once session.isExpired
}
```

### Format

| API | What it is |
|---|---|
| `EncryptedFile`, `EncryptedFileReader`, `EncryptedFileWriter` | The `V57FILE1` file format: 64 KB AES-GCM chunks bound to the file's place in the folder, readable by range. |
| `NameCipher`, `DiskName`, `FolderSubkeys` | Deterministic encrypted names under the parent folder's id, long-name sidecars, keys derived per purpose (HKDF). |
| `Base64URL` | The name encoding. |
| `VaultFilesError` | `notEncrypted`, `unsupportedVersion`, `damaged`, `wrongKey`, `notFound`, `exists`, `notADirectory`, `isADirectory`, `invalidName`, `tooLarge`, each with a message for the user. |

The on-disk format (`V57FILE1` files, encrypted names, `folder.v57`, `dir.v57`) never changes in place: a change is a
new version that old folders keep opening.

## Testing

```bash
swift test --filter VaultFilesTests   # encrypted files, names, folders, decrypt sessions
```

Tests use temporary directories, keep files to a few MB, and make keys with `FolderKey()`; wrapping uses a
`MemoryKeyProvider` from VaultKit, so nothing reaches the keychain.

## Related

- [VaultKit](VaultKit.md): `VaultFolder` records and the vault keys that wrap a folder key.
- [VaultSync](VaultSync.md): syncs a folder, with an `EncryptedFolder` as this device's copy (`EncryptedSyncFolder`).
- [Encrypted Folders](Encrypted-Folders.md): the same feature in the Vault app, for users.
