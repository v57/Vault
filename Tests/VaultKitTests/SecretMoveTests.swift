import Foundation
import Testing

@testable import VaultKit

/// Vault and AutoFill alone hold logins' passwords, codes, cards and passkeys (Ideas/Security V3). None of this touches a
/// keychain: the two groups are memory here, and a fault stands in for a kill.
struct SecretMoveTests {
  let keys = MemoryKeyProvider()

  /// A backing that fails or forgets on request, for what a kill or a broken keychain would leave.
  final class Faulty: VaultSecretBacking, @unchecked Sendable {
    let inner = MemorySecretBacking()
    var failsDelete = false
    var forgetsWrites = false

    func read(_ name: String) throws -> Data? { try inner.read(name) }
    func write(_ data: Data, named name: String, label: String) throws {
      if !forgetsWrites { try inner.write(data, named: name, label: label) }
    }
    func addNew(_ data: Data, named name: String, label: String) throws -> Bool {
      if forgetsWrites { return true }
      return try inner.addNew(data, named: name, label: label)
    }
    func delete(_ name: String) throws {
      if failsDelete { throw CocoaError(.fileWriteUnknown) }
      try inner.delete(name)
    }
    func all() throws -> [(name: String, data: Data)] { try inner.all() }
    func modified(_ name: String) throws -> Date? { try inner.modified(name) }
  }

  private func store() throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
  }

  private func move(
    shared: any VaultSecretBacking, vaultOnly: any VaultSecretBacking, stores: [VaultStore],
    identityShared: any VaultSecretBacking = MemorySecretBacking(), identityVaultOnly: any VaultSecretBacking = MemorySecretBacking()
  ) -> VaultSecretMove {
    VaultSecretMove(
      secrets: VaultSecretTiers(shared: shared, vaultOnly: vaultOnly),
      identity: VaultSecretTiers(shared: identityShared, vaultOnly: identityVaultOnly) { _ in true }, stores: stores)
  }

  private func data(_ text: String) -> Data { Data(text.utf8) }

  @Test func whatOnlyVaultReadsMovesAndWhatAppsLogInWithStays() throws {
    let store = try store()
    let login = VaultLogin(title: "Mail", website: "mail.example.com", username: "me")
    try store.save(login)
    let host = VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy", auth: .password)
    try store.save(host)
    let shared = MemorySecretBacking([
      "password.\(login.id)": data("login password"), "otp.\(login.id)": data("otp"), "card.number.c": data("4242"),
      "card.code.c": data("123"), "passkey.p": data("key"), "recovery.digest": data("digest"),
      "password.\(host.id)": data("host password"), "database.sshkey.1": data("imported key"),
    ])
    let vaultOnly = MemorySecretBacking()

    let report = move(shared: shared, vaultOnly: vaultOnly, stores: [store]).run()

    #expect(report == .init(moved: 6))
    #expect(Set(shared.names) == ["password.\(host.id)", "database.sshkey.1"])
    #expect(try vaultOnly.read("login.\(login.id)") == data("login password"))
    for name in ["otp.\(login.id)", "card.number.c", "card.code.c", "passkey.p", "recovery.digest"] {
      #expect(try vaultOnly.read(name) != nil, "\(name)")
    }
    // Nothing to do the second time.
    #expect(move(shared: shared, vaultOnly: vaultOnly, stores: [store]).run() == .init())
  }

  @Test func aPasswordWhoseRecordHasntArrivedStaysUntilItHas() throws {
    let store = try store()
    let login = VaultLogin(title: "Mail")
    let shared = MemorySecretBacking(["password.\(login.id)": data("secret")])
    let vaultOnly = MemorySecretBacking()
    let mover = move(shared: shared, vaultOnly: vaultOnly, stores: [store])

    var report = mover.run()
    #expect(report.waiting == 1)
    #expect(!report.isComplete)
    #expect(try shared.read("password.\(login.id)") == data("secret"))

    try store.save(login)
    report = mover.run()
    #expect(report.isComplete)
    #expect(report.moved == 1)
    #expect(shared.names.isEmpty)
  }

  @Test func aDeletedLoginsPasswordStillMoves() throws {
    let store = try store()
    let login = VaultLogin(title: "Mail")
    try store.save(login)
    try store.delete(id: login.id)
    let shared = MemorySecretBacking(["password.\(login.id)": data("secret")])
    let vaultOnly = MemorySecretBacking()
    #expect(move(shared: shared, vaultOnly: vaultOnly, stores: [store]).run().moved == 1)
    #expect(try vaultOnly.read("login.\(login.id)") == data("secret"))
  }

  @Test func theOldCopyStaysUntilTheNewOneReadsBack() throws {
    let shared = Faulty()
    try shared.inner.write(data("code"), named: "otp.a", label: "")
    let vaultOnly = Faulty()
    vaultOnly.forgetsWrites = true
    let mover = move(shared: shared, vaultOnly: vaultOnly, stores: [])

    #expect(mover.run().failed == ["otp.a"])
    #expect(try shared.read("otp.a") == data("code"))

    vaultOnly.forgetsWrites = false
    #expect(mover.run() == .init(moved: 1))
    #expect(try shared.read("otp.a") == nil)
    #expect(try vaultOnly.read("otp.a") == data("code"))
  }

  @Test func killedBetweenTheCopyAndTheDeleteItFinishesNextTime() throws {
    let shared = Faulty()
    try shared.inner.write(data("code"), named: "otp.a", label: "")
    shared.failsDelete = true
    let vaultOnly = MemorySecretBacking()
    let mover = move(shared: shared, vaultOnly: vaultOnly, stores: [])

    #expect(mover.run().failed == ["otp.a"])
    #expect(try vaultOnly.read("otp.a") == data("code"))
    #expect(try shared.read("otp.a") == data("code"))

    shared.failsDelete = false
    #expect(mover.run() == .init(moved: 1))
    #expect(try shared.read("otp.a") == nil)
    #expect(try vaultOnly.read("otp.a") == data("code"))
    #expect(try vaultOnly.read("superseded.otp.a") == nil)
  }

  @Test func aLaterEditFromAnOldBuildWinsAndNothingIsLost() throws {
    let shared = MemorySecretBacking(["otp.a": data("edited on the old build")])
    let vaultOnly = MemorySecretBacking(["otp.a": data("moved earlier")])
    shared.setModified(Date(timeIntervalSince1970: 2000), of: "otp.a")
    vaultOnly.setModified(Date(timeIntervalSince1970: 1000), of: "otp.a")

    let report = move(shared: shared, vaultOnly: vaultOnly, stores: []).run()

    #expect(report == .init(moved: 1, conflicts: 1))
    #expect(try vaultOnly.read("otp.a") == data("edited on the old build"))
    #expect(try vaultOnly.read("superseded.otp.a") == data("moved earlier"))
    #expect(shared.names.isEmpty)
  }

  @Test func anOlderCopyArrivingLateDoesntReplaceTheSecret() throws {
    let shared = MemorySecretBacking(["otp.a": data("stale")])
    let vaultOnly = MemorySecretBacking(["otp.a": data("current")])
    shared.setModified(Date(timeIntervalSince1970: 1000), of: "otp.a")
    vaultOnly.setModified(Date(timeIntervalSince1970: 2000), of: "otp.a")

    move(shared: shared, vaultOnly: vaultOnly, stores: []).run()

    #expect(try vaultOnly.read("otp.a") == data("current"))
    #expect(try vaultOnly.read("superseded.otp.a") == data("stale"))
    #expect(shared.names.isEmpty)
  }

  @Test func theSameValueComingBackIsJustRemoved() throws {
    let shared = MemorySecretBacking(["otp.a": data("same")])
    let vaultOnly = MemorySecretBacking(["otp.a": data("same")])
    #expect(move(shared: shared, vaultOnly: vaultOnly, stores: []).run() == .init(moved: 1))
    #expect(shared.names.isEmpty)
    #expect(try vaultOnly.read("superseded.otp.a") == nil)
  }

  @Test func theIdentityMovesAndAnotherNeverReplacesIt() throws {
    let account = VaultPersonalIdentity.account
    let shared = MemorySecretBacking([account: data("first")])
    let vaultOnly = MemorySecretBacking()
    let mover = move(shared: MemorySecretBacking(), vaultOnly: MemorySecretBacking(), stores: [], identityShared: shared, identityVaultOnly: vaultOnly)

    #expect(mover.run().moved == 1)
    #expect(try vaultOnly.read(account) == data("first"))
    #expect(shared.names.isEmpty)

    // An old build made another after the first left its sight, however recently.
    try shared.write(data("second"), named: account, label: "")
    shared.setModified(.distantFuture, of: account)
    mover.run()
    #expect(try vaultOnly.read(account) == data("first"))
    #expect(try vaultOnly.read("superseded.\(account)") == data("second"))
    #expect(shared.names.isEmpty)
  }

  @Test func anAppOutsideTheGroupSeesNothingAndBreaksNothing() throws {
    let shared = MemorySecretBacking(["otp.a": data("not moved yet"), "password.h": data("host")])
    let vaultOnly = MemorySecretBacking(["login.l": data("login"), "card.number.c": data("4242")])
    let inside = VaultSecretTiers(shared: shared, vaultOnly: vaultOnly)
    let outside = VaultSecretTiers(shared: shared, vaultOnly: nil)

    #expect(!outside.seesEverySecret)
    #expect(inside.seesEverySecret)
    #expect(try outside.read("login.l") == nil)
    #expect(try outside.read("card.number.c") == nil)
    // Not through this, even while a copy is still in the shared group.
    #expect(try outside.read("otp.a") == nil)
    #expect(try inside.read("otp.a") == data("not moved yet"))
    #expect(try outside.read("password.h") == data("host"))
    #expect(try outside.all().map(\.name) == ["password.h"])
    #expect(throws: VaultSecretTiers.TierError.self) { try outside.write(data("x"), named: "otp.b", label: "") }
    #expect(throws: VaultSecretTiers.TierError.self) { _ = try outside.addNew(data("x"), named: "otp.b", label: "") }
    // A delete it can't carry out neither fails nor touches the secret.
    try outside.delete("login.l")
    #expect(try vaultOnly.read("login.l") == data("login"))
    // Connection passwords go on working both ways.
    try outside.write(data("new"), named: "password.h", label: "")
    #expect(try inside.read("password.h") == data("new"))
    #expect(Set(try inside.all().map(\.name)) == ["otp.a", "password.h", "login.l", "card.number.c"])
  }

  @Test func writingInVaultRemovesACopyLeftInTheSharedGroup() throws {
    let shared = MemorySecretBacking(["otp.a": data("old")])
    let vaultOnly = MemorySecretBacking()
    let tiers = VaultSecretTiers(shared: shared, vaultOnly: vaultOnly)
    try tiers.write(data("new"), named: "otp.a", label: "")
    #expect(shared.names.isEmpty)
    #expect(try tiers.read("otp.a") == data("new"))
    #expect(try !tiers.addNew(data("x"), named: "otp.a", label: ""))
  }

  @Test func recoverySeesEverySecretAfterTheMoveAndLeavesNoOldBox() async throws {
    let store = try store()
    let login = VaultLogin(title: "Mail")
    try store.save(login)
    let shared = MemorySecretBacking(["password.\(login.id)": data("before"), "otp.\(login.id)": data("code"), "password.h": data("host")])
    let vaultOnly = MemorySecretBacking()
    let tiers = VaultSecretTiers(shared: shared, vaultOnly: vaultOnly)
    let identity = MemorySecretBacking()
    let recovery = VaultRecovery(store: store, identity: identity, secrets: tiers)
    let kit = try recovery.create()
    let sealedBefore = try recovery.blobs().filter { $0.content == .secret }.map(\.keyID)
    #expect(Set(sealedBefore) == ["password.\(login.id)", "otp.\(login.id)", "password.h"])

    move(shared: shared, vaultOnly: vaultOnly, stores: [store]).run()
    try recovery.wrapMissing()

    let sealedAfter = try recovery.blobs().filter { $0.content == .secret }.map(\.keyID)
    #expect(Set(sealedAfter) == ["login.\(login.id)", "otp.\(login.id)", "password.h"])

    // And the kit gives them all back, each to where it belongs.
    let opened = try await recovery.recover(kit.qrText)
    let emptyShared = MemorySecretBacking()
    let emptyVaultOnly = MemorySecretBacking()
    let newDevice = VaultRecovery(
      store: store, identity: MemorySecretBacking(),
      secrets: VaultSecretTiers(shared: emptyShared, vaultOnly: emptyVaultOnly))
    _ = try newDevice.restore(opened)
    #expect(try emptyVaultOnly.read("login.\(login.id)") == data("before"))
    #expect(try emptyVaultOnly.read("otp.\(login.id)") == data("code"))
    #expect(try emptyShared.read("password.h") == data("host"))
  }

  @Test func recoveryOutsideTheGroupNeitherScrubsNorNeedsTheDigestsKey() throws {
    let store = try store()
    let shared = MemorySecretBacking(["password.h": data("host")])
    let vaultOnly = MemorySecretBacking(["login.l": data("login")])
    let inside = VaultRecovery(store: store, identity: MemorySecretBacking(), secrets: VaultSecretTiers(shared: shared, vaultOnly: vaultOnly))
    _ = try inside.create()
    #expect(try store.records(VaultRecoveryBlob.self).contains { $0.keyID == "login.l" })

    let outside = VaultRecovery(store: store, identity: MemorySecretBacking(), secrets: VaultSecretTiers(shared: shared, vaultOnly: nil))
    // Seeing fewer secrets isn't their being gone.
    try outside.wrapMissing()
    #expect(try store.records(VaultRecoveryBlob.self).contains { $0.keyID == "login.l" })

    // A connection password it changes is sealed anyway, without a digest; Vault adds that next time it looks.
    try shared.write(data("changed"), named: "password.h", label: "")
    try outside.secretChanged("password.h", value: data("changed"))
    let blob = try #require(try store.records(VaultRecoveryBlob.self).first { $0.keyID == "password.h" })
    #expect(blob.digest == nil)
    #expect(try inside.wrapMissing() == 1)
    #expect(try store.records(VaultRecoveryBlob.self).first { $0.keyID == "password.h" }?.digest != nil)
    #expect(try inside.wrapMissing() == 0)
  }

  @Test func vaultFinishesTheCleanupAnotherAppCouldntDo() throws {
    let store = try store()
    let shared = MemorySecretBacking(["password.h": data("host")])
    let vaultOnly = MemorySecretBacking(["login.gone": data("x"), "otp.gone": data("y"), "login.kept": data("z")])
    try store.save(VaultSecretCleanup(id: VaultSecretCleanup.recordID(account: "acme"), items: ["gone"]))

    move(shared: shared, vaultOnly: vaultOnly, stores: [store]).run()

    #expect(Set(vaultOnly.names) == ["login.kept"])
    #expect(try store.records(VaultSecretCleanup.self).isEmpty)
    #expect(try shared.read("password.h") == data("host"))
  }

  @Test func namesDecideTheTier() {
    for name in ["login.a", "otp.a", "card.number.a", "card.code.a", "passkey.a", "recovery.digest", "superseded.login.a"] {
      #expect(VaultSecretTiers.isVaultOnly(name), "\(name)")
    }
    for name in ["password.a", "database.sshkey.1", "token.x"] { #expect(!VaultSecretTiers.isVaultOnly(name), "\(name)") }
  }
}
