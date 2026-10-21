import Channel
import Foundation
import HubService
import Observation
import VaultKit

#if canImport(UIKit)
  import UIKit
#endif

/// One Hub, while this app runs: connected as this device, its device directory mirrored into the vault's hosts, and
/// the requests of devices waiting to join.
///
/// It talks to the Hub in-process (no helper) and stops when the app quits or the user turns the Hub off on this
/// device. The Hub learns this device's keys, names and presence; it never sees vault data.
@MainActor
@Observable
public final class HubConnection: Identifiable {
  public enum Status: Equatable, Sendable {
    case connecting
    case connected
    /// Connected, but the Hub doesn't let this device read its directory yet: an owner approves it (the safety
    /// code), or grants it `hub/devices`.
    case needsApproval
    /// The server at the address isn't the Hub that was pinned.
    case wrongHub
    case offline
  }

  public nonisolated let id: String
  public private(set) var status = Status.connecting
  /// The Hub's devices, this one included.
  public private(set) var devices: [VaultHubDevice] = []
  /// Devices waiting for approval; empty unless this device is an owner.
  public private(set) var pending: [HubPendingDevice] = []
  /// Whether the Hub lets this device approve and revoke devices.
  public private(set) var isOwner = false
  /// "default-allow" or "default-deny", from `hub/info`.
  public private(set) var securityMode: String?
  /// Why the last call failed, for the UI.
  public var error: String?

  /// Record sync through this Hub (`HubSync` on the `hub-vault` service), when this device turned it on.
  public enum RecordSync: Equatable, Sendable {
    case off
    case syncing
    case synced(Date, sent: Int, received: Int)
    /// The Hub can't carry records: no `hub-vault` service, or this device isn't allowed yet.
    case unavailable(String)
  }

  public private(set) var recordSync = RecordSync.off

  /// This device on the Hub.
  public let device: HubThisDevice

  @ObservationIgnored private let vault: Vault
  @ObservationIgnored private let deviceKey: HubKey
  @ObservationIgnored private let clientKey: HubKey
  @ObservationIgnored private var client: ClientSender<Void>?
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var stateObserver: (any _Cancellable)?

  init(hub: VaultHubServer, vault: Vault, device: HubThisDevice, deviceKey: HubKey, clientKey: HubKey) {
    id = hub.id
    self.vault = vault
    self.device = device
    self.deviceKey = deviceKey
    self.clientKey = clientKey
  }

  var hub: VaultHubServer? { vault.hub(id: id) }

  // MARK: Connecting

  func start() {
    guard client == nil, let hub, let url = URL(string: hub.url) else { return }
    let channel = Channel<Void>()
    let client = channel.connect(
      url,
      options: ClientOptions(
        headers: { [weak self] in self?.headers() ?? [:] },
        onConnect: { [weak self] _ in await self?.didConnect() }))
    self.client = client
    stateObserver = client.onStateChange { [weak self] state in self?.stateChanged(state) }
    tasks = [
      Task { [weak self] in await self?.followDevices() },
      Task { [weak self] in await self?.followPending() },
      Task { [weak self] in await self?.syncRecords() },
      Task { [weak self] in await self?.followVaultChanges() },
    ]
  }

  func stop() {
    tasks.forEach { $0.cancel() }
    tasks = []
    stateObserver = nil
    client?.stop()
    client = nil
    status = .offline
  }

  /// Headers for each connection attempt: v1 auth once the Hub's key is pinned, and this device's certificate.
  private func headers() -> [String: String] {
    let now = Int(Date().timeIntervalSince1970)
    let hubKey = hub?.hubKey
    return [
      "v": hubKey == nil ? "0" : "1",
      "auth": HubWire.auth(clientKey, hubKey: hubKey, expiry: now + 60),
      "device": HubWire.certificate(
        device: deviceKey, service: clientKey.spki, instance: "v57", deviceName: device.name,
        platform: device.platform, issued: now),
    ]
  }

  private func stateChanged(_ state: ConnectionState) {
    switch state {
    case .connected: if status == .offline || status == .connecting { status = .connected }
    case .disconnected: if status != .wrongHub { status = .offline }
    default: if status != .wrongHub { status = .connecting }
    }
  }

  private func didConnect() async {
    guard let client else { return }
    if status != .needsApproval { status = .connected }
    try? await client.send("hub/profile/update", HubWire.Profile(name: device.name, icon: .plain(symbol: "lock.shield")))
    // Pin the Hub's key on the first connection and use v1 from the next (protocol §2).
    guard let info: HubWire.Info = try? await client.send("hub/info") else { return }
    securityMode = info.mode
    guard var hub else { return }
    // Tell the other devices which Hub device this vault device is (a project's folder on it, for remote builds).
    if hub.members[vault.deviceID] != device.id {
      hub.members[vault.deviceID] = device.id
      vault.save(hub)
    }
    if let pinned = hub.hubKey {
      if pinned != info.key {
        status = .wrongHub
        stop()
        status = .wrongHub
      }
    } else {
      hub.hubKey = info.key
      vault.save(hub)
      client.reconnectNow()
    }
  }

  // MARK: The directory

  /// Follows `hub/devices`, mirroring each list into the vault's hosts. A Hub that refuses (this device isn't
  /// approved yet) is asked again later.
  private func followDevices() async {
    while !Task.isCancelled, let client {
      do {
        for try await list in client.values("hub/devices", as: [HubWire.Device].self) {
          receive(list)
        }
      } catch {
        if Self.isPermission(error) { status = .needsApproval }
      }
      try? await Task.sleep(for: .seconds(20))
    }
  }

  private func followPending() async {
    while !Task.isCancelled, let client {
      do {
        for try await list in client.values("hub/devices/pending", as: [HubWire.PendingDevice].self) {
          isOwner = true
          pending = list.map(HubPendingDevice.init)
        }
      } catch {
        if Self.isPermission(error) {
          isOwner = false
          pending = []
        }
      }
      try? await Task.sleep(for: .seconds(60))
    }
  }

  /// A new list from the Hub: the devices for the UI, the SSH ones as hosts for every app.
  func receive(_ list: [HubWire.Device]) {
    if status == .needsApproval || status == .connecting { status = .connected }
    devices = list.map(VaultHubDevice.init).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    vault.perform { try $0.mirrorHubDevices(devices, hubID: id, thisDevice: device.id) }
  }

  private static func isPermission(_ error: any Error) -> Bool {
    let text = (error as? ChannelError)?.text ?? "\(error)"
    return text.contains("permission") || text.contains("not allowed") || text.contains("unauthorized")
  }

  // MARK: Record sync

  @ObservationIgnored private var recordSyncer: HubSync?
  @ObservationIgnored private var syncedRevision: Int64 = -1
  @ObservationIgnored private var remoteLast = 0
  @ObservationIgnored private var lastSync = Date.distantPast

  /// Whether this device syncs records through this Hub.
  private var syncsRecords: Bool { hub?.syncs.contains(vault.deviceID) == true }

  /// Syncs when the vault changed here, another device pushed, or five minutes passed, while connected and turned on.
  private func syncRecords() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(2))
      guard syncsRecords else {
        if recordSync != .off { recordSync = .off }
        continue
      }
      guard status == .connected, let client, let store = vault.store else { continue }
      let syncer = recordSyncer ?? HubSync(store: store, mailbox: HubVaultMailbox(client: client), deviceID: device.id)
      recordSyncer = syncer
      let due = store.revision != syncedRevision || remoteLast > 0 || Date().timeIntervalSince(lastSync) > 300
      guard due else { continue }
      if case .unavailable = recordSync, Date().timeIntervalSince(lastSync) < 60 { continue }
      recordSync = .syncing
      remoteLast = 0
      lastSync = Date()
      do {
        let result = try await Task.detached { try await syncer.sync() }.value
        syncedRevision = store.revision
        recordSync = .synced(Date(), sent: result.sent, received: result.received)
        if result.received > 0 { vault.reload() }
      } catch {
        let text = (error as? ChannelError)?.text ?? error.localizedDescription
        recordSync = .unavailable(
          text.contains("api not found") ? "This Hub has no vault service (hub-vault)." : text)
      }
    }
  }

  /// Wakes the record sync when another device pushed.
  private func followVaultChanges() async {
    while !Task.isCancelled {
      if syncsRecords, status == .connected, let client, let vaultID = try? recordSyncer?.vaultID() {
        do {
          let changes: Values<Void, HubVaultMailbox.VaultBody, EmptyCodable, VaultChange> =
            client.values("vault/changes", HubVaultMailbox.VaultBody(vault: vaultID))
          for try await change in changes {
            if change.last > 0 { remoteLast = change.last }
          }
        } catch {}
      }
      try? await Task.sleep(for: .seconds(10))
    }
  }

  private struct VaultChange: Decodable, Sendable { var last: Int }

  // MARK: Owner actions

  /// Lets a waiting device in. Compare the safety code on both screens first.
  public func approve(_ deviceID: String) async {
    await call("hub/device/approve", HubWire.ID(id: deviceID))
  }

  /// Turns a waiting device away; it can ask again.
  public func deny(_ deviceID: String) async {
    await call("hub/device/remove", HubWire.ID(id: deviceID))
  }

  /// Removes a device for good: it can't connect again, its services' keys stop working and Hub Network drops it.
  /// Its hosts go from every app on the next directory update.
  public func revoke(_ deviceID: String) async {
    await call("hub/device/revoke", HubWire.ID(id: deviceID))
  }

  public func rename(_ deviceID: String, to name: String) async {
    await call("hub/device/rename", HubWire.Rename(id: deviceID, name: name))
  }

  private func call<Body: Encodable & Sendable>(_ path: String, _ body: Body) async {
    guard let client else { return }
    do {
      let _: EmptyCodable? = try await client.send(path, body)
      error = nil
    } catch {
      self.error = (error as? ChannelError)?.text ?? error.localizedDescription
    }
  }
}

/// This device as the Hub sees it.
public struct HubThisDevice: Sendable, Hashable {
  /// The Hub's device id.
  public var id: String
  /// The code an owner compares when approving it.
  public var safetyCode: String
  public var name: String
  public var platform: String

  @MainActor
  init(key: HubKey) {
    id = HubKey.deviceID(spki: key.spki) ?? ""
    safetyCode = HubKey.safetyCode(spki: key.spki) ?? ""
    name = VaultDevice.name
    #if os(macOS)
      platform = "macos"
    #elseif canImport(UIKit)
      platform = UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
    #else
      platform = "other"
    #endif
  }
}
