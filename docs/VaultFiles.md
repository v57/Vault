# VaultFiles

Encrypted folders: whole folders kept encrypted on disk, names included, each with its own key, and a way to decrypt
one for a while for tools that can't read it.

VaultFiles is the on-disk format and the code that reads and writes it. It doesn't sync folders between devices (that's
[VaultSync](VaultSync.md)) and it doesn't keep folder records (a `VaultFolder` in [VaultKit](VaultKit.md) holds a
folder's wrapped key and its path per device). The format and its guarantees are in the README's
[How it works](../README.md#how-it-works) ("Encrypted folders"); the user's side is in
[Encrypted Folders](Encrypted-Folders.md).

## Getting started

```swift
.package(url: "https://github.com/v57/Vault.git", branch: "main"),
// in the target:
.product(name: "VaultFiles", package: "Vault"),
```

VaultFiles depends on VaultKit, which it uses for the vault keys that wrap a folder key.

```swift
import Foundation
import VaultFiles
import VaultKit

func makeFolder(at url: URL, vault: Vault) throws -> EncryptedFolder {
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
| `list(_:)`, `walk`, `stat`, `exists` | Entries by plaintext path (`EncryptedFolder.Entry`: name, path, isDirectory, size, modified). Names that don't decrypt are skipped. |
| `read(_:)`, `readFile(_:to:)`, `reader` | A whole file, a file decrypted to a URL, or ranges without decrypting the rest. |
| `write(_:to:)`, `writeFile(from:to:)`, `write(to:produce:)`, `beginWrite` | Writing from data, a file, or a streaming writer. |
| `createDirectory`, `move`, `remove` | Folders, renames (re-sealed for the new place), deletes. |
| `exportDecrypted(to:)` | A plain copy of the whole folder. |
| `EncryptedFolder.isEncryptedFolder(_:)`, `EncryptedFolder.keyID(at:)` | Whether a folder is one, and which key it needs, read without a key. |

### Temporary decryption

| API | What it is |
|---|---|
| `DecryptSession.start(_:in:name:duration:onActivity:)` | Decrypts a folder into a working copy in `parent` (hidden from Spotlight and backups) for tools like git and Xcode, locking after `duration` (30 minutes by default). |
| `sealChanges()`, `extend(by:)`, `lock()` | Seals what changed in the copy back into the folder (`DecryptSession.Report`: edited, added, deleted); more time; seal and delete the copy. |
| `DecryptSession.leftovers(in:)`, `DecryptSession.recoverLeftovers(in:folder:)` | Copies a crash left behind; seal them back and delete them at the next launch. |
| `FolderWatcher(url:latency:handler:)` | Calls the handler when anything under a folder changes, so the app can seal as the user works. |
| `FolderActivity` | Progress for the UI: phase, current file, bytes, files done of total. |

### Format

| API | What it is |
|---|---|
| `EncryptedFile`, `EncryptedFileReader`, `EncryptedFileWriter` | The `V57FILE1` file format: 64 KB chunks bound to the file's place, readable by range. |
| `NameCipher`, `DiskName`, `FolderSubkeys` | Deterministic encrypted names under the parent's id, long-name sidecars, keys derived per purpose. |
| `Base64URL` | The name encoding. |
| `VaultFilesError` | `notEncrypted`, `unsupportedVersion`, `damaged`, `wrongKey`, `notFound`, `exists`, `notADirectory`, `isADirectory`, `invalidName`, `tooLarge` and others. |

The on-disk format (`V57FILE1` files, encrypted names, `folder.v57`, `dir.v57`) never changes in place: a change is a
new version that old folders keep opening.

## Platform notes

| Platform | State |
|---|---|
| macOS 14 | Everything. `FolderWatcher` uses FSEvents. |
| iOS/iPadOS 17 | Everything but `FolderWatcher`: call `sealChanges()` on a timer instead. |
| Linux | Builds; the tests pass on Ubuntu 24.04. `FolderWatcher` uses inotify (v57/SwiftUI's `SwiftUIPortability`); CryptoKit comes from v57/SwiftUI. |
| Windows | Builds; the tests build. No `FolderWatcher`: seal on a timer. |
| Android | Not built or tested. |

## Testing

```bash
swift test --filter VaultFilesTests   # encrypted files, names, folders, decrypt sessions
```

Tests use temporary directories, keep files to a few MB, and make keys with `FolderKey()`; wrapping uses a
`MemoryKeyProvider` from VaultKit, so nothing reaches the keychain.
