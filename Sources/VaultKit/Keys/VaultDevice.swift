import Foundation

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
