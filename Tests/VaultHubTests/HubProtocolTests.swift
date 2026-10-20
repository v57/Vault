import Foundation
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
      var safetyCode: String?
    }
    struct Auth: Decodable {
      struct Header: Decodable { var header: String }
      var expiry: Int
      var v0: Header
      var v1: Header
    }
    struct Certificate: Decodable { var json: String; var header: String }
    var keys: [String: Key]
    var auth: Auth
    var certificate: Certificate
    var childCertificate: Certificate
  }

  static let vectors: Vectors = {
    let url = Bundle.module.url(forResource: "Fixtures/hub-device-vectors", withExtension: "json")!
    return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
  }()

  func key(_ name: String) throws -> HubKey {
    let hex = Self.vectors.keys[name]!.seed
    let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
      let start = hex.index(hex.startIndex, offsetBy: offset)
      return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
    return try HubKey(seed: Data(bytes))
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
    #expect(HubKey.safetyCode(spki: device.publicKey) == device.safetyCode)
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
    expectSigned(
      HubWire.auth(service, hubKey: nil, expiry: expiry), like: Self.vectors.auth.v0.header, signed: "\(expiry)",
      spki: service.spki)
    expectSigned(
      HubWire.auth(service, hubKey: hub, expiry: expiry), like: Self.vectors.auth.v1.header,
      signed: "hub1:\(hub):\(expiry)", spki: service.spki)
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

  @Test func pendingCodesComeFromTheKey() throws {
    let key = Self.vectors.keys["device"]!
    let json = """
      [{"id":"\(key.deviceId!)","key":"\(key.publicKey)","name":"iPad","safetyCode":"000 000","firstSeen":"2026-10-20T19:00:00Z"}]
      """
    let pending = try JSONDecoder().decode([HubWire.PendingDevice].self, from: Data(json.utf8)).map(HubPendingDevice.init)
    #expect(pending.first?.safetyCode == "474 971")
    #expect(pending.first?.codeChecks == false)
  }

  @Test func addresses() {
    #expect(HubDirectory.normalized("1997") == "ws://localhost:1997")
    #expect(HubDirectory.normalized("WSS://Hub.Example.com/") == "wss://hub.example.com")
    #expect(HubDirectory.normalized("hub.example.com") == "wss://hub.example.com")
    #expect(HubDirectory.normalized("https://hub.example.com:8443") == "wss://hub.example.com:8443")
    #expect(HubDirectory.normalized("ftp://x") == nil)
    #expect(HubDirectory.normalized("") == nil)
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
