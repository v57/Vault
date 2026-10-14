import Foundation

#if canImport(UIKit)
  import UIKit
#endif

/// This device: an id every app on it shares, and its name.
public enum VaultDevice {
  /// A random id made once per device, kept in the shared keychain group as a this-device-only item, so a
  /// backup restored onto another device doesn't bring it along. Clocks and project paths are tagged with it.
  public static let id: String = {
    #if DEBUG
      if let id = ProcessInfo.processInfo.environment["VAULT_DEVICE"] { return id }
    #endif
    let keychain = VaultKeychain()
    if let data = try? keychain.read("device-id", options: .thisDevice), let id = String(data: data, encoding: .utf8) {
      return id
    }
    let id = UUID().uuidString.lowercased()
    do {
      try keychain.addNew(Data(id.utf8), account: "device-id", options: .init(synchronizable: false, label: "v57 device id"))
      return id
    } catch {
      // Another app on the device made it first.
      if let data = try? keychain.read("device-id", options: .thisDevice), let id = String(data: data, encoding: .utf8) {
        return id
      }
      return id
    }
  }()

  /// The name people gave the device ("Dmitry's MacBook Pro").
  @MainActor public static var name: String {
    #if os(macOS)
      Host.current().localizedName ?? "Mac"
    #else
      UIDevice.current.name
    #endif
  }
}
