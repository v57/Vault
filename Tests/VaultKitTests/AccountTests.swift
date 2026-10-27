import Foundation
import Testing

@testable import VaultKit

/// Accounts as vaults of their own: two accounts beside Personal on three devices sharing one fake CloudKit database.
@MainActor
struct AccountTests {
  let personalKeys = MemoryKeyProvider()
  let database = FakeDatabase()

  init() { VaultSecrets.useInMemoryStore() }

  func device(_ name: String) throws -> FakeDevice {
    try FakeDevice(name, personalKeys: personalKeys)
  }

  func project(_ name: String, remote: String? = nil, device: String) -> VaultProject {
    VaultProject(id: UUID().uuidString, name: name, remoteURL: remote, paths: [device: "/src/\(name)"], addedBy: "test")
  }

  @Test func personalStaysAsItWas() throws {
    let mac = try device("mac")
    let personalMailbox = try mac.personal.derivedID("hub-vault")  // as before accounts
    let acme = try mac.vaults.createAccount(name: "Acme")
    let acmeVault = try #require(mac.vaults.vault(for: acme))

    #expect(mac.vaults.vault(for: .personal) === mac.vaults.personal)
    #expect(mac.vaults.personal.isPersonal)
    #expect(mac.personal.fileURL.lastPathComponent == "Vault.sqlite")
    #expect(VaultAccount.personal.zoneName == "Vault")
    #expect(acme.zoneName == "Vault-\(acme.id)")
    #expect(acmeVault.store?.fileURL.lastPathComponent == "\(acme.id).sqlite")
    #expect(acmeVault.store?.directory == mac.personal.directory)
    // Personal's mailbox is untouched; the account has its own, under the same key.
    let acmeStore = try #require(acmeVault.store)
    let box = FakeMailbox()
    #expect(try HubSync(store: mac.personal, mailbox: box.device("mac"), deviceID: "mac").vaultID() == personalMailbox)
    #expect(try HubSync(store: acmeStore, mailbox: box.device("mac"), deviceID: "mac").vaultID() != personalMailbox)
    #expect(try acmeStore.keys.primary().id == personalKeys.primary().id)
    #expect(mac.personal.accountID == nil)
    #expect(acmeStore.accountID == acme.id)
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
      try device.vaults.allAccounts.map { try #require(device.vaults.vault(for: $0)?.store).hubVaultID() }
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

  @Test func accountsSealWithTheVaultKeys() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    let acme = try mac.vaults.createAccount(name: "Acme")
    try #require(mac.vault("Acme")).save(project("Rocket", device: "mac"))
    mac.sync(database)

    // CloudKit holds the account's records sealed with Personal's key, which every device already has.
    let personalKey = try personalKeys.primary().id
    #expect(database.zone(acme.zoneName).records.values.map(\.keyID) == [personalKey])
    phone.sync(database)
    #expect(phone.vault("Acme")?.projects.map(\.name) == ["Rocket"])
    try #require(phone.vault("Acme")).save(project("Draft", device: "phone"))
    #expect(phone.vault("Acme")?.error == nil)
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

  // MARK: Deleting

  @Test func deletingAnAccountRemovesItsZoneMailboxPasswordsAndStore() async throws {
    let mac = try device("mac")
    let phone = try device("phone")
    let pad = try device("pad")
    let hub = FakeHub()
    let acme = try mac.vaults.createAccount(name: "Acme")
    let globex = try mac.vaults.createAccount(name: "Globex")
    mac.vaults.personal.save(project("Dotfiles", device: "mac"))
    mac.vaults.personal.save(VaultHost(id: "h1", hostname: "home.lan"))
    try #require(mac.vault("Acme")).save(project("Rocket", device: "mac"))
    try #require(mac.vault("Globex")).save(project("Dome", device: "mac"))
    // Passwords of each vault's records.
    let homeHost = UUID().uuidString, acmeHost = UUID().uuidString, acmeLogin = UUID().uuidString
    let globexHost = UUID().uuidString
    mac.vaults.personal.save(VaultHost(id: homeHost, hostname: "nas.lan"))
    try #require(mac.vault("Acme")).save(VaultHost(id: acmeHost, hostname: "build.acme.com"))
    try #require(mac.vault("Acme")?.store).save(VaultLogin(id: acmeLogin, title: "Acme SSO"))
    try #require(mac.vault("Globex")).save(VaultHost(id: globexHost, hostname: "ci.globex.com"))
    for id in [homeHost, acmeHost, acmeLogin, globexHost] { try VaultSecrets.setPassword("secret-\(id)", for: id) }
    try VaultSecrets.setSecretText("JBSWY3DPEHPK3PXP", named: VaultLogin.oneTimeCodeSecret(acmeLogin))
    for device in [mac, phone, pad] { device.sync(database) }

    // Every device syncs every vault through the Hub too.
    for device in [mac, phone, pad] {
      for account in device.vaults.allAccounts {
        let store = try #require(device.vaults.vault(for: account)?.store)
        try await HubSync(store: store, mailbox: hub.device("hub-\(device.name)"), deviceID: "hub-\(device.name)").sync()
      }
    }
    func mailbox(_ device: FakeDevice, _ account: VaultAccount) throws -> FakeMailbox {
      hub.mailbox(try #require(device.vaults.vault(for: account)?.store).hubVaultID())
    }
    let acmeMailbox = try mailbox(mac, acme)
    let globexMailbox = try mailbox(mac, globex)
    let personalMailbox = try mailbox(mac, .personal)
    #expect(acmeMailbox.memberIDs.count == 3)
    let personalRevision = mac.personal.revision

    // The pad is away while the Mac deletes the account.
    let failures = try await mac.vaults.delete(acme, hubs: [(hub.device("hub-mac"), "hub-mac")])
    #expect(failures.isEmpty)
    #expect(acmeMailbox.memberIDs.isEmpty)
    #expect(acmeMailbox.waiting == 0)
    #expect(globexMailbox.memberIDs.count == 3)
    #expect(personalMailbox.memberIDs.count == 3)
    // The account's passwords went with it; the others' stay.
    #expect(VaultSecrets.password(for: acmeHost) == nil)
    #expect(VaultSecrets.password(for: acmeLogin) == nil)
    #expect(VaultSecrets.secretText(VaultLogin.oneTimeCodeSecret(acmeLogin)) == nil)
    #expect(VaultSecrets.password(for: homeHost) == "secret-\(homeHost)")
    #expect(VaultSecrets.password(for: globexHost) == "secret-\(globexHost)")
    #expect(mac.vaults.accounts.map(\.name) == ["Globex"])
    #expect(mac.vaults.vault(for: acme) == nil)
    #expect(mac.files == ["\(globex.id).sqlite", "Vault.sqlite"].sorted())
    // Personal lost only the account's record.
    #expect(mac.personal.revision == personalRevision + 1)
    mac.sync(database)
    #expect(database.zoneNames == ["Vault", globex.zoneName].sorted())

    phone.sync(database)
    pad.sync(database)
    #expect(database.zoneNames == ["Vault", globex.zoneName].sorted())
    for device in [mac, phone, pad] {
      #expect(device.vaults.accounts.map(\.name) == ["Globex"])
      #expect(device.files == ["\(globex.id).sqlite", "Vault.sqlite"].sorted())
      #expect(device.vault("Globex")?.projects.map(\.name) == ["Dome"])
      #expect(device.vaults.personal.projects.map(\.name) == ["Dotfiles"])
      #expect(device.vaults.personal.hosts.map(\.hostname).sorted() == ["home.lan", "nas.lan"])
      #expect(device.app.zones.coordinator(forZone: acme.zoneName) == nil)
    }
  }

  @Test func anAccountsZoneLeftBehindGoesWithTheFirstDeviceThatSeesTheTombstone() async throws {
    let mac = try device("mac")
    let phone = try device("phone")
    let acme = try mac.vaults.createAccount(name: "Acme")
    try #require(mac.vault("Acme")).save(project("Rocket", device: "mac"))
    mac.sync(database)
    phone.sync(database)

    // The Mac's engine sends Personal's tombstone but doesn't delete the zone.
    try await mac.vaults.delete(acme)
    mac.app.push(database, deletingZones: false)
    #expect(database.zoneNames.contains(acme.zoneName))

    phone.sync(database)
    #expect(database.zoneNames == ["Vault"])
    #expect(phone.vaults.accounts.isEmpty)
    #expect(phone.files == ["Vault.sqlite"])
  }

  @Test func personalCantBeDeleted() async throws {
    let mac = try device("mac")
    await #expect(throws: VaultAccountStores.AccountError.personal) { try await mac.vaults.delete(.personal) }
    #expect(mac.files == ["Vault.sqlite"])
  }
}
