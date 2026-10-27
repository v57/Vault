import Foundation
import Testing

@testable import VaultKit

struct DeviceHostTests {
  let keys = MemoryKeyProvider()
  static let hostKey = HubMirrorTests.hostKey
  static let phoneKey = HubMirrorTests.otherKey + " iPhone"

  init() { VaultSecrets.useInMemoryStore() }

  func store(_ device: String = "mac") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  @Test func aMacPublishesItselfAsATrustedHost() throws {
    let store = try store()
    #expect(try store.publishDeviceHost(name: "Studio", address: "Studio.local", user: "me", hostKey: Self.hostKey, allowed: ["phone"]))
    let host = try #require(try store.records(VaultHost.self).first)
    #expect(host.hostname == "Studio.local")
    #expect(host.user == "me")
    #expect(host.source == "device")
    #expect(host.device?.deviceID == "mac")
    #expect(host.device?.allowed == ["phone"])
    #expect(try store.knownFingerprint(host: "Studio.local", port: 22) == VaultIdentity.fingerprint(keyLine: Self.hostKey))

    // The same again writes nothing.
    #expect(try !store.publishDeviceHost(name: "Studio", address: "Studio.local", user: "me", hostKey: Self.hostKey, allowed: ["phone"]))
  }

  @Test func theUsersHostnameOutlivesANewAddress() throws {
    let store = try store()
    try store.publishDeviceHost(name: "Studio", address: "Studio.local", user: "me", hostKey: Self.hostKey, allowed: [])
    var host = try #require(try store.records(VaultHost.self).first)
    host.hostname = "studio.tail1234.ts.net"
    host.name = "Mac Studio"
    try store.save(host)

    try store.publishDeviceHost(name: "Studio", address: "Studio-2.local", user: "me", hostKey: Self.hostKey, allowed: [])
    host = try #require(try store.records(VaultHost.self).first)
    #expect(host.hostname == "studio.tail1234.ts.net")
    #expect(host.name == "Mac Studio")
    #expect(host.device?.address == "Studio-2.local")
    #expect(try store.knownFingerprint(host: "studio.tail1234.ts.net", port: 22) == VaultIdentity.fingerprint(keyLine: Self.hostKey))
  }

  @Test func withdrawingTakesTheHostAndItsTrust() throws {
    let store = try store()
    try store.publishDeviceHost(name: "Studio", address: "Studio.local", user: "me", hostKey: Self.hostKey, allowed: [])
    try store.withdrawDeviceHost()
    #expect(try store.records(VaultHost.self).isEmpty)
    #expect(try store.knownFingerprint(host: "Studio.local", port: 22) == nil)
  }

  @Test @MainActor func projectsOnAPublishedMacHaveAWayThere() throws {
    let mac = try store()
    try mac.publishDeviceHost(name: "Studio", address: "Studio.local", user: "me", hostKey: Self.hostKey, allowed: [])
    let host = try #require(try mac.records(VaultHost.self).first)

    // The phone's store, with the Mac's records as they arrive through sync.
    let phone = try store("phone")
    try phone.save(host)
    try phone.save(VaultProject(id: "p1", name: "Code", paths: ["mac": "/Users/me/Code"]))
    let vault = Vault(store: phone)
    let project = try #require(vault.projects.first)
    let place = try #require(vault.otherPlaces(of: project).first)
    #expect(place.host?.id == host.id)
    #expect(place.path == "/Users/me/Code")
    #expect(vault.vaultDevice(of: host) == "mac")
  }

  @Test @MainActor func anAccountsProjectsUsePersonalsHosts() throws {
    let phone = try FakeDevice("phone", personalKeys: keys)
    let mac = try store()
    try mac.publishDeviceHost(name: "Studio", address: "Studio.local", user: "me", hostKey: Self.hostKey, allowed: [])
    try phone.personal.save(try #require(try mac.records(VaultHost.self).first))
    phone.vaults.personal.reload()

    let acme = try phone.vaults.createAccount(name: "Acme")
    let vault = try #require(phone.vaults.vault(for: acme))
    vault.save(VaultProject(id: "p1", name: "Site", paths: ["mac": "/Users/me/Site"]))
    let project = try #require(vault.projects.first)
    let place = try #require(vault.otherPlaces(of: project).first)
    #expect(place.host?.device?.deviceID == "mac")
    #expect(vault.personalVault === phone.vaults.personal)
  }

  @Test func authorizedKeysKeepTheirOtherLines() throws {
    let file = temporaryDirectory().appendingPathComponent(".ssh/authorized_keys")
    let keys = VaultAuthorizedKeys(url: file)
    let phone = VaultDeviceKey(id: "phone", deviceName: "iPhone", publicKey: Self.phoneKey, platform: "iOS")
    #expect(try keys.allowedDevices(among: [phone]).isEmpty)

    try keys.allow(phone)
    try keys.allow(phone)
    #expect(try keys.lines().count == 1)
    #expect(try keys.allowedDevices(among: [phone]) == ["phone"])
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)

    // A line added by hand stays through everything but disallowing its key.
    let other = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 laptop"
    try keys.write(try keys.lines() + [other])
    try keys.removeStale(keeping: [phone])
    #expect(try keys.lines().contains(other))
    try keys.disallow(phone)
    #expect(try keys.lines() == [other])
  }

  @Test func aNewKeyNeedsAllowingAgain() throws {
    let keys = VaultAuthorizedKeys(url: temporaryDirectory().appendingPathComponent("authorized_keys"))
    var phone = VaultDeviceKey(id: "phone", deviceName: "iPhone", publicKey: Self.phoneKey, platform: "iOS")
    try keys.allow(phone)
    #expect(try !keys.removeStale(keeping: [phone]))

    phone.publicKey = HubMirrorTests.hostKey + " iPhone"
    #expect(try keys.removeStale(keeping: [phone]))
    #expect(try keys.allowedDevices(among: [phone]).isEmpty)

    // A device that's gone loses its line too.
    try keys.allow(phone)
    #expect(try keys.removeStale(keeping: []))
    #expect(try keys.lines().isEmpty)
  }

  @Test func keyMaterialSkipsOptions() {
    let line = #"from="10.0.0.0/8",no-pty ecdsa-sha2-nistp256 AAAA v57-device=abc My Phone"#
    #expect(VaultAuthorizedKeys.keyMaterial(of: line) == "ecdsa-sha2-nistp256 AAAA")
    #expect(VaultAuthorizedKeys.device(of: line) == "abc")
    #expect(VaultAuthorizedKeys.keyMaterial(of: "# comment") == nil)
  }
}
