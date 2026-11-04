import Foundation
import HubService
import Testing
import VaultKit

@testable import VaultHub

/// Hub's device-layer wire format, checked against the vectors every SDK reproduces (`Docs/Devices/vectors.json`).
struct HubProtocolTests {
  struct Vectors: Decodable {
    struct Key: Decodable {
      var seed: String
      var keyFile: String
      var publicKey: String
      var deviceId: String?
    }
    struct Auth: Decodable {
      struct Header: Decodable { var header: String }
      var nonce: String
      var expiry: Int
      var v0: Header
      var v1: Header
    }
    struct Certificate: Decodable { var json: String; var header: String }
    struct Credentials: Decodable {
      struct Canonical: Decodable { var input: String; var address: String }
      struct Derived: Decodable { var role: String; var address: String; var seed: String; var publicKey: String }
      var deviceSeed: String
      var canonical: [Canonical]
      var keys: [Derived]
    }
    struct SafetyCode: Decodable {
      struct Case: Decodable { var hubKey: String; var deviceKey: String; var codeValue: String; var code: String }
      var cases: [Case]
    }
    var safetyCode: SafetyCode
    var credentials: Credentials
    var keys: [String: Key]
    var auth: Auth
    var certificate: Certificate
    var childCertificate: Certificate
  }

  static let vectors: Vectors = {
    let url = Bundle.module.url(forResource: "Fixtures/hub-device-vectors", withExtension: "json")!
    return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
  }()

  static func hex(_ hex: String) -> Data {
    let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
      let start = hex.index(hex.startIndex, offsetBy: offset)
      return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
    return Data(bytes)
  }

  func key(_ name: String) throws -> HubKey {
    try HubKey(seed: Self.hex(Self.vectors.keys[name]!.seed))
  }

  @Test func keysAndDeviceIdentity() throws {
    for (name, vector) in Self.vectors.keys {
      let key = try key(name)
      #expect(key.spki == vector.publicKey)
      #expect(key.keyFile == vector.keyFile)
      #expect(try HubKey(keyFile: vector.keyFile).spki == vector.publicKey)
    }
    let device = Self.vectors.keys["device"]!
    #expect(HubKey.deviceID(spki: device.publicKey) == device.deviceId)
    for code in Self.vectors.safetyCode.cases {
      #expect(HubKey.safetyCode(hubKey: code.hubKey, deviceKey: code.deviceKey, codeValue: code.codeValue) == code.code)
    }
  }

  // CryptoKit's Ed25519 signatures are randomized, so the vectors' signature strings can't be reproduced on Apple
  // platforms: everything but the signature must match exactly, and the signature must verify.

  /// `<prefix>.<signature>.<suffix>` with the signature verified against `spki` over `signed`.
  func expectSigned(_ made: String, like vector: String, signed: String, spki: String) {
    func parts(_ text: String) -> [Substring] { text.split(separator: ".", omittingEmptySubsequences: false) }
    let mine = parts(made)
    let theirs = parts(vector)
    #expect(mine.count == theirs.count)
    guard mine.count == theirs.count, let index = theirs.indices.first(where: { theirs[$0].hasSuffix("=") && theirs[$0].count == 88 })
    else { return }
    for i in mine.indices where i != index { #expect(mine[i] == theirs[i]) }
    #expect(HubKey.verify(String(mine[index]), of: signed, spki: spki))
    #expect(HubKey.verify(String(theirs[index]), of: signed, spki: spki))
  }

  @Test func authHeaders() throws {
    let service = try key("service")
    let hub = Self.vectors.keys["hub"]!.publicKey
    let expiry = Self.vectors.auth.expiry
    let nonce = Self.vectors.auth.nonce
    expectSigned(
      HubWire.auth(service, hubKey: hub, nonce: nonce, expiry: expiry), like: Self.vectors.auth.v1.header,
      signed: "hub1:\(hub):\(nonce):\(expiry)", spki: service.spki)
  }

  /// The keys for a Hub come from the device key and the address, the same as Hub's vectors and as the Hub app.
  @Test func credentialsMatchTheVectors() throws {
    let credentials = Self.vectors.credentials
    let device = try HubKey(seed: Self.hex(credentials.deviceSeed))
    for vector in credentials.canonical {
      #expect(HubAddress.canonical(vector.input) == vector.address)
    }
    for vector in credentials.keys {
      let role = try #require(HubCredentials.Role(rawValue: vector.role))
      let key = try device.credential(role, address: vector.address)
      #expect(key.seed == Self.hex(vector.seed))
      #expect(key.spki == vector.publicKey)
    }
  }

  @MainActor
  func directory(deviceID: String = "mac") throws -> (HubDirectory, VaultStore, Vault) {
    VaultSecrets.useInMemoryStore()
    let store = try VaultStore(
      directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), keys: MemoryKeyProvider(),
      deviceID: deviceID, notifier: nil, owner: deviceID)
    let vault = Vault(store: store)
    return (HubDirectory(vault: vault), store, vault)
  }

  @MainActor
  @Test func aNewHubGetsItsOwnKeysAndAPinnedOneKeepsTheShared() throws {
    let (directory, store, vault) = try directory()
    let shared = try HubKeyStore.keys(for: .shared)

    let new = try directory.add(url: "wss://Hub.Example.com/")
    let newKeys = try HubKeyStore.keys(for: try #require(directory.keyScope(of: new)))
    #expect(directory.keyScope(of: new) == .address("wss://hub.example.com"))
    #expect(newKeys.device.spki != shared.device.spki)
    #expect(newKeys.client.spki != shared.client.spki)
    #expect(newKeys.device.spki != newKeys.client.spki)
    #expect(directory.thisDevice(on: new)?.id == HubKey.deviceID(spki: newKeys.device.spki))

    // A record from before auth v2: pinned, no `keys`. It was approved with the shared keys, so nobody pairs again.
    let old = VaultHubServer(id: "old", url: "wss://old.example.com", hubKey: "pinned")
    try store.save(old)
    vault.reload()
    #expect(directory.keyScope(of: old) == .shared)
    // Another app saving the record doesn't lose it, and the pin of a new record doesn't turn it into an old one
    vault.save(old)
    #expect(directory.keyScope(of: old) == .shared)
    var pinned = try #require(vault.hub(id: new.id))
    pinned.hubKey = "pinned"
    vault.save(pinned)
    #expect(directory.keyScope(of: pinned) == .address("wss://hub.example.com"))

    // A record another device or app made, unpinned and without `keys`: keys of its own before anything connects
    let bare = VaultHubServer(id: "bare", url: "ws://192.168.1.5:1997")
    try store.save(bare)
    vault.reload()
    #expect(directory.keyScope(of: bare) == .address("ws://192.168.1.5:1997"))
  }

  @MainActor
  @Test func aSecondAddressIsANewHubUnlessToldOtherwise() throws {
    let (directory, _, vault) = try directory()
    let first = try directory.add(url: "wss://hub.example.com")
    var pinned = try #require(vault.hub(id: first.id))
    pinned.hubKey = "same-key"
    vault.save(pinned)

    // It proves the same key, and that alone doesn't reuse credentials: a malicious Hub can relay the proof
    var second = try directory.add(url: "ws://192.168.1.5:1997")
    second.hubKey = "same-key"
    vault.save(second)
    #expect(directory.keyScope(of: second) == .address("ws://192.168.1.5:1997"))

    // The address came from that Hub, or from the user
    let third = try directory.add(url: "ws://100.96.0.4:1997", sameHubAs: pinned)
    #expect(directory.keyScope(of: third) == directory.keyScope(of: pinned))
  }

  @MainActor
  @Test func forgettingAKeyEndsTheSharedKeys() throws {
    let (directory, store, vault) = try directory()
    let old = VaultHubServer(id: "old", url: "wss://old.example.com", hubKey: "pinned")
    try store.save(old)
    vault.reload()
    #expect(directory.keyScope(of: old) == .shared)
    directory.forgetKey(of: old)
    let forgotten = try #require(vault.hub(id: "old"))
    #expect(forgotten.hubKey == nil)
    #expect(directory.keyScope(of: forgotten) == .address("wss://old.example.com"))
  }

  /// Plain `ws://` beyond this network never gets a connection, and on the LAN the UI can say so.
  @MainActor
  @Test func aPlainPublicAddressIsNotDialed() async throws {
    let (directory, _, vault) = try directory()
    directory.start()
    defer { directory.stop() }
    let hub = try directory.add(url: "ws://hub.example.com:1997")
    let connection = try #require(directory.connection(for: hub.id))
    #expect(connection.status == .notEncrypted)
    #expect(vault.hub(id: hub.id)?.hubKey == nil)
    let local = try directory.add(url: "ws://192.168.1.5:1")
    #expect(try #require(directory.connection(for: local.id)).isUnencrypted)
    let tls = try directory.add(url: "wss://secure.example.com")
    #expect(try #require(directory.connection(for: tls.id)).isUnencrypted == false)
  }

  @Test func certificates() throws {
    let device = try key("device")
    let service = Self.vectors.keys["service"]!.publicKey
    let made = HubWire.certificate(
      device: device, service: service, instance: "s3-local/Backup Disk", deviceName: "Mac Studio",
      platform: "macos", issued: 1_792_500_000)
    let payload = String(Self.vectors.certificate.header.split(separator: ".")[0])
    expectSigned(made, like: Self.vectors.certificate.header, signed: payload, spki: device.spki)
    let child = HubWire.certificate(
      device: device, service: service, instance: "builder", deviceName: "builder", platform: "linux",
      parent: "Mac Studio", issued: 1_792_500_000)
    let childPayload = String(Self.vectors.childCertificate.header.split(separator: ".")[0])
    expectSigned(child, like: Self.vectors.childCertificate.header, signed: childPayload, spki: device.spki)
  }

  @Test func keyFilesAreMadeOnceAndPrivate() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "hub-\(UUID().uuidString)/device.key")
    let made = try HubKeyStore.fileKey(at: file)
    let again = try HubKeyStore.fileKey(at: file)
    #expect(made.spki == again.spki)
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test func theHubAppsDeviceKeyIsSharedWithEveryApp() throws {
    VaultSecrets.useInMemoryStore()
    // The Hub app's own key replaces whatever a v57 app made; without one it keeps the group's
    let own = HubKey()
    #expect(try HubKeyStore.shareDeviceKey(own.seed).spki == own.spki)
    #expect(try HubKeyStore.deviceKey().spki == own.spki)
    #expect(try HubKeyStore.sharedDeviceKey()?.spki == own.spki)
    #expect(try HubKeyStore.shareDeviceKey(nil).spki == own.spki)
  }

  // MARK: The directory

  static func deviceJSON(_ key: HubKey, hostKey: String, signature: String, revoked: Bool = false) -> Data {
    let id = HubKey.deviceID(spki: key.spki)!
    return Data(
      """
      [{"id":"\(id)","key":"\(key.spki)","name":"Mac Studio","platform":"macos","approved":true,"revoked":\(revoked),
        "online":true,"network":"online","overlay":{"address":"100.96.0.4","authority":"mac-studio.hub.invalid"},
        "lastSeen":"2026-10-20T19:01:02.345Z","newField":{"a":1},
        "capabilities":{"tools":{"xcode":"27.0","simulators":["iPhone 18 Pro"],"docker":true,"cores":24},
          "ssh":{"port":2222,"user":"me","hostKey":"\(hostKey)","hostKeySignature":"\(signature)"}},
        "services":[{"key":"k","instance":"hub-launcher","online":true,"paths":[]}]}]
      """.utf8)
  }

  static let hostKey =
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLCMdXLYdMyZCS2rOzcgJMOt87l22HK0AUGoqzCFfczoDEf1JCKCAs+9ydUUXYTUWpuXqD95SbzTwGRoNxHGcMU="

  @Test func devicesDecodeWithSignedHostKeys() throws {
    let device = HubKey()
    let signed = device.sign(HubWire.hostKeySigned(Self.hostKey))
    let wire = try JSONDecoder().decode([HubWire.Device].self, from: Self.deviceJSON(device, hostKey: Self.hostKey, signature: signed))
    let entry = VaultHubDevice(try #require(wire.first))
    #expect(entry.isSSHTarget)
    #expect(entry.address == "100.96.0.4")
    #expect(entry.ssh == .init(port: 2222, hostKey: Self.hostKey, user: "me"))
    #expect(entry.tools["xcode"] == "27.0")
    #expect(entry.tools["simulators"] == "iPhone 18 Pro")
    #expect(entry.isNetworkOnline == true)
    #expect(entry.lastSeen != nil)
    #expect(entry.services == ["hub-launcher"])
  }

  @Test func hostKeysAnotherKeySignedAreNotPinned() throws {
    let device = HubKey()
    let forged = HubKey().sign(HubWire.hostKeySigned(Self.hostKey))
    let wire = try JSONDecoder().decode([HubWire.Device].self, from: Self.deviceJSON(device, hostKey: Self.hostKey, signature: forged))
    let entry = VaultHubDevice(try #require(wire.first))
    #expect(entry.ssh?.hostKey == nil)
    #expect(entry.isSSHTarget)
  }

  /// `hostKeys`: the first ECDSA or RSA key the device signed, over an Ed25519 `hostKey`.
  @Test func signedECDSAKeysWinOverEd25519() throws {
    let device = HubKey()
    let ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO1JKMYo0cLG6ukDOJBZlWEpWSc6XGP5NjbBRhSshzfR"
    let forgedECDSA = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDQtoM8yj77ua8p9tI4mH0LcOFWOzT0wUwLLtL5dDUOB0+4GIz2Aq6siPRVnYbdpE/zKA0Gu2wgcMQhNDHMKj8M="
    func sign(_ key: String) -> String { device.sign(HubWire.hostKeySigned(key)) }
    let json = """
      [{"id":"\(HubKey.deviceID(spki: device.spki)!)","key":"\(device.spki)","name":"Mac Studio","approved":true,
        "revoked":false,"online":true,"overlay":{"address":"100.96.0.4"},
        "capabilities":{"ssh":{"port":22,"hostKey":"\(ed25519)","hostKeySignature":"\(sign(ed25519))","hostKeys":[
          {"hostKey":"\(ed25519)","hostKeySignature":"\(sign(ed25519))"},
          {"hostKey":"\(forgedECDSA)","hostKeySignature":"\(HubKey().sign(HubWire.hostKeySigned(forgedECDSA)))"},
          {"hostKey":"\(Self.hostKey)","hostKeySignature":"\(sign(Self.hostKey))"}]}}}]
      """
    let wire = try JSONDecoder().decode([HubWire.Device].self, from: Data(json.utf8))
    #expect(VaultHubDevice(try #require(wire.first)).ssh?.hostKey == Self.hostKey)

    // Without hostKeys (older reporters): the signed hostKey, whatever its type.
    let old = json.replacingOccurrences(of: #","hostKeys":["#, with: #","ignored":["#)
    let oldWire = try JSONDecoder().decode([HubWire.Device].self, from: Data(old.utf8))
    #expect(VaultHubDevice(try #require(oldWire.first)).ssh?.hostKey == ed25519)
  }

  @Test func pendingCodesAreComputedFromThePinnedKey() throws {
    let key = Self.vectors.keys["device"]!
    let hubKey = Self.vectors.keys["hub"]!.publicKey
    let value = Self.vectors.safetyCode.cases[0].codeValue
    func pending(_ code: String, value: String?, pinned: String?) throws -> HubPendingDevice? {
      let codeValue = value.map { ",\"codeValue\":\"\($0)\"" } ?? ""
      let json = """
        [{"id":"\(key.deviceId!)","key":"\(key.publicKey)","name":"iPad","safetyCode":"\(code)"\(codeValue),"firstSeen":"2026-10-20T19:00:00Z"}]
        """
      return try JSONDecoder().decode([HubWire.PendingDevice].self, from: Data(json.utf8)).map { HubPendingDevice($0, hubKey: pinned) }.first
    }
    let computed = HubKey.safetyCode(hubKey: hubKey, deviceKey: key.publicKey, codeValue: value)
    // What the Hub says doesn't count: the code comes from the pinned key, and a different claim shows
    let altered = try pending("000 000", value: value, pinned: hubKey)
    #expect(altered?.safetyCode == computed && altered?.codeChecks == false)
    let agreed = try pending(computed, value: value, pinned: hubKey)
    #expect(agreed?.safetyCode == computed && agreed?.codeChecks == true)
    // Another Hub's key gives another code, which doesn't check
    #expect(try pending(computed, value: value, pinned: key.publicKey)?.codeChecks == false)
    // A Hub with no value gives no code at all, never one computed from the device's key alone
    let old = try pending("474 971", value: nil, pinned: hubKey)
    #expect(old?.safetyCode == "" && old?.codeChecks == false)
  }

  @Test func addresses() {
    #expect(HubDirectory.normalized("1997") == "ws://localhost:1997")
    #expect(HubDirectory.normalized("WSS://Hub.Example.com/") == "wss://hub.example.com")
    #expect(HubDirectory.normalized("hub.example.com") == "wss://hub.example.com")
    #expect(HubDirectory.normalized("https://hub.example.com:8443") == "wss://hub.example.com:8443")
    #expect(HubDirectory.normalized("ftp://x") == nil)
    #expect(HubDirectory.normalized("") == nil)
  }

  /// Finding U2 of the second review: a host's record lands before its Hub's on a fresh device, whose first fetch comes in
  /// batches. Its absence says nothing, and a tombstone written now would reach every device.
  @MainActor
  @Test func aHostWhoseHubHasntArrivedStays() throws {
    let (directory, store, vault) = try directory()
    let device = VaultHubDevice(
      id: "studio", name: "Mac Studio", platform: "macos", isOnline: true, address: "100.96.0.4", ssh: .init(port: 22))
    try store.mirrorHubDevices([device], hubID: "not-here-yet")
    vault.reload()
    directory.start()
    #expect(vault.hubHosts.count == 1)
    #expect(try store.items(kind: "host").count == 1)

    // A store that finished doesn't change that: a later batch can still bring the Hub.
    store.fetchCompleted()
    directory.refresh()
    vault.reload()
    #expect(vault.hubHosts.count == 1)

    // Only a Hub this store holds a tombstone for has gone.
    try store.save(VaultHubServer(id: "not-here-yet", url: "ws://localhost:1"))
    try store.delete(id: "not-here-yet")
    vault.reload()
    directory.refresh()
    vault.reload()
    #expect(vault.hubHosts.isEmpty)
  }

  @MainActor
  @Test func aDirectoryUpdateMirrorsHosts() throws {
    VaultSecrets.useInMemoryStore()
    let store = try VaultStore(
      directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), keys: MemoryKeyProvider(),
      deviceID: "mac", notifier: nil, owner: "mac")
    let vault = Vault(store: store)
    let directory = HubDirectory(vault: vault)
    directory.start()
    let hub = VaultHubServer(url: "ws://localhost:1", connects: [])
    try store.save(hub)
    vault.reload()
    let me = HubKey()
    let connection = HubConnection(
      hub: hub, vault: vault, device: HubThisDevice(key: me), deviceKey: me, clientKey: HubKey())
    let other = HubKey()
    connection.receive(
      try JSONDecoder().decode(
        [HubWire.Device].self,
        from: Self.deviceJSON(other, hostKey: Self.hostKey, signature: other.sign(HubWire.hostKeySigned(Self.hostKey)))))
    #expect(vault.hubHosts.map(\.hostname) == ["100.96.0.4"])
    #expect(vault.hubHosts.first?.port == 2222)
    #expect(vault.knownHosts.count == 1)

    connection.receive(
      try JSONDecoder().decode(
        [HubWire.Device].self,
        from: Self.deviceJSON(other, hostKey: Self.hostKey, signature: "", revoked: true)))
    #expect(vault.hubHosts.isEmpty)
    #expect(vault.knownHosts.isEmpty)

    directory.remove(hub)
    #expect(vault.hubs.isEmpty)
  }
}
