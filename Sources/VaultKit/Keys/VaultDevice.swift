import Foundation
import Observation

#if canImport(UIKit)
  import UIKit
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// This device: an id every app on it shares, and its name.
public enum VaultDevice {
  /// A random id made once per device, kept in the shared keychain group as a this-device-only item, so a
  /// backup restored onto another device doesn't bring it along. Clocks and project paths are tagged with it.
  /// After `VaultSecrets.useInMemoryStore()` (a demo run or a test) it is a new one for the process, and the
  /// keychain isn't read.
  public static let id: String = {
    #if DEBUG
      if let id = ProcessInfo.processInfo.environment["VAULT_DEVICE"] { return id }
    #endif
    if VaultSecrets.isInMemory { return UUID().uuidString.lowercased() }
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
      // Out of reach, so this id is the process's own: see `isProvisional`.
      noteProvisional(id)
      return id
    }
  }()

  private static let provisionalLock = NSLock()
  nonisolated(unsafe) private static var provisionalIDs: Set<String> = []

  /// Whether this is an id made up for this process because the keychain was out of reach: nothing else on the device goes
  /// by it, so a stamp not matching it says nothing about who wrote it. Doesn't touch the keychain.
  static func isProvisional(_ id: String) -> Bool { provisionalLock.withLock { provisionalIDs.contains(id) } }

  static func noteProvisional(_ id: String) { provisionalLock.withLock { _ = provisionalIDs.insert(id) } }

  /// The device's name everywhere v57 shows it (the Hub, its SSH key's comment, `authorized_keys` lines, the hosts
  /// other devices see): the one the user gave it in the vault (`VaultStore.renameDevice`), else the system's.
  /// Observable: a view that shows it redraws when it changes.
  @MainActor public static var name: String { DeviceName.shared.custom ?? systemName }

  /// The name the user gave this device in the vault (`VaultDeviceKey.customName`), nil while it goes by the system's.
  /// The Personal vault sets it when it loads.
  @MainActor public internal(set) static var customName: String? {
    get { DeviceName.shared.custom }
    set { if DeviceName.shared.custom != newValue { DeviceName.shared.custom = newValue } }
  }

  /// The name the system gives the device ("Dmitry's MacBook Pro").
  @MainActor public static var systemName: String {
    #if os(macOS)
      Host.current().localizedName ?? "Mac"
    #elseif canImport(UIKit)
      UIDevice.current.name
    #else
      ProcessInfo.processInfo.hostName
    #endif
  }

  /// The IPv4 and IPv6 addresses of the device's network interfaces now, its Hub Network overlay address among them
  /// while that's connected. Empty where it can't tell (Windows).
  public static var addresses: Set<String> {
    #if canImport(Darwin) || canImport(Glibc)
      var list: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&list) == 0, let first = list else { return [] }
      defer { freeifaddrs(list) }
      var addresses: Set<String> = []
      for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let address = entry.pointee.ifa_addr else { continue }
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { continue }
        let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        // Drop the zone of a link-local IPv6 address ("fe80::1%en0").
        addresses.insert(String(String(cString: host).prefix { $0 != "%" }))
      }
      return addresses
    #else
      return []
    #endif
  }
}

/// Where `VaultDevice.customName` lives, observable.
@MainActor @Observable
final class DeviceName {
  static let shared = DeviceName()
  var custom: String?
}
