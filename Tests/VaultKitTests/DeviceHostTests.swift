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

  @Test func aRunWithSecretsInMemoryNeverOpensTheUsersStore() throws {
    let temporary = FileManager.default.temporaryDirectory.path
    #expect(VaultConfiguration.defaultDirectory().path.hasPrefix(temporary))
    #expect(try #require(VaultStore.shared).directory.path.hasPrefix(temporary))
  }

  @Test func removingADeviceTakesItOutOfTheVault() throws {
    let store = try store()
    try store.save(VaultDeviceKey(id: "old", deviceName: "Old Mac", publicKey: Self.phoneKey, platform: "macOS"))
    let route = VaultHost.DeviceRoute(deviceID: "old", address: "Old.local", hostKey: Self.hostKey, allowed: [])
    var host = VaultHost(id: "published", name: "Old Mac", hostname: "Old.local", user: "me", source: "device")
    host.device = route
    try store.save(host)
    try store.trust(fingerprint: try #require(route.hostKeyFingerprint), host: "Old.local", port: 22)
    let status = VaultProject.Status(branch: "main", changeCount: 0)
    var onBoth = VaultProject(id: "both", name: "both", paths: ["old": "/both", "mac": "/both"])
    onBoth.statuses = ["old": status, "mac": status]
    try store.save(onBoth)
    try store.save(VaultProject(id: "gone", name: "gone", paths: ["old": "/gone"]))
    try store.save(VaultProject(id: "moved", name: "moved", paths: ["old": "/moved"]))
    try store.save(VaultProject(id: "duplicate", name: "duplicate", paths: ["old": "/both"]))
    try store.save(VaultFolder(name: "Notes", paths: ["old": "/notes", "mac": "/notes"]))
    try store.save(VaultHubServer(id: "hub", url: "ws://hub", connects: ["old", "mac"], members: ["old": "a", "mac": "b"]))

    try store.removeDevice("old") { $0 == "/moved" || $0 == "/both" }

    #expect(try store.record(VaultDeviceKey.self, id: "old") == nil)
    #expect(try store.record(VaultHost.self, id: "published") == nil)
    #expect(try store.knownFingerprint(host: "Old.local", port: 22) == nil)
    let both = try #require(try store.record(VaultProject.self, id: "both"))
    #expect(both.paths == ["mac": "/both"])
    #expect(both.statuses == ["mac": status])
    // The folder isn't here, or another project already has it here: nothing keeps the project.
    #expect(try store.record(VaultProject.self, id: "gone") == nil)
    #expect(try store.record(VaultProject.self, id: "duplicate") == nil)
    #expect(try store.record(VaultProject.self, id: "moved")?.paths == ["mac": "/moved"])
    #expect(try store.records(VaultFolder.self).first?.paths == ["mac": "/notes"])
    let hub = try #require(try store.record(VaultHubServer.self, id: "hub"))
    #expect(hub.connects == ["mac"])
    #expect(hub.members == ["mac": "b"])
  }

  @Test func aRemovedProjectsEmptyGroupGoesToo() throws {
    let store = try store()
    try store.save(VaultProject(id: "only", name: "only", paths: ["old": "/only"]))
    try store.save(VaultProject(id: "kept", name: "kept", paths: ["mac": "/kept"]))
    let group = try #require(try store.groupProjects(["only"], name: "Group"))

    try store.removeDevice("old")

    #expect(try store.record(VaultProjectGroup.self, id: group.id) == nil)
    #expect(try store.record(VaultProject.self, id: "kept") != nil)
  }

  @Test func aDeviceCantRemoveItself() throws {
    let store = try store()
    #expect(throws: VaultDeviceError.self) { try store.removeDevice("mac") }
  }

  @Test func aRemovedDeviceCanComeBack() throws {
    let store = try store()
    let key = VaultDeviceKey(id: "old", deviceName: "Old Mac", publicKey: Self.phoneKey, platform: "macOS")
    try store.save(key)
    try store.removeDevice("old")
    try store.save(key)
    #expect(try store.record(VaultDeviceKey.self, id: "old")?.deviceName == "Old Mac")
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
    #expect(vault.otherDeviceHosts.map(\.id) == [saved.id])
    #expect(Vault(store: mac).otherDeviceHosts.isEmpty)
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

  @Test @MainActor func aStatusKeepsItsDatesAndOldOnesHaveNone() throws {
    let mac = try store()
    try mac.save(VaultProject(id: "p1", name: "Code", paths: ["mac": "/Users/me/Code"]))
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let status = VaultProject.Status(branch: "main", changeCount: 0, lastCommit: date, lastPush: date)
    Vault(store: mac).setStatus(status, ofProjectAt: "/Users/me/Code")
    #expect(try mac.record(VaultProject.self, id: "p1")?.statuses["mac"] == status)

    // As a build from before the dates wrote it.
    let old = try #require(
      VaultProject.Status(json: #"{"ahead":0,"behind":0,"changeCount":1,"conflictCount":0,"files":[],"hasUpstream":false}"#))
    #expect(old.lastCommit == nil && old.lastPush == nil)
    #expect(old.needsAttention)
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

  /// Keys and names come from synced records: neither may add a line, which sshd would read with its own options.
  @Test func aRecordCantAddAnotherLineToAuthorizedKeys() throws {
    let file = temporaryDirectory().appendingPathComponent(".ssh/authorized_keys")
    let keys = VaultAuthorizedKeys(url: file)
    let forged = VaultDeviceKey(
      id: "forged", deviceName: "iPhone", publicKey: "ssh-x\ncommand=\"touch /tmp/x\" ssh-rsa AAAA", platform: "iOS")
    #expect(throws: VaultAuthorizedKeys.AuthorizedKeysError.self) { try keys.allow(forged) }
    #expect(try keys.lines().isEmpty)

    let phone = VaultDeviceKey(
      id: "phone", deviceName: "iPhone\ncommand=\"touch /tmp/x\" ssh-rsa AAAA\r\u{0}", publicKey: Self.phoneKey,
      platform: "iOS")
    try keys.allow(phone)
    #expect(try keys.lines().count == 1)
    var renamed = phone
    renamed.deviceName = "Phone\nssh-rsa AAAA"
    try keys.removeStale(keeping: [renamed])
    #expect(try keys.lines().count == 1)
    #expect(try keys.allowedDevices(among: [phone]) == ["phone"])
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
