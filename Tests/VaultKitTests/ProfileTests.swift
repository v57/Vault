import Foundation
import Testing

@testable import VaultKit

/// Each account's name and email (`VaultProfile`), kept in Personal, and what the Your Name sheet suggests.
@MainActor
struct ProfileTests {
  let personalKeys = MemoryKeyProvider()
  let database = FakeDatabase()

  init() { VaultSecrets.useInMemoryStore() }

  func device(_ name: String) throws -> FakeDevice {
    try FakeDevice(name, personalKeys: personalKeys)
  }

  @Test func emptyUntilAsked() throws {
    let mac = try device("mac")
    let acme = try mac.vaults.createAccount(name: "Acme")
    #expect(mac.vaults.profile(for: .personal) == VaultProfile(account: "personal"))
    #expect(mac.vaults.profile(for: acme) == VaultProfile(account: acme.id))
    #expect(mac.vaults.profile(for: acme).isComplete == false)
    #expect(mac.vaults.profile(for: acme).signature == nil)
  }

  @Test func anAccountTakesPersonalsNameButNotItsEmail() throws {
    let mac = try device("mac")
    let acme = try mac.vaults.createAccount(name: "Acme")
    mac.vaults.save(VaultProfile(account: "personal", name: " Ada Lovelace\n", email: "ada@example.com "))

    #expect(mac.vaults.profile(for: .personal).signature == "Ada Lovelace <ada@example.com>")
    #expect(mac.vaults.profile(for: acme) == VaultProfile(account: acme.id, name: "Ada Lovelace"))

    mac.vaults.save(VaultProfile(account: acme.id, email: "ada@acme.example"))
    #expect(mac.vaults.profile(for: acme).signature == "Ada Lovelace <ada@acme.example>")
    mac.vaults.save(VaultProfile(account: acme.id, name: "A. Lovelace", email: "ada@acme.example"))
    #expect(mac.vaults.profile(for: acme).name == "A. Lovelace")
    #expect(mac.vaults.profile(for: .personal).name == "Ada Lovelace")

    // In Personal's store, under the account's id; nothing in the account's.
    #expect(try mac.personal.records(VaultProfile.self).map(\.account).sorted() == [acme.id, "personal"].sorted())
    #expect(mac.vaults.accounts == [acme])
    #expect(try #require(mac.vault("Acme")?.store).records(VaultProfile.self).isEmpty)
  }

  @Test func syncsWithPersonalAndMergesFieldByField() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    let acme = try mac.vaults.createAccount(name: "Acme")
    mac.vaults.save(VaultProfile(account: acme.id, name: "Ada", email: "ada@acme.example"))
    mac.sync(database)
    phone.sync(database)
    #expect(phone.vaults.profile(for: acme).signature == "Ada <ada@acme.example>")

    // A name changed on one device and an email on the other both stay.
    var onMac = mac.vaults.profile(for: acme)
    onMac.name = "Ada Lovelace"
    mac.vaults.save(onMac)
    var onPhone = phone.vaults.profile(for: acme)
    onPhone.email = "lovelace@acme.example"
    phone.vaults.save(onPhone)
    mac.sync(database)
    phone.sync(database)
    mac.sync(database)
    for device in [mac, phone] {
      #expect(device.vaults.profile(for: acme).signature == "Ada Lovelace <lovelace@acme.example>")
    }
  }

  @Test func goesWithItsAccount() async throws {
    let mac = try device("mac")
    let phone = try device("phone")
    let acme = try mac.vaults.createAccount(name: "Acme")
    mac.vaults.save(VaultProfile(account: "personal", name: "Ada", email: "ada@example.com"))
    mac.vaults.save(VaultProfile(account: acme.id, email: "ada@acme.example"))
    mac.sync(database)
    phone.sync(database)

    try await mac.vaults.delete(acme)
    mac.sync(database)
    phone.sync(database)
    for device in [mac, phone] {
      #expect(try device.personal.records(VaultProfile.self).map(\.account) == ["personal"])
    }
  }

  @Test func suggestionsFillOnlyEmptyFields() throws {
    let mac = try device("mac")
    let acme = try mac.vaults.createAccount(name: "Acme")
    let git = GitGlobalIdentity(name: "Ada (git)", email: "ada@git.example")
    let gitHub: (name: String?, email: String?) = ("Ada (GitHub)", "1+ada@users.noreply.github.com")

    // Git's global configuration comes first, then the GitHub sign-in.
    #expect(mac.vaults.suggestedProfile(for: .personal, gitHub: gitHub, git: git).signature == "Ada (git) <ada@git.example>")
    #expect(
      mac.vaults.suggestedProfile(for: .personal, gitHub: gitHub, git: GitGlobalIdentity()).signature
        == "Ada (GitHub) <1+ada@users.noreply.github.com>")
    #expect(
      mac.vaults.suggestedProfile(for: .personal, gitHub: (nil, " "), git: GitGlobalIdentity(name: "Ada")).email.isEmpty)

    // An organization's account starts from Personal's, email included, for the user to change.
    mac.vaults.save(VaultProfile(account: "personal", name: "Ada Lovelace", email: "ada@example.com"))
    #expect(mac.vaults.suggestedProfile(for: acme, git: git).signature == "Ada Lovelace <ada@example.com>")

    // What the account has stays.
    mac.vaults.save(VaultProfile(account: acme.id, email: "ada@acme.example"))
    #expect(mac.vaults.suggestedProfile(for: acme, git: git).signature == "Ada Lovelace <ada@acme.example>")
  }

  @Test func readsGitsGlobalConfiguration() throws {
    let home = temporaryDirectory()
    let xdg = home.appendingPathComponent("xdg")
    try FileManager.default.createDirectory(at: xdg.appendingPathComponent("git"), withIntermediateDirectories: true)
    try """
      [user]
        name = From XDG
        email = xdg@example.com
      """.write(to: xdg.appendingPathComponent("git/config"), atomically: true, encoding: .utf8)
    #expect(
      GitGlobalIdentity.read(home: home, environment: ["XDG_CONFIG_HOME": xdg.path])
        == GitGlobalIdentity(name: "From XDG", email: "xdg@example.com"))
    #expect(GitGlobalIdentity.read(home: home, environment: [:]) == GitGlobalIdentity())

    // ~/.gitconfig wins, field by field.
    try "[User]\n\tName = \"Ada \\\"the Countess\\\" Lovelace\" ; a comment\n"
      .write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
    #expect(
      GitGlobalIdentity.read(home: home, environment: ["XDG_CONFIG_HOME": xdg.path])
        == GitGlobalIdentity(name: "Ada \"the Countess\" Lovelace", email: "xdg@example.com"))
  }

  @Test func parsesOnlyTheUserSection() {
    let config = """
      # name = Not This
      [core]
        name = Not This Either
      [user]
        email = first@example.com
      [userx]
        name = Nor This
      [ user ]
        email = "second@example.com" # later wins
        name =
        signingkey = ABC
      [include]
        path = ~/.gitconfig.local
      """
    #expect(GitGlobalIdentity.parse(config) == GitGlobalIdentity(name: nil, email: "second@example.com"))
  }

  @Test func oldBuildsKeepFieldsTheyDontKnow() throws {
    let mac = try device("mac")
    try mac.personal.save(id: "profile.personal", kind: VaultProfile.kind, changes: ["name": .string("Ada"), "pronouns": .string("she")])
    mac.vaults.save(VaultProfile(account: "personal", name: "Ada", email: "ada@example.com"))
    #expect(try mac.personal.item(id: "profile.personal")?.values["pronouns"] == .string("she"))
  }
}
