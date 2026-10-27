import Foundation
import Testing

@testable import VaultKit

/// Accounts as vaults of their own: two accounts beside Personal on three devices sharing one fake CloudKit database.
@MainActor
struct AccountTests {
  let personalKeys = MemoryKeyProvider()
  let accountKeys = MemoryAccountKeychain()
  let database = FakeDatabase()

  init() { VaultSecrets.useInMemoryStore() }

  func device(_ name: String) throws -> FakeDevice {
    try FakeDevice(name, personalKeys: personalKeys, accountKeys: accountKeys)
  }

  func project(_ name: String, remote: String? = nil, device: String) -> VaultProject {
    VaultProject(id: UUID().uuidString, name: name, remoteURL: remote, paths: [device: "/src/\(name)"], addedBy: "test")
  }

  @Test func personalStaysAsItWas() throws {
    let mac = try device("mac")
    let personalMailbox = try mac.personal.derivedID("hub-vault")
    let acme = try mac.vaults.createAccount(name: "Acme")
    let acmeVault = try #require(mac.vaults.vault(for: acme))

    #expect(mac.vaults.vault(for: .personal) === mac.vaults.personal)
    #expect(mac.vaults.personal.isPersonal)
    #expect(mac.personal.fileURL.lastPathComponent == "Vault.sqlite")
    #expect(VaultAccount.personal.zoneName == "Vault")
    #expect(acme.zoneName == "Vault-\(acme.id)")
    #expect(acmeVault.store?.fileURL.lastPathComponent == "\(acme.id).sqlite")
    #expect(acmeVault.store?.directory == mac.personal.directory)
    // Personal's mailbox and key are untouched; the account's are its own.
    #expect(try mac.personal.derivedID("hub-vault") == personalMailbox)
    let acmeStore = try #require(acmeVault.store)
    #expect(try HubSync(store: acmeStore, mailbox: FakeMailbox().device("mac"), deviceID: "mac").vaultID() != personalMailbox)
    #expect(try acmeStore.keys.primary().id == acme.keyID)
    #expect(try acmeStore.keys.primary().id != personalKeys.primary().id)
    // The account's record is in Personal; nothing of the account is.
    #expect(try mac.personal.records(VaultAccount.self).map(\.name) == ["Acme"])
    acmeVault.save(project("Rocket", device: "mac"))
    #expect(try mac.personal.records(VaultProject.self).isEmpty)
    #expect(try acmeStore.records(VaultAccount.self).isEmpty)
  }

  @Test func twoAccountsSyncOnThreeDevices() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    let pad = try device("pad")
    let acme = try mac.vaults.createAccount(name: "Acme", color: "orange")
    let globex = try mac.vaults.createAccount(name: "Globex", color: "green")
    mac.vaults.personal.save(project("Dotfiles", device: "mac"))
    try #require(mac.vault("Acme")).save(project("Rocket", device: "mac"))
    try #require(mac.vault("Acme")).save(VaultAppleTeam(teamID: "ACME000001", name: "Acme Inc."))
    try #require(mac.vault("Globex")).save(project("Dome", device: "mac"))

    mac.sync(database)
    phone.sync(database)
    pad.sync(database)

    #expect(database.zoneNames == ["Vault", acme.zoneName, globex.zoneName].sorted())
    for device in [mac, phone, pad] {
      #expect(device.vaults.accounts.map(\.name) == ["Acme", "Globex"])
      #expect(device.vaults.accounts.map(\.color) == ["orange", "green"])
      #expect(device.vaults.personal.projects.map(\.name) == ["Dotfiles"])
      #expect(device.vault("Acme")?.projects.map(\.name) == ["Rocket"])
      #expect(device.vault("Acme")?.appleTeams.map(\.teamID) == ["ACME000001"])
      #expect(device.vault("Globex")?.projects.map(\.name) == ["Dome"])
      #expect(device.vault("Globex")?.appleTeams.isEmpty == true)
      #expect(device.files == ["\(acme.id).sqlite", "\(globex.id).sqlite", "Vault.sqlite"].sorted())
    }

    // Edits on two devices, in two accounts, merge field by field.
    var rocket = try #require(phone.vault("Acme")?.projects.first)
    rocket.name = "Rocket 2"
    try #require(phone.vault("Acme")).save(rocket)
    var onPad = try #require(pad.vault("Acme")?.projects.first)
    onPad.order = 5
    try #require(pad.vault("Acme")).save(onPad)
    try #require(pad.vault("Globex")).save(project("Lab", device: "pad"))
    phone.sync(database)
    pad.sync(database)
    mac.sync(database)
    phone.sync(database)

    for device in [mac, phone, pad] {
      #expect(device.vault("Acme")?.projects.map(\.name) == ["Rocket 2"])
      #expect(device.vault("Acme")?.projects.first?.order == 5)
      #expect(device.vault("Globex")?.projects.map(\.name) == ["Dome", "Lab"])
      #expect(device.vaults.personal.projects.map(\.name) == ["Dotfiles"])
      for zone in [VaultAccount.personal.zoneName, acme.zoneName, globex.zoneName] {
        #expect(try device.app.zones.coordinator(forZone: zone)?.store.pendingCount() == 0)
      }
    }

    // Each account's Hub mailbox is derived from its key: the same on every device, apart from the others.
    func mailboxes(_ device: FakeDevice) throws -> [String] {
      try device.vaults.allAccounts.map { try #require(device.vaults.vault(for: $0)?.store).derivedID("hub-vault") }
    }
    #expect(Set(try mailboxes(mac)).count == 3)
    #expect(try mailboxes(phone) == mailboxes(mac))
    #expect(try mailboxes(pad) == mailboxes(mac))
  }

  @Test func recordsThatArriveBeforeTheirAccountAreKept() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    let acme = try mac.vaults.createAccount(name: "Acme")
    try #require(mac.vault("Acme")).save(project("Rocket", device: "mac"))
    mac.sync(database)

    // The account's zone comes before Personal's.
    phone.app.pull(database, only: [acme.zoneName])
    phone.reload()
    #expect(phone.vaults.accounts.isEmpty)
    #expect(phone.files.contains("\(acme.id).sqlite"))
    phone.sync(database)
    #expect(phone.vault("Acme")?.projects.map(\.name) == ["Rocket"])
  }

  @Test func anAccountWaitsForItsKey() throws {
    let mac = try device("mac")
    let acme = try mac.vaults.createAccount(name: "Acme")
    try #require(mac.vault("Acme")).save(project("Rocket", device: "mac"))
    mac.sync(database)

    // A device whose iCloud Keychain hasn't brought the account's key: records wait, writes fail.
    let elsewhere = MemoryAccountKeychain()
    let phone = try FakeDevice("phone", personalKeys: personalKeys, accountKeys: elsewhere)
    phone.sync(database)
    let vault = try #require(phone.vaults.vault(for: acme))
    #expect(vault.projects.isEmpty)
    vault.save(project("Draft", device: "phone"))
    #expect(vault.error != nil)
    #expect(try #require(phone.vaults.vault(for: .personal)?.store).keys.primary().id == personalKeys.primary().id)
  }

  @Test func matchesTeamsAndGitHubOwnersToAccounts() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    let acme = try mac.vaults.createAccount(name: "Acme")
    let globex = try mac.vaults.createAccount(name: "Globex")
    mac.vaults.personal.save(VaultAppleTeam(teamID: "AUCR797TMH", name: "Me"))
    mac.vaults.personal.save(VaultAppleTeam(teamID: "SHARED0001", name: "Old team"))
    mac.vaults.personal.save(project("Vault", remote: "https://github.com/v57/Vault.git", device: "mac"))
    try #require(mac.vault("Acme")).save(VaultAppleTeam(teamID: "ACME000001", name: "Acme Inc."))
    try #require(mac.vault("Acme")).save(VaultAppleTeam(teamID: "SHARED0001", name: "Old team"))
    try #require(mac.vault("Acme")).save(project("Rocket", remote: "git@github.com:Acme-Corp/rocket.git", device: "mac"))
    try #require(mac.vault("Globex")).save(project("Dome", remote: "ssh://git@github.com/globex/dome", device: "mac"))
    mac.sync(database)
    phone.sync(database)

    for vaults in [mac.vaults, phone.vaults] {
      #expect(vaults.account(forTeam: "ACME000001") == acme)
      #expect(vaults.account(forTeam: "AUCR797TMH") == .personal)
      // A team in Personal and an organization goes to the organization.
      #expect(vaults.account(forTeam: "SHARED0001") == acme)
      #expect(vaults.account(forTeam: "NOBODY0000") == nil)
      #expect(vaults.account(forGitHubOwner: "acme-corp") == acme)
      #expect(vaults.account(forGitHubOwner: "globex") == globex)
      #expect(vaults.account(forGitHubOwner: "v57") == .personal)
      #expect(vaults.account(forGitHubOwner: "initech") == nil)
    }
  }

  @Test func readsGitHubOwnersFromRemotes() {
    let owner = VaultProject.gitHubOwner(ofRemote:)
    #expect(owner("https://github.com/v57/Vault.git") == "v57")
    #expect(owner("https://www.github.com/v57/Vault") == "v57")
    #expect(owner("git@github.com:acme/rocket.git") == "acme")
    #expect(owner("ssh://git@github.com/acme/rocket.git") == "acme")
    #expect(owner("ssh://git@github.com:22/acme/rocket.git") == "acme")
    #expect(owner("https://user:token@github.com/acme/rocket") == "acme")
    #expect(owner("https://gitlab.com/acme/rocket") == nil)
    #expect(owner("https://github.com/acme") == nil)
    #expect(owner("/Users/me/rocket") == nil)
  }
}
