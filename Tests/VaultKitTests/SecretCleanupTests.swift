import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Finding X1 of the second review: what any app can write can't choose which secrets Vault deletes. Every app holds the
/// vault key, so a record says nothing: Vault goes by a list of its own, in the group only it can write.
struct SecretCleanupTests {
  let keys = MemoryKeyProvider()
  let directory = temporaryDirectory()
  let shared = MemorySecretBacking()
  let vaultOnly = MemorySecretBacking()

  private func personal() throws -> VaultStore {
    let store = try openStore(directory, keys: keys)
    store.fetchCompleted()
    return store
  }

  private func account(_ id: String, in personal: VaultStore) throws -> VaultStore {
    try personal.save(VaultAccount(id: id, name: id))
    let store = try openStore(directory, keys: keys, fileName: VaultAccountStores.fileName(forAccount: id), account: id)
    store.fetchCompleted()
    return store
  }

  private func run(_ stores: [VaultStore]) {
    VaultSecretMove(
      secrets: VaultSecretTiers(shared: shared, vaultOnly: vaultOnly),
      identity: VaultSecretTiers(shared: MemorySecretBacking(), vaultOnly: MemorySecretBacking()) { _ in true }, stores: stores
    ).run()
  }

  private func secret(_ name: String) throws { try vaultOnly.write(Data(name.utf8), named: name, label: "") }

  private func forge(_ personal: VaultStore, account: String, items: [String]) throws {
    try personal.save(
      id: "secret-cleanup.\(account)", kind: "secretCleanup", changes: ["items": .string(items.joined(separator: "\n"))])
  }

  private func remove(_ account: String, from personal: VaultStore) throws {
    try personal.delete(id: account)
    VaultStore.removeFiles(at: directory.appendingPathComponent(VaultAccountStores.fileName(forAccount: account)))
  }

  @Test func aForgedRecordDeletesNothingAndGoes() throws {
    let personal = try personal()
    let acme = try account("acme", in: personal)
    let own = VaultLogin(title: "Mine")
    try personal.save(own)
    let theirs = VaultLogin(title: "Acme's")
    try acme.save(theirs)
    let names = [
      "login.\(own.id)", "otp.\(own.id)", "login.\(theirs.id)", "card.number.\(own.id)", "login.orphan", "passkey.orphan",
    ]
    for name in names { try secret(name) }

    // The account is alive, and the record names its logins, Personal's, and what no record holds.
    try forge(personal, account: "acme", items: [own.id, theirs.id, "orphan"])
    run([personal, acme])
    for name in names { #expect(try vaultOnly.read(name) != nil, "\(name)") }
    #expect(try personal.items(kind: "secretCleanup").isEmpty)
  }

  /// All an app with the key can do: make up an account, delete it, and name whatever it likes.
  @Test func aForgedTombstoneGivesAForgedRecordNothing() throws {
    let personal = try personal()
    let own = VaultLogin(title: "Mine")
    try personal.save(own)
    try secret("login.\(own.id)")
    try secret("login.orphan")
    try personal.save(VaultAccount(id: "ghost", name: "ghost"))
    try personal.delete(id: "ghost")
    try forge(personal, account: "ghost", items: [own.id, "orphan"])

    run([personal])
    #expect(try vaultOnly.read("login.\(own.id)") != nil)
    #expect(try vaultOnly.read("login.orphan") != nil)
  }

  /// Even with the row taken out of the file first, which an app in the group's container can do.
  @Test func aRowTakenOutOfTheFileDoesntMakeItsSecretAnAccounts() throws {
    let personal = try personal()
    let own = VaultLogin(title: "Mine")
    try personal.save(own)
    try secret("login.\(own.id)")
    let acme = try account("acme", in: personal)
    run([personal, acme])

    try personal.database.query("DELETE FROM items WHERE id = ?", [.text(own.id)])
    try remove("acme", from: personal)
    try forge(personal, account: "acme", items: [own.id])
    run([personal])
    #expect(try vaultOnly.read("login.\(own.id)") != nil)
  }

  /// A list planted in the group every app can write counts for nothing.
  @Test func aListInTheSharedGroupCountsForNothing() throws {
    let personal = try personal()
    try secret("login.victim")
    let acme = try account("acme", in: personal)
    try shared.write(Data("victim".utf8), named: "account-secrets.acme", label: "")
    try remove("acme", from: personal)
    run([personal])
    _ = acme
    #expect(try vaultOnly.read("login.victim") != nil)
    #expect(try vaultOnly.read("account-secrets.acme") == nil)
  }

  @Test func aRemovedAccountsSecretsGoEverywhereButTheOnesKept() throws {
    let personal = try personal()
    let acme = try account("acme", in: personal)
    let login = VaultLogin(title: "Acme's")
    try acme.save(login)
    try secret("login.\(login.id)")
    try secret("otp.\(login.id)")
    try secret("superseded.login.\(login.id)")
    try shared.write(Data("old copy".utf8), named: "card.code.\(login.id)", label: "")
    let other = VaultLogin(title: "Mine")
    try personal.save(other)
    try secret("login.\(other.id)")

    run([personal, acme])
    #expect(try vaultOnly.read("login.\(login.id)") != nil)
    #expect(try vaultOnly.read("account-secrets.acme") != nil)

    try remove("acme", from: personal)
    run([personal])
    #expect(try vaultOnly.read("login.\(login.id)") == nil)
    #expect(try vaultOnly.read("otp.\(login.id)") == nil)
    #expect(try vaultOnly.read("card.code.\(login.id)") == nil)
    #expect(try shared.read("card.code.\(login.id)") == nil)
    #expect(try vaultOnly.read("superseded.login.\(login.id)") != nil)
    #expect(try vaultOnly.read("login.\(other.id)") != nil)
    #expect(try vaultOnly.read("account-secrets.acme") == nil)
  }

  /// A login moved out of the account before it went stays with where it is now.
  @Test func aSecretAnotherStoreHoldsStays() throws {
    let personal = try personal()
    let acme = try account("acme", in: personal)
    let login = VaultLogin(title: "Moved")
    try acme.save(login)
    try secret("login.\(login.id)")
    run([personal, acme])

    try personal.save(login)
    try remove("acme", from: personal)
    run([personal])
    #expect(try vaultOnly.read("login.\(login.id)") != nil)
    #expect(try vaultOnly.read("account-secrets.acme") == nil)
  }

  /// Nothing is decided while a store hasn't seen what it should have: the row that says otherwise may be on its way.
  @Test func nothingGoesWhileAStoreIsStillInItsFirstFetch() throws {
    let unfinished = try openStore(temporaryDirectory(), keys: keys)
    let acmeDirectory = unfinished.directory
    try unfinished.save(VaultAccount(id: "acme", name: "acme"))
    let acme = try openStore(acmeDirectory, keys: keys, fileName: VaultAccountStores.fileName(forAccount: "acme"), account: "acme")
    let login = VaultLogin(title: "Acme's")
    try acme.save(login)
    try secret("login.\(login.id)")
    run([unfinished, acme])
    try unfinished.delete(id: "acme")

    run([unfinished])
    #expect(try vaultOnly.read("login.\(login.id)") != nil)
    #expect(try vaultOnly.read("account-secrets.acme") != nil)

    unfinished.fetchCompleted()
    run([unfinished])
    #expect(try vaultOnly.read("login.\(login.id)") == nil)
  }

  /// A live account whose store isn't among those given might hold the login: wait.
  @Test func aLiveAccountThatIsntOpenHoldsThingsUp() throws {
    let personal = try personal()
    let acme = try account("acme", in: personal)
    let beta = try account("beta", in: personal)
    let login = VaultLogin(title: "Acme's")
    try acme.save(login)
    try secret("login.\(login.id)")
    run([personal, acme, beta])
    try remove("acme", from: personal)

    run([personal])
    #expect(try vaultOnly.read("login.\(login.id)") != nil)
    run([personal, beta])
    #expect(try vaultOnly.read("login.\(login.id)") == nil)
  }

  @Test func theListIsntSealedToTheKit() {
    #expect(!VaultRecovery.isCovered(secret: "account-secrets.acme"))
  }
}
