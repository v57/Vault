import CryptoKit
import Foundation
import Testing

@testable import VaultKit

struct LoginTests {
  let keys = MemoryKeyProvider()

  init() { VaultSecrets.useInMemoryStore() }

  func store(device: String = "mac") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  @Test func savesAndReadsALogin() throws {
    let store = try store()
    let login = VaultLogin(
      title: "GitHub", website: "https://www.github.com/login", username: "octocat", notes: "work",
      favorite: true, order: 2, links: ["host-1", "project-2"])
    try store.save(login)
    let read = try #require(try store.record(VaultLogin.self, id: login.id))
    #expect(read == login)
    #expect(read.domain == "github.com")
    #expect(VaultLogin(website: "example.org").displayName == "example.org")
  }

  @Test func removedLinksAreCleared() throws {
    let store = try store()
    var login = VaultLogin(title: "Server", links: ["a", "b"])
    try store.save(login)
    login.links = ["b", "c"]
    try store.save(login)
    let item = try #require(try store.item(id: login.id))
    #expect(item.values["link.a"] == .null)
    #expect(try store.record(VaultLogin.self, id: login.id)?.links == ["b", "c"])
  }

  @Test func unknownFieldsSurvive() throws {
    let store = try store()
    let login = VaultLogin(title: "Mail")
    try store.save(login)
    try store.save(id: login.id, kind: VaultLogin.kind, changes: ["passkey": "future"])
    var copy = try #require(try store.record(VaultLogin.self, id: login.id))
    copy.title = "Mail (work)"
    try store.save(copy)
    #expect(try store.item(id: login.id)?.values["passkey"] == "future")
  }

  @Test func passwordChangesAreDated() throws {
    let store = try store()
    let login = VaultLogin(title: "Bank")
    try store.save(login)
    let first = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(try store.setPassword("one", forLogin: login.id, now: first))
    #expect(try !store.setPassword("one", forLogin: login.id, now: .now))
    var read = try #require(try store.record(VaultLogin.self, id: login.id))
    #expect(read.password == "one")
    #expect(read.passwordChanged == first)

    // A copy loaded before the change can't set the date back.
    let stale = read
    let second = Date(timeIntervalSince1970: 1_700_000_100)
    try store.setPassword("two", forLogin: login.id, now: second)
    var edited = stale
    edited.notes = "changed"
    try store.save(edited)
    read = try #require(try store.record(VaultLogin.self, id: login.id))
    #expect(read.passwordChanged == second)
    #expect(read.password == "two")
    #expect(read.notes == "changed")

    try store.setPassword(nil, forLogin: login.id)
    #expect(VaultSecrets.password(for: login.id) == nil)
  }

  @Test func oneTimeCodes() throws {
    let store = try store()
    let login = VaultLogin(title: "Cloud")
    try store.save(login)
    #expect(try store.record(VaultLogin.self, id: login.id)?.hasOneTimeCode == false)
    try store.setOneTimeCode("otpauth://totp/Cloud:me?secret=JBSWY3DPEHPK3PXP&issuer=Cloud", forLogin: login.id)
    var read = try #require(try store.record(VaultLogin.self, id: login.id))
    #expect(read.hasOneTimeCode)
    #expect(read.otpChanged != nil)
    #expect(read.oneTimeCode?.secret == Base32.decode("JBSWY3DPEHPK3PXP"))
    #expect(read.oneTimeCode?.issuer == "Cloud")
    #expect(VaultSecrets.secretText("otp.\(login.id)")?.hasPrefix("otpauth://totp/") == true)

    #expect(throws: VaultStore.PasswordItemError.self) {
      try store.setOneTimeCode("not a key!", forLogin: login.id)
    }
    try store.setOneTimeCode(String?.none, forLogin: login.id)
    read = try #require(try store.record(VaultLogin.self, id: login.id))
    #expect(!read.hasOneTimeCode)
    #expect(read.oneTimeCode == nil)
  }

  @Test func deletingALoginDeletesItsSecrets() throws {
    let store = try store()
    let login = VaultLogin(title: "Old")
    try store.save(login)
    try store.setPassword("secret", forLogin: login.id)
    try store.setOneTimeCode("JBSWY3DPEHPK3PXP", forLogin: login.id)
    try store.deleteLogin(id: login.id)
    #expect(try store.record(VaultLogin.self, id: login.id) == nil)
    #expect(VaultSecrets.password(for: login.id) == nil)
    #expect(VaultSecrets.secret(VaultLogin.oneTimeCodeSecret(login.id)) == nil)
  }

  @Test func cards() throws {
    let store = try store()
    let card = VaultCard(title: "Travel", holder: "Alice", expiry: "08/29")
    try store.save(card)
    try store.setCardNumber("4111 1111 1111 1234", forCard: card.id)
    try store.setCardCode("123", forCard: card.id)
    let read = try #require(try store.record(VaultCard.self, id: card.id))
    #expect(read.last4 == "1234")
    #expect(read.brand == "visa")
    #expect(read.number == "4111111111111234")
    #expect(read.securityCode == "123")
    #expect(VaultCard.brand(forNumber: "3782 822463 10005") == "amex")
    #expect(VaultCard.brand(forNumber: "5555555555554444") == "mastercard")
    #expect(VaultCard.brand(forNumber: "2223000048400011") == "mastercard")
    #expect(VaultCard.brand(forNumber: "6011111111111117") == "discover")
    #expect(VaultCard.brand(forNumber: "9999") == nil)
    try store.deleteCard(id: card.id)
    #expect(VaultSecrets.secret(VaultCard.numberSecret(card.id)) == nil)
  }

  @MainActor @Test func theVaultListsLoginsByTitle() throws {
    let store = try store()
    try store.save(VaultLogin(title: "zeta"))
    try store.save(VaultLogin(title: "Alpha"))
    try store.save(VaultLogin(website: "mail.example.com"))
    try store.trust(fingerprint: "SHA256:abc", host: "example.com", port: 22)
    let vault = Vault(store: store)
    #expect(vault.logins.map(\.displayName) == ["Alpha", "mail.example.com", "zeta"])
    #expect(vault.knownHosts.map(\.host) == ["example.com"])
  }
}
