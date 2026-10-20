import Foundation
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
  @ObservationIgnored private var keys: (device: HubKey, client: HubKey)?
  @ObservationIgnored private var isStarted = false

  public init(vault: Vault) {
    self.vault = vault
  }

  /// Connects the Hubs turned on for this device, and follows the records from then on.
  public func start() {
    guard !isStarted else { return }
    isStarted = true
    refresh()
  }

  public func stop() {
    isStarted = false
    connections.values.forEach { $0.stop() }
    connections = [:]
  }

  public func connection(for hubID: String?) -> HubConnection? {
    hubID.flatMap { connections[$0] }
  }

  /// This device on the Hubs (the same on all of them), once its key exists.
  public var thisDevice: HubThisDevice? {
    guard let key = try? loadKeys().device else { return nil }
    return HubThisDevice(key: key)
  }

  // MARK: Changing Hubs

  /// Adds a Hub at a WebSocket address and connects this device to it.
  @discardableResult
  public func add(url text: String, name: String = "") throws -> VaultHubServer {
    guard let url = Self.normalized(text) else { throw HubDirectoryError.badAddress }
    guard let store = vault.store else { throw HubDirectoryError.noVault }
    if let existing = vault.hubs.first(where: { Self.normalized($0.url) == url }) {
      setConnects(existing, true)
      return existing
    }
    let hub = VaultHubServer(name: name, url: url, connects: [vault.deviceID], order: vault.hubs.count)
    try store.save(hub)
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

  /// Removes the Hub from every device, with the hosts it added.
  public func remove(_ hub: VaultHubServer) {
    connections[hub.id]?.stop()
    connections[hub.id] = nil
    vault.perform { store in
      try store.forgetHubHosts(hubID: hub.id)
      try store.delete(id: hub.id)
    }
  }

  /// Forgets the pinned key, for a Hub whose key changed on purpose (it was reinstalled).
  public func forgetKey(of hub: VaultHubServer) {
    var hub = vault.hub(id: hub.id) ?? hub
    hub.hubKey = nil
    vault.save(hub)
    connections[hub.id]?.stop()
    connections[hub.id] = nil
    refresh()
  }

  /// Starts and stops connections to match the records.
  public func refresh() {
    guard isStarted else { return }
    let wanted = Set(vault.hubs.filter { $0.connects(on: vault.deviceID) }.map(\.id))
    for (id, connection) in connections where !wanted.contains(id) {
      connection.stop()
      connections[id] = nil
    }
    guard !wanted.isEmpty else { return }
    do {
      let keys = try loadKeys()
      error = nil
      for hub in vault.hubs where wanted.contains(hub.id) && connections[hub.id] == nil {
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

  private func loadKeys() throws -> (device: HubKey, client: HubKey) {
    if let keys { return keys }
    let loaded = (device: try HubKeyStore.deviceKey(), client: try HubKeyStore.clientKey())
    keys = loaded
    return loaded
  }

  /// Refreshes when another app or device changes the Hub records.
  private func observeHubs() {
    withObservationTracking { _ = vault.hubs } onChange: { [weak self] in
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
