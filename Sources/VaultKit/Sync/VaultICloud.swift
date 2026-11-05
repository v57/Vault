import Foundation
import Observation

/// The switch that turns iCloud off for every v57 app on this device (Settings ▸ Privacy, `VaultICloudCard`).
///
/// It's one switch per device rather than per app, because the apps share one store: an app still syncing would send
/// what the others wrote. It's a file beside the store, not a record, so it never syncs: another device decides for
/// itself. A file also outlives `VaultStore.resetServerState`, and the keychain can read it without opening the store.
///
/// While it's off:
/// - `CloudSync` runs no engine and asks CloudKit nothing, not even for the account's status. Writes wait in the outbox
///   and go up when it's on again, so nothing is lost and nothing needs a full send.
/// - `VaultKeychain` keeps what would go to iCloud Keychain in items on this device only.
/// - What's already in iCloud stays there, and the other devices keep it: deleting it would take it from them too.
public enum VaultICloud {
  /// Whether this platform has iCloud at all. Elsewhere the vault never leaves the device, or goes through a Hub.
  public static var isSupported: Bool {
    #if canImport(CloudKit)
      true
    #else
      false
    #endif
  }

  /// Posted to every process on the device when the switch changes.
  public static let changeNotification = "dev.v57.vault.icloud"

  /// Whether the user turned iCloud off on this device. Read from disk each time, so another app's change counts at once.
  public static var isOff: Bool {
    FileManager.default.fileExists(atPath: VaultConfiguration.iCloudOffFile.path)
  }

  /// Turns iCloud off or on for every v57 app on this device.
  public static func setOff(_ off: Bool) throws {
    let file = VaultConfiguration.iCloudOffFile
    if off {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: file, options: .atomic)
    } else if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
    SystemChangeNotifier(name: changeNotification).post()
  }
}

/// `VaultICloud.isOff` for SwiftUI, current whichever app changes it.
@MainActor
@Observable
public final class VaultICloudStatus {
  public static let shared = VaultICloudStatus()

  public private(set) var isOff = VaultICloud.isOff
  /// Why the last change failed, for the UI.
  public private(set) var error: String?
  @ObservationIgnored private var observer: VaultChangeObserver?

  public init() {
    observer = VaultChangeObserver(name: VaultICloud.changeNotification) { [weak self] in
      Task { @MainActor in self?.isOff = VaultICloud.isOff }
    }
  }

  /// Turns iCloud off or on for every v57 app on this device; a failure goes to `error`.
  public func setOff(_ off: Bool) {
    do {
      try VaultICloud.setOff(off)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
    isOff = VaultICloud.isOff
  }
}
