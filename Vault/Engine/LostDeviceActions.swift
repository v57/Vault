import Foundation
import SSHKit
import VaultKit
import VaultUI

/// What the Vault app adds to Lost Device: revoking on the Hubs it connects to, and taking the device's lines off other
/// machines over SSH. Everything here runs at the user's click; opening the sheet contacts nothing.
@MainActor
enum LostDeviceActions {
  static func make(for device: VaultDeviceKey, app: AppModel) -> VaultLostDeviceActions {
    let vault = app.deviceVault
    return VaultLostDeviceActions(hubs: app.hubs.hubs.map { hub(for: device, on: $0, app: app) }, servers: servers(for: device, in: vault))
  }

  private static func hub(for device: VaultDeviceKey, on hub: HubItem, app: AppModel) -> VaultLostDeviceActions.Action {
    // Read now: revoking takes the device out of the Hub's record.
    let hubDevice = hub.record.members[device.id]
    let unavailable: String? =
      if hubDevice == nil {
        String(localized: "It isn’t a member of this Hub, as far as your vault knows.")
      } else if hub.status != .connected {
        String(localized: "This \(ThisDevice.word) isn’t connected to it. Revoke it from a device that is.")
      } else if !hub.isOwner {
        String(localized: "Only this Hub’s owner can revoke a device.")
      } else {
        nil
      }
    return VaultLostDeviceActions.Action(
      id: "hub.\(hub.id)", name: hub.name, systemImage: "server.rack", unavailable: unavailable
    ) { [hubs = app.hubs] in
      guard let hubDevice else { return "" }
      await hubs.revoke(hubDevice, on: hub.id)
      let now = hubs.hubs.first { $0.id == hub.id }?.devices.first { $0.id == hubDevice }
      if now?.isRevoked == true || now == nil { return String(localized: "Revoked on \(hub.name).") }
      return String(localized: "Asked \(hub.name) to revoke it. It hasn’t confirmed yet: check its device list.")
    }
  }

  private static func servers(for device: VaultDeviceKey, in vault: Vault) -> [VaultLostDeviceActions.Action] {
    guard let command = VaultAuthorizedKeys.sweepCommand(device: device.id, publicKey: device.publicKey) else { return [] }
    return vault.hosts
      .filter { !vault.isThisDevice($0) && vault.vaultDevice(of: $0) != device.id && !$0.hostname.isEmpty }
      .map { host in
        VaultLostDeviceActions.Action(id: "server.\(host.id)", name: host.displayName, systemImage: "terminal") {
          try await sweep(command, on: host, in: vault)
        }
      }
  }

  private static func sweep(_ text: String, on host: VaultHost, in vault: Vault) async throws -> String {
    let collected = Collected()
    let status = try await SSHCommand(server: try server(for: host, in: vault), command: text).run { collected.append($0) }
    guard status == 0, let lines = VaultAuthorizedKeys.sweptLines(from: collected.text) else {
      throw SweepError(host: host.displayName)
    }
    return lines == 0 ? String(localized: "It wasn’t there.") : String(localized: "Took out \(lines) lines.")
  }

  /// This device's key or the saved password, and only a host key the user already accepted: a sweep doesn't stop to
  /// ask, and it isn't the moment to trust a server for the first time.
  private static func server(for host: VaultHost, in vault: Vault) throws -> SSHServer {
    let trust = SSHHostTrust.known(vault.knownHost(for: host)?.fingerprint, otherwise: .refuseUnknown)
    let user = host.user.isEmpty ? NSUserName() : host.user
    let fallbacks = vault.fallbackAddresses(of: host)
    if host.auth == .password {
      return SSHServer(
        host: host.hostname, fallbackHosts: fallbacks, port: host.port, user: user,
        password: VaultSecrets.password(for: host.id), trust: trust)
    }
    let key = try VaultIdentity.key()
    let sshKey = SSHKey(
      kind: .ecdsaP256, publicKeyBlob: Array(VaultIdentity.publicKeyBlob(key)), comment: VaultDevice.name,
      prepare: VaultIdentity.presencePrompt()
    ) { data in
      Array(try VaultIdentity.sshSignature(Data(data), key: key))
    }
    return SSHServer(host: host.hostname, fallbackHosts: fallbacks, port: host.port, user: user, key: sshKey, trust: trust)
  }

  private struct SweepError: LocalizedError {
    let host: String
    var errorDescription: String? { "\(host) signed in but didn’t finish. Check its ~/.ssh/authorized_keys yourself." }
  }

  private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
  }
}
