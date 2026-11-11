import Foundation
import HubService
import Observation
import VaultKit

/// The Hubs this device connects to, kept in step with the vault's `VaultHubServer` records: a Hub turned on for this
/// device connects, one turned off or removed disconnects.
///
/// Nothing connects until the user adds a Hub (off by default; the apps never pick one, the v57.dev playground
/// included). The app that holds the directory mirrors each Hub's devices into the vault's hosts, which every other
/// app reads through VaultKit alone.
@MainActor
@Observable
public final class HubDirectory {
  public private(set) var connections: [String: HubConnection] = [:]
  /// Why this device can't connect (its keys couldn't be read or made).
  public private(set) var error: String?

  @ObservationIgnored public let vault: Vault
  @ObservationIgnored private var keys: [HubKeyScope: (device: HubKey, client: HubKey)] = [:]
  /// Whether `start` ran: the app starts the directory once the user opens something that shows the Hubs.
  public private(set) var isStarted = false

  public init(vault: Vault) {
    self.vault = vault
  }

  /// Connects the Hubs turned on for this device, and follows the records from then on.
  public func start() {
    guard !isStarted else { return }
    isStarted = true
    // Records made before they carried their identity get it now, so duplicates of one Hub fold into one.
    vault.perform { store in
      for hub in vault.hubs where (try? store.item(id: hub.id))?.values["_identity"] == nil { try store.save(hub) }
    }
    refresh()
    observeDeviceName()
  }

  public func stop() {
    isStarted = false
    connections.values.forEach { $0.stop() }
    connections = [:]
  }

  public func connection(for hubID: String?) -> HubConnection? {
    hubID.flatMap { connections[$0] }
  }

  /// This device on a Hub, once its key exists. A Hub added since auth v2 knows it by an id of its own.
  public func thisDevice(on hub: VaultHubServer) -> HubThisDevice? {
    guard let scope = keyScope(of: hub), let key = try? loadKeys(scope).device else { return nil }
    return HubThisDevice(key: key)
  }

  /// This device on the Hubs that keep the keys from before auth v2.
  public var thisDevice: HubThisDevice? {
    guard let key = try? loadKeys(.shared).device else { return nil }
    return HubThisDevice(key: key)
  }

  // MARK: Changing Hubs

  /// Adds a Hub at a WebSocket address and connects this device to it, with keys of its own for this address.
  ///
  /// A second address of a Hub this device knows counts as a new Hub, also when it proves the same key: a proof can be
  /// relayed. Use `sameHubAs` only when the address came from that Hub over its authenticated connection, or the user
  /// said so; the new record then uses that Hub's keys. `keys` names them directly, for the app holding them.
  @discardableResult
  public func add(
    url text: String, name: String = "", sameHubAs original: VaultHubServer? = nil, keys: HubKeyScope? = nil
  ) throws -> VaultHubServer {
    guard let url = Self.normalized(text) else { throw HubDirectoryError.badAddress }
    guard let store = vault.store else { throw HubDirectoryError.noVault }
    if let existing = vault.hubs.first(where: { Self.normalized($0.url) == url })
      ?? (try? store.record(VaultHubServer.self, id: VaultHubServer.newID(url: url, in: store)))
    {
      setConnects(existing, true)
      return existing
    }
    let hub = VaultHubServer(
      id: try VaultHubServer.newID(url: url, in: store), name: name, url: url, connects: [vault.deviceID],
      order: vault.hubs.count)
    guard let scope = keys ?? original.flatMap(keyScope) ?? HubAddress.canonical(url).map(HubKeyScope.address) else {
      throw HubDirectoryError.badAddress
    }
    try store.save(hub)
    try store.save(id: hub.id, kind: VaultHubServer.kind, changes: [Self.keysField: .string(scope.field)])
    vault.reload()
    refresh()
    return hub
  }

  /// Turns the Hub on or off for this device. Its hosts stay while other devices connect to it.
  public func setConnects(_ hub: VaultHubServer, _ on: Bool) {
    var hub = vault.hub(id: hub.id) ?? hub
    if on { hub.connects.insert(vault.deviceID) } else { hub.connects.remove(vault.deviceID) }
    vault.save(hub)
    refresh()
  }

  /// Turns record sync through the Hub on or off for this device (the Hub needs the `hub-vault` service).
  public func setSyncs(_ hub: VaultHubServer, _ on: Bool) {
    var hub = vault.hub(id: hub.id) ?? hub
    if on { hub.syncs.insert(vault.deviceID) } else { hub.syncs.remove(vault.deviceID) }
    vault.save(hub)
  }

  /// Removes the Hub from every device, with the hosts it added.
  public func remove(_ hub: VaultHubServer) {
    connections[hub.id]?.stop()
    connections[hub.id] = nil
    vault.perform { store in
      try store.forgetHubHosts(hubID: hub.id)
      try store.delete(id: hub.id)
    }
  }

  /// Forgets the pinned key, for a Hub whose key changed on purpose (it was reinstalled). Whatever answers there next is
  /// a new Hub to this device, so a record on the old shared keys moves to keys of its own.
  public func forgetKey(of hub: VaultHubServer) {
    var hub = vault.hub(id: hub.id) ?? hub
    hub.hubKey = nil
    vault.save(hub)
    if keyScope(of: hub) == .shared, let address = HubAddress.canonical(hub.url), let store = vault.store {
      try? store.save(id: hub.id, kind: VaultHubServer.kind, changes: [Self.keysField: .string(HubKeyScope.address(address).field)])
    }
    connections[hub.id]?.stop()
    connections[hub.id] = nil
    refresh()
  }

  /// Starts and stops connections to match the records.
  public func refresh() {
    guard isStarted else { return }
    // Hosts of a Hub this store knows was removed, or folded into its twin, go too. A Hub that's merely not here doesn't
    // count (`VaultStore.removedHubs`).
    let unlisted = Set(vault.hubHosts.compactMap(\.hub?.hubID)).subtracting(vault.hubs.map(\.id))
    if !unlisted.isEmpty, let removed = vault.store?.removedHubs(among: unlisted), !removed.isEmpty {
      vault.perform { store in for hubID in removed { try store.forgetHubHosts(hubID: hubID) } }
    }
    let wanted = Set(vault.hubs.filter { $0.connects(on: vault.deviceID) }.map(\.id))
    for (id, connection) in connections where !wanted.contains(id) {
      connection.stop()
      connections[id] = nil
    }
    guard !wanted.isEmpty else { return }
    do {
      error = nil
      for hub in vault.hubs where wanted.contains(hub.id) && connections[hub.id] == nil {
        guard let scope = keyScope(of: hub) else { continue }
        let keys = try loadKeys(scope)
        let connection = HubConnection(
          hub: hub, vault: vault, device: HubThisDevice(key: keys.device), deviceKey: keys.device, clientKey: keys.client)
        connections[hub.id] = connection
        connection.start()
      }
    } catch {
      self.error = error.localizedDescription
    }
    observeHubs()
  }

  /// The field of a Hub record that says which keys it uses. A record's other fields survive any app saving it.
  nonisolated static let keysField = "keys"

  /// Which keys a record uses, written to it the first time: a record pinned before the field existed was approved with
  /// the shared keys and keeps them, and every other record gets keys of its own before anything connects.
  public func keyScope(of hub: VaultHubServer) -> HubKeyScope? {
    guard let store = vault.store else { return nil }
    if case .string(let field)? = (try? store.item(id: hub.id))?.values[Self.keysField] { return HubKeyScope(field: field) }
    let scope: HubKeyScope
    if hub.hubKey != nil {
      scope = .shared
    } else if let address = HubAddress.canonical(hub.url) {
      scope = .address(address)
    } else {
      return nil
    }
    try? store.save(id: hub.id, kind: VaultHubServer.kind, changes: [Self.keysField: .string(scope.field)])
    return scope
  }

  private func loadKeys(_ scope: HubKeyScope) throws -> (device: HubKey, client: HubKey) {
    if let keys = keys[scope] { return keys }
    let loaded = try HubKeyStore.keys(for: scope)
    keys[scope] = loaded
    return loaded
  }

  /// Connects again when the user renames this device (`VaultDevice.name`): each connection's certificate carries
  /// the name, and the Hub takes it from there.
  private func observeDeviceName() {
    withObservationTracking { _ = VaultDevice.name } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.isStarted else { return }
        self.connections.values.forEach { $0.stop() }
        self.connections = [:]
        self.refresh()
        self.observeDeviceName()
      }
    }
  }

  /// Refreshes when another app or device changes the Hub records.
  private func observeHubs() {
    withObservationTracking {
      _ = vault.hubs
      // A host of a Hub removed elsewhere can land after the Hub's tombstone.
      _ = vault.hubHosts
    } onChange: { [weak self] in
      Task { @MainActor in self?.refresh() }
    }
  }

  /// The address as the SDKs dial it (protocol §2): a bare port is the local Hub, http(s) become ws(s), lowercased
  /// scheme and host, no trailing slash.
  public nonisolated static func normalized(_ text: String) -> String? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(text), (1...65535).contains(port) { return "ws://localhost:\(port)" }
    if !text.contains("://") { text = "wss://\(text)" }
    guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
      let host = components.host, !host.isEmpty
    else { return nil }
    switch scheme {
    case "ws", "wss": components.scheme = scheme
    case "http": components.scheme = "ws"
    case "https": components.scheme = "wss"
    default: return nil
    }
    components.host = host.lowercased()
    while components.path.hasSuffix("/") { components.path.removeLast() }
    return components.string
  }
}

public enum HubDirectoryError: LocalizedError {
  case badAddress, noVault

  public var errorDescription: String? {
    switch self {
    case .badAddress: "That isn’t a Hub address. Use ws://, wss:// or a port number."
    case .noVault: "The vault couldn’t be opened."
    }
  }
}
