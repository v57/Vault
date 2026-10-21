import Foundation
import Observation
import VaultHub
import VaultKit

/// A Hub as the Hub screen shows it: the record, this device's connection to it, its devices and the ones waiting.
struct HubItem: Identifiable, Hashable {
  enum Status: Hashable {
    /// This device doesn't connect to it (another one does).
    case off
    case connecting, connected, needsApproval, wrongHub, offline
  }

  var record: VaultHubServer
  var status: Status
  var devices: [VaultHubDevice] = []
  var pending: [HubPendingDevice] = []
  var isOwner = false
  var securityMode: String?
  var error: String?
  /// Record sync through this Hub on this device, and how it went ("Synced just now · 3 in").
  var syncsRecords = false
  var recordSyncLine = ""

  var id: String { record.id }
  var name: String { record.displayName }
}

/// This device as every Hub sees it.
struct HubIdentity: Hashable {
  var id: String
  var safetyCode: String
}

/// The user's Hubs: adding one, turning it on for this device, approving and revoking devices.
@MainActor
protocol HubEngine: AnyObject {
  var hubs: [HubItem] { get }
  var identity: HubIdentity? { get }
  var error: String? { get }
  func add(url: String, name: String) throws
  func setConnects(_ hubID: String, _ on: Bool)
  func setSyncs(_ hubID: String, _ on: Bool)
  func remove(_ hubID: String)
  func approve(_ deviceID: String, on hubID: String) async
  func deny(_ deviceID: String, on hubID: String) async
  func revoke(_ deviceID: String, on hubID: String) async
}

/// The Hubs through VaultHub: real connections, only to Hubs the user added and turned on here.
@MainActor
final class LiveHubs: HubEngine {
  let directory: HubDirectory

  init(directory: HubDirectory) {
    self.directory = directory
  }

  var hubs: [HubItem] {
    directory.vault.hubs.map { record in
      guard record.connects(on: directory.vault.deviceID), let connection = directory.connection(for: record.id) else {
        return HubItem(record: record, status: .off)
      }
      return HubItem(
        record: record, status: Self.status(connection.status), devices: connection.devices,
        pending: connection.pending, isOwner: connection.isOwner, securityMode: connection.securityMode,
        error: connection.error, syncsRecords: record.syncs.contains(directory.vault.deviceID),
        recordSyncLine: Self.line(connection.recordSync))
    }
  }

  private static func line(_ sync: HubConnection.RecordSync) -> String {
    switch sync {
    case .off: ""
    case .syncing: "Syncing…"
    case .synced(let date, let sent, let received):
      ["Synced \(RelativeTime.short(date))", sent > 0 ? "\(sent) out" : "", received > 0 ? "\(received) in" : ""]
        .filter { !$0.isEmpty }.joined(separator: " · ")
    case .unavailable(let reason): reason
    }
  }

  var identity: HubIdentity? { directory.thisDevice.map { HubIdentity(id: $0.id, safetyCode: $0.safetyCode) } }
  var error: String? { directory.error }

  func add(url: String, name: String) throws { try directory.add(url: url, name: name) }

  func setConnects(_ hubID: String, _ on: Bool) {
    if let hub = directory.vault.hub(id: hubID) { directory.setConnects(hub, on) }
  }

  func setSyncs(_ hubID: String, _ on: Bool) {
    if let hub = directory.vault.hub(id: hubID) { directory.setSyncs(hub, on) }
  }

  func remove(_ hubID: String) {
    if let hub = directory.vault.hub(id: hubID) { directory.remove(hub) }
  }

  func approve(_ deviceID: String, on hubID: String) async { await directory.connection(for: hubID)?.approve(deviceID) }
  func deny(_ deviceID: String, on hubID: String) async { await directory.connection(for: hubID)?.deny(deviceID) }
  func revoke(_ deviceID: String, on hubID: String) async { await directory.connection(for: hubID)?.revoke(deviceID) }

  private static func status(_ status: HubConnection.Status) -> HubItem.Status {
    switch status {
    case .connecting: .connecting
    case .connected: .connected
    case .needsApproval: .needsApproval
    case .wrongHub: .wrongHub
    case .offline: .offline
    }
  }
}

/// Sample Hubs for `--demo`: a home Hub with a Mac Studio, a Linux VM on it, a NAS, an offline Android tablet and a
/// ThinkPad waiting to join. Its SSH devices are mirrored into the demo vault's hosts like the live ones.
@MainActor
@Observable
final class DemoHubs: HubEngine {
  private(set) var hubs: [HubItem] = []
  let identity: HubIdentity? = HubIdentity(id: "5d1e0c7a9b2f43e8a1c6d4b7e9f02a31", safetyCode: "318 604")
  let error: String? = nil
  @ObservationIgnored private let vault: Vault

  static let studioKey =
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLCMdXLYdMyZCS2rOzcgJMOt87l22HK0AUGoqzCFfczoDEf1JCKCAs+9ydUUXYTUWpuXqD95SbzTwGRoNxHGcMU="
  static let builderKey =
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDQtoM8yj77ua8p9tI4mH0LcOFWOzT0wUwLLtL5dDUOB0+4GIz2Aq6siPRVnYbdpE/zKA0Gu2wgcMQhNDHMKj8M="
  static let nasKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIE5dw6ofRdfVqNUZsNMfszLjYqRtO43ol32D1uPybOU"

  init(vault: Vault) {
    self.vault = vault
    let now = Date.now
    let home = VaultHubServer(id: "demo-hub-home", name: "Home Hub", url: "wss://hub.home.arpa", hubKey: "demo", connects: [vault.deviceID])
    let playground = VaultHubServer(id: "demo-hub-playground", url: "wss://hub.v57.dev", order: 1)
    vault.perform { store in
      try store.save(home)
      try store.save(playground)
    }
    let devices = [
      VaultHubDevice(
        id: "8cef065b7af83669150b7d32704d3d3e", name: "Mac Studio", platform: "macos", os: "27.0", arch: "arm64",
        isOnline: true, isNetworkOnline: true, address: "100.96.0.4", lastSeen: now,
        ssh: .init(port: 22, hostKey: Self.studioKey, user: "dmitry"),
        tools: ["xcode": "27.0", "swift": "6.3", "simulators": "iPhone 18 Pro, iPad Pro 13-inch"],
        services: ["hub-launcher", "s3-local/Backup Disk", "dev-runner"]),
      VaultHubDevice(
        id: "2b7f1e90c4d35a68e1f0b2c9d7a46e15", name: "builder", platform: "linux", os: "Ubuntu 26.04", arch: "arm64",
        parent: "Mac Studio", isOnline: true, isNetworkOnline: true, address: "100.96.0.11", lastSeen: now,
        ssh: .init(port: 22, hostKey: Self.builderKey, user: "ci"), tools: ["swift": "6.3", "docker": "yes"],
        services: ["dev-runner"]),
      VaultHubDevice(
        id: "c0a4e7d1f9b2683e5a7c1d0f4b9e2a76", name: "nas", platform: "linux", os: "Debian 13", arch: "x86_64",
        isOnline: true, isNetworkOnline: true, address: "100.96.0.6", lastSeen: now.addingTimeInterval(-40),
        ssh: .init(port: 2222, hostKey: Self.nasKey, user: "admin"), services: ["hub-s3-local"]),
      VaultHubDevice(
        id: "f3b9d2e0a1c7465e8b0f9d3a2c1e7b54", name: "Galaxy Tab", platform: "android", os: "Android 17",
        isOnline: false, lastSeen: now.addingTimeInterval(-3 * 86400)),
      VaultHubDevice(
        id: identity!.id, name: VaultDevice.name,
        platform: ThisDevice.word == "iPad" ? "ipados" : ThisDevice.word == "iPhone" ? "ios" : "macos", os: "27.0",
        arch: "arm64", isOnline: true,
        isNetworkOnline: true, address: "100.96.0.2", lastSeen: now),
    ]
    let pending = [
      HubPendingDevice(
        id: "9e4c2a7f1b0d3e58c6a9f2b1d0e7c435", name: "ThinkPad X1", platform: "windows", safetyCode: "702 115",
        firstSeen: now.addingTimeInterval(-120))
    ]
    hubs = [
      HubItem(
        record: home, status: .connected, devices: devices, pending: pending, isOwner: true,
        securityMode: "default-deny", syncsRecords: true, recordSyncLine: "Synced 1 min ago · 3 in"),
      HubItem(record: playground, status: .off),
    ]
    mirror()
  }

  private func mirror() {
    for hub in hubs where hub.status != .off {
      vault.perform { try $0.mirrorHubDevices(hub.devices, hubID: hub.id, thisDevice: identity?.id) }
    }
  }

  func add(url: String, name: String) throws {
    guard let url = HubDirectory.normalized(url) else { throw HubDirectoryError.badAddress }
    let record = VaultHubServer(name: name, url: url, connects: [vault.deviceID], order: hubs.count)
    vault.save(record)
    hubs.append(HubItem(record: record, status: .connecting))
  }

  func setSyncs(_ hubID: String, _ on: Bool) {
    guard let index = hubs.firstIndex(where: { $0.id == hubID }) else { return }
    hubs[index].syncsRecords = on
    hubs[index].recordSyncLine = on ? "Syncing…" : ""
  }

  func setConnects(_ hubID: String, _ on: Bool) {
    guard let index = hubs.firstIndex(where: { $0.id == hubID }) else { return }
    hubs[index].status = on ? (hubs[index].devices.isEmpty ? .connecting : .connected) : .off
  }

  func remove(_ hubID: String) {
    hubs.removeAll { $0.id == hubID }
    vault.perform { store in
      try store.forgetHubHosts(hubID: hubID)
      try store.delete(id: hubID)
    }
  }

  func approve(_ deviceID: String, on hubID: String) async {
    guard let index = hubs.firstIndex(where: { $0.id == hubID }),
      let waiting = hubs[index].pending.first(where: { $0.id == deviceID })
    else { return }
    hubs[index].pending.removeAll { $0.id == deviceID }
    hubs[index].devices.append(
      VaultHubDevice(id: waiting.id, name: waiting.name, platform: waiting.platform, isOnline: true, lastSeen: .now))
    mirror()
  }

  func deny(_ deviceID: String, on hubID: String) async {
    guard let index = hubs.firstIndex(where: { $0.id == hubID }) else { return }
    hubs[index].pending.removeAll { $0.id == deviceID }
  }

  func revoke(_ deviceID: String, on hubID: String) async {
    guard let index = hubs.firstIndex(where: { $0.id == hubID }),
      let device = hubs[index].devices.firstIndex(where: { $0.id == deviceID })
    else { return }
    hubs[index].devices[device].isRevoked = true
    hubs[index].devices[device].isOnline = false
    mirror()
  }
}
