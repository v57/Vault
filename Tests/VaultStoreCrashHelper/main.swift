// Opens a store the way an app does, so that `VaultStoreCrashTests` can kill a real process during its migration. It's for
// the tests alone: no app links it, and it never runs beyond them. It uses a memory keychain and the folder it's given.
import CryptoKit
import Foundation
import VaultKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let key = Data(base64Encoded: arguments[2]) else {
  print("usage: VaultStoreCrashHelper <folder> <base64 key>")
  exit(2)
}
do {
  let keys = MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(data: key)])
  let store = try VaultStore(
    directory: URL(fileURLWithPath: arguments[1]), keys: keys, deviceID: "helper", notifier: nil,
    owner: "helper-\(ProcessInfo.processInfo.processIdentifier)")
  let status = store.formatStatus
  print("waiting=\(status.isWaiting) resealed=\(status.resealed) error=\(status.error ?? "none")")
  exit(status.isWaiting ? 1 : 0)
} catch {
  print("failed: \(error)")
  exit(3)
}
