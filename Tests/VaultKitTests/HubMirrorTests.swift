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
    #expect(try store.knownFingerprint(for: host) == VaultIdentity.fingerprint(keyLine: Self.hostKey))

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
    #expect(try store.records(VaultKnownHost.self).isEmpty)
  }

  /// A Hub the user added can say anything about its devices: it can't point one at a server and replace its key.
  @Test func aHubCantReplaceTheKeyPinnedForAServer() throws {
    let store = try store()
    try store.trust(fingerprint: "SHA256:real", host: "prod.example.com", port: 22)
    for address in ["prod.example.com", "203.0.113.5", "100.128.0.1", "100.63.0.1", "100.96.0.4.example.com", "::1"] {
      let changes = try store.mirrorHubDevices([studio(address: address)], hubID: "hub1")
      #expect(changes.added.isEmpty)
      #expect(try store.knownFingerprint(host: address, port: 22) == (address == "prod.example.com" ? "SHA256:real" : nil))
    }
    #expect(try store.records(VaultHost.self).isEmpty)
    #expect(VaultHubDevice.isOverlayAddress("100.96.0.4") && VaultHubDevice.isOverlayAddress("100.127.255.254"))
  }

  @Test func movingAddressMovesTheTrust() throws {
    let store = try store()
    try store.mirrorHubDevices([studio()], hubID: "hub1")
    try store.mirrorHubDevices([studio(address: "100.96.0.7")], hubID: "hub1")
    let host = try #require(try store.records(VaultHost.self).first)
    #expect(host.hostname == "100.96.0.7")
    #expect(try store.knownFingerprint(for: host) != nil)
    #expect(try store.records(VaultKnownHost.self).map(\.host) == ["100.96.0.7"])
  }

  @Test func keysTheUserAcceptedStay() throws {
    let store = try store()
    try store.mirrorHubDevices([studio(key: nil)], hubID: "hub1")
    let accepted = try #require(VaultIdentity.fingerprint(keyLine: Self.otherKey))
    let host = try #require(try store.records(VaultHost.self).first)
    try store.trust(fingerprint: accepted, for: host)
    try store.forgetHubHosts(hubID: "hub1")
    #expect(try store.records(VaultHost.self).isEmpty)
    #expect(try store.knownFingerprint(for: host) == accepted)
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
    let host = try #require(try store.records(VaultHost.self).first)
    #expect(host.hub?.hostKey == Self.ed25519Key)
    #expect(try store.knownFingerprint(for: host) == nil)
  }

  // MARK: Pins by route

  /// Two Hubs hand out addresses on their own: the same address on both is two machines, and neither pin moves the
  /// other. Once it was one pin, overwritten in turn, and the mismatch warnings taught people to accept them.
  @Test func twoHubsAtOneAddressKeepTheirOwnPins() throws {
    let store = try store()
    let one = try #require(VaultIdentity.fingerprint(keyLine: Self.hostKey))
    let other = try #require(VaultIdentity.fingerprint(keyLine: Self.otherKey))
    try store.mirrorHubDevices([studio()], hubID: "hub1")
    try store.mirrorHubDevices([studio(key: Self.otherKey)], hubID: "hub2")
    let hosts = try store.records(VaultHost.self)
    let first = try #require(hosts.first { $0.hub?.hubID == "hub1" })
    let second = try #require(hosts.first { $0.hub?.hubID == "hub2" })
    #expect(first.hostname == second.hostname)
    #expect(try store.knownFingerprint(for: first) == one)
    #expect(try store.knownFingerprint(for: second) == other)

    try store.forgetHubHosts(hubID: "hub2")
    #expect(try store.knownFingerprint(for: first) == one)
  }

  /// A Hub the user joined names an address another Hub uses, or a server they saved: its key counts for its own device
  /// and nowhere else.
  @Test func aHubsTrustStaysOnItsOwnRoutes() throws {
    let store = try store()
    let saved = VaultHost(name: "box", hostname: "100.96.0.4")
    try store.save(saved)
    let real = try #require(VaultIdentity.fingerprint(keyLine: Self.hostKey))
    try store.trust(fingerprint: real, for: saved)
    try store.mirrorHubDevices([studio()], hubID: "real")
    let realHost = try #require(try store.records(VaultHost.self).first { $0.hub?.hubID == "real" })

    try store.mirrorHubDevices([studio(key: Self.otherKey)], hubID: "malicious")

    #expect(try store.knownFingerprint(for: saved) == real)
    #expect(try store.knownFingerprint(host: "100.96.0.4", port: 22) == real)
    #expect(try store.knownFingerprint(for: realHost) == real)
    // A host the user adds at that address starts knowing nothing, whatever any Hub said.
    #expect(try store.knownFingerprint(for: VaultHost(hostname: "100.96.0.5")) == nil)
    let mirrored = try store.records(VaultKnownHost.self).filter { $0.route?.hasPrefix("hub|") == true }
    #expect(Set(mirrored.compactMap(\.route)).count == 2)
  }

  /// A Hub can't replace a pin on a route of another Hub even by claiming to be the same device id.
  @Test func theSameDeviceIDOnAnotherHubIsAnotherRoute() throws {
    let store = try store()
    try store.mirrorHubDevices([studio()], hubID: "hub1")
    let first = try #require(try store.records(VaultHost.self).first)
    let before = try store.knownFingerprint(for: first)
    try store.mirrorHubDevices([studio(address: "100.96.0.4", key: Self.otherKey)], hubID: "hub2")
    #expect(try store.knownFingerprint(for: first) == before)
  }

  /// `.local` names repeat across networks: two saved hosts with one name are two machines.
  @Test func repeatedLocalNamesDontOverwriteEachOther() throws {
    let store = try store()
    let home = VaultHost(id: "home", hostname: "nas.local")
    let office = VaultHost(id: "office", hostname: "NAS.local")
    try store.trust(fingerprint: "SHA256:home", for: home)
    try store.trust(fingerprint: "SHA256:office", for: office)
    #expect(try store.knownFingerprint(for: home) == "SHA256:home")
    #expect(try store.knownFingerprint(for: office) == "SHA256:office")
    // Other names stay one server for every saved host, the way known_hosts has them.
    let one = VaultHost(id: "one", hostname: "prod.example.com")
    let other = VaultHost(id: "other", hostname: "Prod.Example.com")
    try store.trust(fingerprint: "SHA256:prod", for: one)
    #expect(try store.knownFingerprint(for: other) == "SHA256:prod")
    #expect(try store.knownFingerprint(host: "prod.example.com", port: 22) == "SHA256:prod")
  }

  /// A pin written before routes (no `route` field) still answers for a host at its address, until that host has
  /// its own, and it goes when the Hub's device does. The schema didn't change: `route` is a field.
  @Test func pinsFromBeforeRoutesStayReadable() throws {
    let store = try store()
    let id = try store.knownHostID(host: "100.96.0.4", port: 22)
    let fingerprint = try #require(VaultIdentity.fingerprint(keyLine: Self.hostKey))
    try store.save(VaultKnownHost(id: id, host: "100.96.0.4", port: 22, fingerprint: fingerprint))
    #expect(try store.record(VaultKnownHost.self, id: id)?.route == nil)

    #expect(try store.knownFingerprint(host: "100.96.0.4", port: 22) == fingerprint)
    #expect(try store.knownFingerprint(for: VaultHost(hostname: "100.96.0.4")) == fingerprint)
    try store.mirrorHubDevices([studio(key: Self.ed25519Key)], hubID: "hub1")
    let unsigned = try #require(try store.records(VaultHost.self).first)
    #expect(try store.knownFingerprint(for: unsigned) == fingerprint)

    // Its own pin wins.
    try store.mirrorHubDevices([studio(key: Self.otherKey)], hubID: "hub1")
    let signed = try #require(try store.records(VaultHost.self).first)
    #expect(try store.knownFingerprint(for: signed) == VaultIdentity.fingerprint(keyLine: Self.otherKey))
    // A pin made since routes began belongs to the plain address, and says nothing about a Hub's device.
    try store.trust(fingerprint: "SHA256:plain", host: "100.96.0.9", port: 22)
    try store.mirrorHubDevices([studio(address: "100.96.0.9", key: Self.ed25519Key)], hubID: "hub3")
    let other = try #require(try store.records(VaultHost.self).first { $0.hub?.hubID == "hub3" })
    #expect(try store.knownFingerprint(for: other) == nil)
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
