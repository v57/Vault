import Channel
import Foundation
import Testing
import VaultKit

@testable import VaultHub

/// Auth v2 against a malicious Hub (`Fixtures/malicious-hub.ts`) and the real one behind it. `HUB_E2E_PORT` is hub-server
/// with `a1…`'s device key as an owner; the fixture runs with that Hub's address and the ports in
/// `HUB_EVIL_RELAY_PORT` and `HUB_EVIL_CLAIM_PORT`.
@Suite(.serialized, .enabled(if: liveHubURL != nil && ProcessInfo.processInfo.environment["HUB_EVIL_RELAY_PORT"] != nil))
@MainActor
struct HubAuthLiveTests {
  struct Report: Decodable, Sendable {
    var relayed: Int
    var relayReceived: Int
    var replays: [String]
    var claimReceived: Int
    var claimAsked: Int
  }

  func report(_ port: String) async throws -> Report {
    let client = Channel<Void>().connect(URL(string: "ws://127.0.0.1:\(port)")!)
    defer { client.stop() }
    return try await client.send("report")
  }

  var relayPort: String { ProcessInfo.processInfo.environment["HUB_EVIL_RELAY_PORT"]! }
  var claimPort: String { ProcessInfo.processInfo.environment["HUB_EVIL_CLAIM_PORT"]! }

  func wait(_ what: String, timeout: TimeInterval = 20, _ check: () async throws -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while try await !check() {
      guard Date() < end else {
        Issue.record("timed out waiting for \(what)")
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// A vault on this device, whose device key is the real Hub's owner.
  func directory(_ name: String) throws -> (HubDirectory, Vault) {
    VaultSecrets.useInMemoryStore()
    _ = try HubKeyStore.shareDeviceKey(Data(repeating: 0xa1, count: 32))
    let store = try VaultStore(
      directory: FileManager.default.temporaryDirectory.appending(path: "hub-auth-\(name)-\(UUID().uuidString)"),
      keys: MemoryKeyProvider(), deviceID: name, notifier: nil, owner: name)
    let vault = Vault(store: store)
    return (HubDirectory(vault: vault), vault)
  }

  /// H1 and the relay: the malicious Hub proves the real Hub's key and gets what the app sends a new Hub. Replayed on the
  /// real Hub it is a stranger, though this device's key is an owner there, and it works once.
  @Test func aMaliciousHubReplayingWhatItReceivedGetsNothing() async throws {
    let url = try #require(liveHubURL)
    let (directory, vault) = try directory("relay")
    directory.start()
    defer { directory.stop() }

    // The control: this device's own key is an owner on the real Hub
    var this = HubThisDevice(key: try HubKeyStore.deviceKey())
    this.name = "owner"
    let realRecord = VaultHubServer(id: "real", url: url, connects: ["relay"])
    try vault.store?.save(realRecord)
    vault.reload()
    let owner = HubConnection(
      hub: realRecord, vault: vault, device: this, deviceKey: try HubKeyStore.deviceKey(), clientKey: try HubKeyStore.clientKey())
    owner.start()
    defer { owner.stop() }
    try await wait("the control to be an owner") { owner.isOwner }

    let hub = try directory.add(url: "ws://127.0.0.1:\(relayPort)")
    let evil = try #require(directory.connection(for: hub.id))
    #expect(evil.device.id != this.id)
    try await wait("the relay to get a token") { try await report(relayPort).relayReceived > 0 }
    // A relayed proof holds, so the key is pinned; it decided nothing about the keys, which are this address's own
    #expect(vault.hub(id: hub.id)?.hubKey == vault.hub(id: "real")?.hubKey)
    #expect(directory.keyScope(of: hub) == .address("ws://127.0.0.1:\(relayPort)"))

    try await wait("the replays") { try await report(relayPort).replays.count >= 2 }
    let replays = try await report(relayPort).replays
    #expect(replays[0] != "owner", "the replayed token reached an owner-only API")
    #expect(replays[0].contains("permission") || replays[0].contains("authoriz"), "\(replays[0])")
    #expect(replays[1] != "owner" && !replays[1].contains("permission"), "a second replay should be refused: \(replays[1])")
  }

  /// A server claiming the real Hub's key without proof is asked, and gets no credentials and no pin.
  @Test func aHubClaimingAKeyWithoutProofIsNotPinned() async throws {
    let (directory, vault) = try directory("claim")
    directory.start()
    defer { directory.stop() }
    let before = try await report(claimPort)
    let hub = try directory.add(url: "ws://127.0.0.1:\(claimPort)")
    try await wait("the claim to be asked") { try await report(claimPort).claimAsked > before.claimAsked + 1 }
    let after = try await report(claimPort)
    #expect(after.claimReceived == before.claimReceived)
    #expect(vault.hub(id: hub.id)?.hubKey == nil)
    #expect(directory.connection(for: hub.id)?.status != .connected)
  }

  /// The same server claiming a key that isn't the pinned one, unproven: it still gets nothing, and stays only unproven.
  @Test func aPinnedHubIsNotReplacedByAClaim() async throws {
    let (directory, vault) = try directory("pinned")
    directory.start()
    defer { directory.stop() }
    let before = try await report(claimPort)
    let store = try #require(vault.store)
    let pinned = "MCowBQYDK2VwAyEAiojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w="
    let hub = VaultHubServer(id: "pinned", url: "ws://127.0.0.1:\(claimPort)", hubKey: pinned, connects: ["pinned"])
    try store.save(hub)
    vault.reload()
    directory.refresh()
    try await wait("the claim to be asked") { try await report(claimPort).claimAsked > before.claimAsked + 1 }
    #expect(try await report(claimPort).claimReceived == before.claimReceived)
    #expect(vault.hub(id: "pinned")?.hubKey == pinned)
  }
}
