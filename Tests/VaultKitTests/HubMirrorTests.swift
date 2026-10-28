import Foundation
import Testing

@testable import VaultKit

struct HubMirrorTests {
  let keys = MemoryKeyProvider()
  static let hostKey =
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLCMdXLYdMyZCS2rOzcgJMOt87l22HK0AUGoqzCFfczoDEf1JCKCAs+9ydUUXYTUWpuXqD95SbzTwGRoNxHGcMU="
  static let otherKey =
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDQtoM8yj77ua8p9tI4mH0LcOFWOzT0wUwLLtL5dDUOB0+4GIz2Aq6siPRVnYbdpE/zKA0Gu2wgcMQhNDHMKj8M="
  static let ed25519Key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO1JKMYo0cLG6ukDOJBZlWEpWSc6XGP5NjbBRhSshzfR"

  init() { VaultSecrets.useInMemoryStore() }

  func studio(address: String = "100.96.0.4", key: String? = hostKey, revoked: Bool = false) -> VaultHubDevice {
    VaultHubDevice(
      id: "8cef065b7af83669150b7d32704d3d3e", name: "Mac Studio", platform: "macos", isRevoked: revoked,
      isOnline: true, address: address, lastSeen: Date(timeIntervalSince1970: 1_792_501_234),
      ssh: .init(port: 22, hostKey: key))
  }

  func store(_ device: String = "mac") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  @Test func sshDevicesBecomeTrustedHosts() throws {
    let store = try store()
    let phone = VaultHubDevice(id: "phone", name: "iPhone", platform: "ios", isOnline: true, address: "100.96.0.9")
    let me = VaultHubDevice(
      id: "me", name: "This Mac", platform: "macos", address: "100.96.0.2", ssh: .init(hostKey: Self.otherKey))
    let changes = try store.mirrorHubDevices([studio(), phone, me], hubID: "hub1", thisDevice: "me")
    #expect(changes.added.count == 1)

    let hosts = try store.records(VaultHost.self)
    let host = try #require(hosts.first)
    #expect(hosts.count == 1)
    #expect(host.name == "Mac Studio")
    #expect(host.hostname == "100.96.0.4")
    #expect(host.source == "hub")
    #expect(host.hub?.deviceID == "8cef065b7af83669150b7d32704d3d3e")
    #expect(host.hub?.lastSeen == Date(timeIntervalSince1970: 1_792_501_200))
    #expect(try store.knownFingerprint(host: "100.96.0.4", port: 22) == VaultIdentity.fingerprint(keyLine: Self.hostKey))

    // The same directory again writes nothing.
    #expect(try store.mirrorHubDevices([studio(), phone, me], hubID: "hub1", thisDevice: "me").isEmpty)
  }

  @Test func aMachineListedTwiceIsOneHost() throws {
    let store = try store()
    // The Hub app reinstalled: a new device took over the address, and the Hub still lists the old one.
    var old = studio()
    old.id = "0ld"
    old.isOnline = false
    old.lastSeen = Date(timeIntervalSince1970: 1_790_000_000)
    try store.mirrorHubDevices([old, studio()], hubID: "hub1")
    var hosts = try store.records(VaultHost.self)
    #expect(hosts.count == 1)
    #expect(hosts.first?.hub?.deviceID == studio().id)

    // Both offline: the last seen stays, and a host the old device had is removed.
    var new = studio()
    new.isOnline = false
    try store.mirrorHubDevices([new, old], hubID: "hub1")
    try store.save(VaultHost(id: try store.hubHostID(hubID: "hub1", deviceID: "0ld"), hostname: "100.96.0.4", source: "hub",
      hub: .init(hubID: "hub1", deviceID: "0ld", deviceName: "Mac Studio")))
    try store.mirrorHubDevices([old, new], hubID: "hub1")
    hosts = try store.records(VaultHost.self)
    #expect(hosts.map(\.hub?.deviceID) == [studio().id])
  }

  @Test func buildSigningOutlivesTheHubsUpdates() throws {
    let store = try store()
    try store.mirrorHubDevices([studio()], hubID: "hub1")
    var host = try #require(try store.records(VaultHost.self).first)
    #expect(host.buildSigning == nil)
    host.buildSigning = .desktopSession
    try store.save(host)

    // The device moves to a new address: the host follows, and keeps how builds there sign.
    try store.mirrorHubDevices([studio(address: "100.96.0.7")], hubID: "hub1")
    host = try #require(try store.records(VaultHost.self).first)
    #expect(host.hostname == "100.96.0.7")
    #expect(host.buildSigning == .desktopSession)
  }

  @Test func renamesFollowTheHubUntilTheUserRenames() throws {
    let store = try store()
    try store.mirrorHubDevices([studio()], hubID: "hub1")
    var renamed = studio()
    renamed.name = "Studio"
    try store.mirrorHubDevices([renamed], hubID: "hub1")
    var host = try #require(try store.records(VaultHost.self).first)
    #expect(host.name == "Studio")

    host.name = "Build box"
    host.user = "me"
    try store.save(host)
    renamed.name = "Studio 2"
    try store.mirrorHubDevices([renamed], hubID: "hub1")
    host = try #require(try store.records(VaultHost.self).first)
    #expect(host.name == "Build box")
    #expect(host.user == "me")
    #expect(host.hub?.deviceName == "Studio 2")
  }

  @Test func revokingRemovesTheHostAndItsTrust() throws {
    let store = try store()
    try store.mirrorHubDevices([studio()], hubID: "hub1")
    let changes = try store.mirrorHubDevices([studio(revoked: true)], hubID: "hub1")
    #expect(changes.removed.count == 1)
    #expect(try store.records(VaultHost.self).isEmpty)
    #expect(try store.knownFingerprint(host: "100.96.0.4", port: 22) == nil)
  }

  @Test func movingAddressMovesTheTrust() throws {
    let store = try store()
    try store.mirrorHubDevices([studio()], hubID: "hub1")
    try store.mirrorHubDevices([studio(address: "100.96.0.7")], hubID: "hub1")
    #expect(try store.knownFingerprint(host: "100.96.0.4", port: 22) == nil)
    #expect(try store.knownFingerprint(host: "100.96.0.7", port: 22) != nil)
  }

  @Test func keysTheUserAcceptedStay() throws {
    let store = try store()
    try store.mirrorHubDevices([studio(key: nil)], hubID: "hub1")
    let accepted = try #require(VaultIdentity.fingerprint(keyLine: Self.otherKey))
    try store.trust(fingerprint: accepted, host: "100.96.0.4", port: 22)
    try store.forgetHubHosts(hubID: "hub1")
    #expect(try store.records(VaultHost.self).isEmpty)
    #expect(try store.knownFingerprint(host: "100.96.0.4", port: 22) == accepted)
  }

  @Test func otherHubsAndUserHostsStay() throws {
    let store = try store()
    try store.save(VaultHost(name: "nas", hostname: "nas.local"))
    try store.mirrorHubDevices([studio()], hubID: "hub2")
    try store.mirrorHubDevices([], hubID: "hub1")
    #expect(try store.records(VaultHost.self).count == 2)
  }

  @MainActor
  @Test func projectsOnHubDevices() throws {
    let store = try store()
    var hub = VaultHubServer(id: "hub1", url: "wss://hub.example.com")
    hub.members = ["studio": "8cef065b7af83669150b7d32704d3d3e"]
    try store.save(hub)
    try store.mirrorHubDevices([studio()], hubID: "hub1")
    try store.save(VaultProject(id: "atlas", name: "Atlas", paths: ["mac": "/Users/a/Atlas", "studio": "/Users/b/Code/Atlas", "pad": "Atlas"]))
    let vault = Vault(store: store)
    let project = try #require(vault.project(atPath: "/Users/a/Atlas/"))
    let places = vault.otherPlaces(of: project)
    #expect(places.count == 2)
    let there = try #require(places.first { $0.device == "studio" })
    #expect(there.deviceName == "Mac Studio")
    #expect(there.host?.hostname == "100.96.0.4")
    #expect(there.sshCommand == #"ssh -t -p 22 100.96.0.4 'cd '\''/Users/b/Code/Atlas'\'' && exec "$SHELL" -l'"#)
    #expect(places.first { $0.device == "pad" }?.sshCommand == nil)
  }

  @MainActor
  @Test func thisMacOnTheHubIsThisDevice() throws {
    let store = try store()
    try store.mirrorHubDevices([studio()], hubID: "hub1")
    let host = try #require(try store.records(VaultHost.self).first)
    let vault = Vault(store: store)
    #expect(vault.isThisDevice(host, addresses: ["127.0.0.1", "100.96.0.4"]))
    #expect(!vault.isThisDevice(host, addresses: ["127.0.0.1", "100.96.0.2"]))
    // A host the user added at the same address is theirs to keep.
    #expect(!vault.isThisDevice(VaultHost(hostname: "100.96.0.4"), addresses: ["100.96.0.4"]))
    #if !os(Windows)
      #expect(VaultDevice.addresses.isSuperset(of: ["127.0.0.1", "::1"]))
    #endif
  }

  /// The hub's own machine adds it at 127.0.0.1 and another device at its LAN address: two records with one key
  @MainActor
  @Test func projectsOnTheHubsOwnMachine() throws {
    let store = try store()
    var local = VaultHubServer(id: "local", url: "ws://127.0.0.1:1997")
    local.hubKey = "hub-key"
    local.members = ["studio": "8cef065b7af83669150b7d32704d3d3e"]
    var lan = VaultHubServer(id: "lan", url: "ws://192.168.1.21:1997")
    lan.hubKey = "hub-key"
    try store.save(local)
    try store.save(lan)
    try store.mirrorHubDevices([studio()], hubID: "lan")
    try store.save(VaultProject(id: "atlas", name: "Atlas", paths: ["mac": "/Users/a/Atlas", "studio": "/Users/b/Code/Atlas"]))
    let vault = Vault(store: store)
    let project = try #require(vault.project(atPath: "/Users/a/Atlas"))
    #expect(vault.otherPlaces(of: project).first?.host?.hostname == "100.96.0.4")
    // A record of another Hub doesn't count
    lan.hubKey = "other-key"
    try store.save(lan)
    #expect(Vault(store: store).otherPlaces(of: project).first?.host == nil)
  }

  /// The apps' libssh2 has no Ed25519: pinning one would look like a changed key next to the ECDSA key they get.
  @Test func ed25519KeysAreShownButNotPinned() throws {
    let store = try store()
    try store.mirrorHubDevices([studio(key: Self.ed25519Key)], hubID: "hub1")
    #expect(try store.records(VaultHost.self).first?.hub?.hostKey == Self.ed25519Key)
    #expect(try store.knownFingerprint(host: "100.96.0.4", port: 22) == nil)
  }

  /// Sends an item from one device's store to another's, as sync would.
  func send(_ id: String, from: VaultStore, to: VaultStore) throws {
    let record = try #require(try from.outgoing(id: id))
    try to.apply(
      RemoteRecord(id: id, keyID: record.keyID, payload: record.payload, changeTag: UUID().uuidString, systemFields: nil))
  }

  /// The iPhone and the iPad add the same Hub before either sees the other's record: one Hub, both connecting.
  @Test func oneHubAddedOnTwoDevicesIsOneRecord() throws {
    let phone = try store("phone")
    let pad = try store("pad")
    let onPhone = VaultHubServer(
      id: VaultHubServer.newID(url: "ws://192.168.1.21:21999", in: phone), url: "ws://192.168.1.21:21999",
      connects: ["phone"], syncs: ["phone"])
    let onPad = VaultHubServer(
      id: VaultHubServer.newID(url: "WS://192.168.1.21:21999/", in: pad), url: "ws://192.168.1.21:21999",
      connects: ["pad"])
    #expect(onPhone.id == onPad.id)
    try phone.save(onPhone)
    try pad.save(onPad)
    try send(onPad.id, from: pad, to: phone)
    let hubs = try phone.records(VaultHubServer.self)
    #expect(hubs.count == 1)
    #expect(hubs.first?.connects == ["phone", "pad"])
    #expect(hubs.first?.syncs == ["phone"])
  }

  /// Records made before the derived id (random ids) fold by their identity when they meet.
  @Test func duplicateHubRecordsFoldKeepingEveryDevicesFlags() throws {
    let phone = try store("phone")
    let pad = try store("pad")
    let a = VaultHubServer(id: "aaa-old", url: "ws://192.168.1.21:21999", connects: ["phone"], members: ["phone": "h1"])
    let b = VaultHubServer(id: "bbb-old", url: "ws://192.168.1.21:21999/", connects: ["pad"], members: ["pad": "h2"])
    try phone.save(a)
    try pad.save(b)
    try send(b.id, from: pad, to: phone)
    let hubs = try phone.records(VaultHubServer.self)
    #expect(hubs.map(\.id) == ["aaa-old"])
    #expect(hubs.first?.connects == ["phone", "pad"])
    #expect(hubs.first?.members == ["phone": "h1", "pad": "h2"])
    // The tombstone goes back to the iPad, which folds the same way.
    try send(b.id, from: phone, to: pad)
    try send(a.id, from: phone, to: pad)
    #expect(try pad.records(VaultHubServer.self).map(\.id) == ["aaa-old"])
  }

  @Test func hubRecordConnectsPerDevice() throws {
    var hub = VaultHubServer(url: "wss://hub.v57.dev")
    #expect(hub.isPlayground)
    #expect(hub.displayName == "hub.v57.dev")
    hub.connects = ["mac"]
    let store = try store()
    try store.save(hub)
    var read = try #require(try store.record(VaultHubServer.self, id: hub.id))
    #expect(read.connects(on: "mac"))
    read.connects.remove("mac")
    try store.save(read)
    read = try #require(try store.record(VaultHubServer.self, id: hub.id))
    #expect(read.connects.isEmpty)
    #expect(!VaultHubServer(url: "ws://192.168.1.20:1997").isPlayground)
    read.members = ["studio-vault-id": "8cef065b7af83669150b7d32704d3d3e"]
    try store.save(read)
    read = try #require(try store.record(VaultHubServer.self, id: hub.id))
    #expect(read.vaultDevice(forHubDevice: "8cef065b7af83669150b7d32704d3d3e") == "studio-vault-id")
    #expect(read.vaultDevice(forHubDevice: "other") == nil)
  }
}
