import Foundation
import Testing

@testable import VaultHub
@testable import VaultKit

/// Hub decision 11 and security audit M4: the Hub keys move from the shared group to the device group, which only Vault
/// and the Hub app list, without changing: the Hub app's device key and its Hubs must survive the update.
struct HubKeyPlacesTests {
  final class Place: HubKeyStore.Place, @unchecked Sendable {
    var items: [String: Data] = [:]
    let lock = NSLock()
    func read(_ account: String) throws -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, account: String, label: String) throws { lock.withLock { items[account] = data } }
    func addNew(_ data: Data, account: String, label: String) throws {
      try lock.withLock {
        guard items[account] == nil else { throw VaultKeychain.KeychainError.status(-25299) }
        items[account] = data
      }
    }
    func delete(_ account: String) throws { _ = lock.withLock { items.removeValue(forKey: account) } }
  }

  /// The Hub app as the App Store has it (1.0): its key in its own group only, nothing in the v57 groups. The update
  /// lists the device group, and its own key becomes the device's.
  @Test func hub10UpdatesWithItsOwnKey() throws {
    let own = HubKey()
    let device = Place()
    let places = HubKeyStore.Places(device: device, legacy: nil)
    let shared = try HubKeyStore.share(own.seed, in: places)
    #expect(shared.seed == own.seed)
    #expect(device.items[HubKeyStore.deviceKeyAccount] == own.seed)
    // Vault on the same device then connects as the same device.
    #expect(try HubKeyStore.keychainKey(HubKeyStore.deviceKeyAccount, label: "", in: places).seed == own.seed)
  }

  /// A development Hub build (since 2026-10-26) put its key in the shared group, where Vault reads it: Vault moves it,
  /// unchanged, and the shared copy goes.
  @Test func vaultMovesTheKeysOutOfTheSharedGroup() throws {
    let key = HubKey()
    let client = HubKey()
    let shared = Place()
    shared.items = [HubKeyStore.deviceKeyAccount: key.seed, HubKeyStore.clientKeyAccount: client.seed]
    let device = Place()
    let places = HubKeyStore.Places(device: device, legacy: shared)
    #expect(try HubKeyStore.keychainKey(HubKeyStore.deviceKeyAccount, label: "", in: places).seed == key.seed)
    #expect(try HubKeyStore.keychainKey(HubKeyStore.clientKeyAccount, label: "", in: places).seed == client.seed)
    #expect(shared.items.isEmpty)
    #expect(device.items == [HubKeyStore.deviceKeyAccount: key.seed, HubKeyStore.clientKeyAccount: client.seed])

    // The updated Hub app, now without the shared group, keeps its own key and makes it the device's.
    let hubPlaces = HubKeyStore.Places(device: device, legacy: nil)
    #expect(try HubKeyStore.share(key.seed, in: hubPlaces).seed == key.seed)
  }

  /// The Hub app's own key wins over one a v57 app made before it, in either group.
  @Test func theHubAppsKeyReplacesAnAppsKey() throws {
    let own = HubKey()
    let shared = Place()
    shared.items[HubKeyStore.deviceKeyAccount] = HubKey().seed
    let device = Place()
    let key = try HubKeyStore.share(own.seed, in: .init(device: device, legacy: shared))
    #expect(key.seed == own.seed)
    #expect(device.items[HubKeyStore.deviceKeyAccount] == own.seed)
    #expect(shared.items.isEmpty)
  }

  /// No key anywhere: one is made in the device group, once.
  @Test func aNewDeviceGetsOneKey() throws {
    let device = Place()
    let places = HubKeyStore.Places(device: device, legacy: Place())
    let first = try HubKeyStore.keychainKey(HubKeyStore.deviceKeyAccount, label: "", in: places)
    let again = try HubKeyStore.keychainKey(HubKeyStore.deviceKeyAccount, label: "", in: places)
    #expect(first.seed == again.seed)
    #expect(try HubKeyStore.share(nil, in: places).seed == first.seed)
  }
}
