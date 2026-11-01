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

  @Test @MainActor func aMacsPlacesTryItsOtherAddresses() throws {
    let mac = try store()
    try mac.publishDeviceHost(name: "Studio", address: "Studio.local", user: "me", hostKey: Self.hostKey, allowed: [])
    var host = try #require(try mac.records(VaultHost.self).first)
    host.hostname = "studio.tail1234.ts.net"
    host.fallbacks = ["192.168.1.20", "Studio.local"]
    try mac.save(host)

    let phone = try store("phone")
    try phone.save(try #require(try mac.records(VaultHost.self).first))
    try phone.save(VaultProject(id: "p1", name: "Code", paths: ["mac": "/Users/me/Code"]))
    let vault = Vault(store: phone)
    let saved = try #require(vault.deviceHosts.first)
    #expect(saved.fallbacks == ["192.168.1.20", "Studio.local"])
    #expect(vault.addresses(of: saved) == ["studio.tail1234.ts.net", "192.168.1.20", "Studio.local"])
    let project = try #require(vault.projects.first)
    let place = try #require(vault.otherPlaces(of: project).first)
    #expect(place.fallbackAddresses == ["192.168.1.20", "Studio.local"])
  }

  @Test @MainActor func eachDeviceKeepsItsRepositorysStatusInTheProject() throws {
    let mac = try store()
    try mac.save(VaultProject(id: "p1", name: "Code", paths: ["mac": "/Users/me/Code", "laptop": "/Users/me/Code"]))
    let vault = Vault(store: mac)
    let status = VaultProject.Status(
      branch: "main", changeCount: 2, ahead: 1, hasUpstream: true,
      files: [.init(path: "a.swift", kind: "M", area: "unstaged"), .init(path: "b.swift", kind: "?", area: "unstaged")])
    vault.setStatus(status, ofProjectAt: "/Users/me/Code")
    #expect(vault.projects.first?.statuses == ["mac": status])

    // Another device's status in the same project stays.
    var record = try #require(try mac.record(VaultProject.self, id: "p1"))
    record.statuses["laptop"] = VaultProject.Status(branch: "dev", changeCount: 0)
    try mac.save(record)
    vault.reload()
    #expect(try mac.record(VaultProject.self, id: "p1")?.statuses.keys.sorted() == ["laptop", "mac"])
    #expect(vault.projects.first?.statuses["mac"] == status)
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

  @Test func anyKeyCanBeListedAddedAndRemoved() throws {
    let keys = VaultAuthorizedKeys(url: temporaryDirectory().appendingPathComponent("authorized_keys"))
    let phone = VaultDeviceKey(id: "phone", deviceName: "iPhone", publicKey: Self.phoneKey, platform: "iOS")
    try keys.allow(phone)
    let laptop = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me@laptop"
    try keys.add(line: laptop + "\n")
    try keys.add(line: laptop)
    #expect(throws: VaultAuthorizedKeys.AuthorizedKeysError.self) { try keys.add(line: "not a key") }
    #expect(!VaultAuthorizedKeys.isKeyLine("ssh-ed25519 not*base64"))

    let entries = try keys.entries()
    #expect(entries.map(\.device) == ["phone", nil])
    #expect(entries.map(\.comment) == ["iPhone", "me@laptop"])

    try keys.remove(material: entries[1].material)
    #expect(try keys.entries().map(\.device) == ["phone"])
  }

  #if os(macOS)
    @Test func passwordLoginFollowsSSHDsFirstValue() throws {
      let folder = temporaryDirectory()
      let included = folder.appendingPathComponent("sshd_config.d")
      try FileManager.default.createDirectory(at: included, withIntermediateDirectories: true)
      // As macOS ships it: PAM on, nothing about passwords.
      try "# comment\nInclude \(included.path)/*\n#PasswordAuthentication yes\n".write(
        to: folder.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
      try "UsePAM yes\n".write(to: included.appendingPathComponent("100-macos.conf"), atomically: true, encoding: .utf8)
      #expect(VaultThisMac.passwordLoginIsOn(directory: folder))

      // The apps' file comes first, so its values win; a Match block's don't count.
      try "PasswordAuthentication no\nKbdInteractiveAuthentication no\n".write(
        to: included.appendingPathComponent("050-v57-keys-only.conf"), atomically: true, encoding: .utf8)
      #expect(!VaultThisMac.passwordLoginIsOn(directory: folder))
      try "Match User guest\n  PasswordAuthentication no\n".write(
        to: included.appendingPathComponent("050-v57-keys-only.conf"), atomically: true, encoding: .utf8)
      #expect(VaultThisMac.passwordLoginIsOn(directory: folder))
    }
  #endif

  @Test func keyMaterialSkipsOptions() {
    let line = #"from="10.0.0.0/8",no-pty ecdsa-sha2-nistp256 AAAA v57-device=abc My Phone"#
    #expect(VaultAuthorizedKeys.keyMaterial(of: line) == "ecdsa-sha2-nistp256 AAAA")
    #expect(VaultAuthorizedKeys.device(of: line) == "abc")
    #expect(VaultAuthorizedKeys.keyMaterial(of: "# comment") == nil)
  }
}

/// Renaming a device: the record, this device's name, and the `authorized_keys` lines Vault wrote.
@MainActor
struct DeviceNameTests {
  let keys = MemoryKeyProvider()

  init() { VaultSecrets.useInMemoryStore() }

  func store(_ device: String = "mac") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  @Test func renamingADeviceKeepsItUntilItsCleared() throws {
    let store = try store()
    #expect(throws: VaultDeviceError.self) { try store.renameDevice("phone", to: "Pocket") }
    try store.save(VaultDeviceKey(id: "phone", deviceName: "iPhone", publicKey: DeviceHostTests.phoneKey, platform: "iOS"))

    try store.renameDevice("phone", to: "  Pocket\n")
    var phone = try #require(try store.record(VaultDeviceKey.self, id: "phone"))
    #expect(phone.customName == "Pocket")
    #expect(phone.deviceName == "Pocket")

    // Back to the system's name: the device publishes it again; until then the old one shows.
    try store.renameDevice("phone", to: " ")
    phone = try #require(try store.record(VaultDeviceKey.self, id: "phone"))
    #expect(phone.customName == nil)
    #expect(phone.deviceName == "Pocket")
  }

  @Test func theVaultGivesThisDeviceItsName() throws {
    let store = try store()
    let material = try #require(VaultAuthorizedKeys.keyMaterial(of: DeviceHostTests.phoneKey))
    try store.save(
      VaultDeviceKey(id: "mac", deviceName: "Studio", customName: "Studio", publicKey: "\(material) Studio", platform: "macOS"))
    defer { VaultDevice.customName = nil }
    _ = Vault(store: store)
    #expect(VaultDevice.customName == "Studio")
    #expect(VaultDevice.name == "Studio")
  }

  @Test func authorizedKeysFollowARename() throws {
    let keys = VaultAuthorizedKeys(url: temporaryDirectory().appendingPathComponent("authorized_keys"))
    var phone = VaultDeviceKey(id: "phone", deviceName: "iPhone", publicKey: DeviceHostTests.phoneKey, platform: "iOS")
    try keys.allow(phone)
    let material = try #require(VaultAuthorizedKeys.keyMaterial(of: phone.publicKey))
    // Options someone added stay.
    try keys.write([#"no-pty "# + (try keys.lines()[0])])
    #expect(try !keys.removeStale(keeping: [phone]))

    phone.deviceName = "Pocket"
    #expect(try keys.removeStale(keeping: [phone]))
    #expect(try keys.lines() == ["no-pty \(material) v57-device=phone Pocket"])
    #expect(try keys.allowedDevices(among: [phone]) == ["phone"])
  }
}
