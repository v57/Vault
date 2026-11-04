import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Finding U5 of the second review: two values under one name.
struct SecretConflictTests {
  let shared = MemorySecretBacking()
  let vaultOnly = MemorySecretBacking()

  private func run() -> VaultSecretMove.Report {
    VaultSecretMove(
      secrets: VaultSecretTiers(shared: shared, vaultOnly: vaultOnly),
      identity: VaultSecretTiers(shared: MemorySecretBacking(), vaultOnly: MemorySecretBacking()) { _ in true }, stores: []
    ).run()
  }

  private func data(_ text: String) -> Data { Data(text.utf8) }

  private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

  /// An old build edits again, and again: every value it lost stays.
  @Test func everyConflictKeepsItsValue() throws {
    try vaultOnly.write(data("current"), named: "otp.a", label: "")
    vaultOnly.setModified(date(1000), of: "otp.a")
    for (index, text) in ["one", "two", "three"].enumerated() {
      try shared.write(data(text), named: "otp.a", label: "")
      shared.setModified(date(Double(index)), of: "otp.a")
      #expect(run().conflicts == 1)
    }
    #expect(try vaultOnly.read("otp.a") == data("current"))
    let kept = try vaultOnly.all().filter { $0.name.hasPrefix("superseded.") }.map(\.data)
    #expect(Set(kept) == [data("one"), data("two"), data("three")])
    #expect(shared.names.isEmpty)
  }

  @Test func theSameLoserIsKeptOnce() throws {
    try vaultOnly.write(data("current"), named: "otp.a", label: "")
    vaultOnly.setModified(date(1000), of: "otp.a")
    for _ in 0..<3 {
      try shared.write(data("stale"), named: "otp.a", label: "")
      shared.setModified(date(1), of: "otp.a")
      _ = run()
      #expect(shared.names.isEmpty)
    }
    #expect(try vaultOnly.all().filter { $0.name.hasPrefix("superseded.") }.count == 1)
  }

  /// Bounded: past the limit the old copy stays where it is, rather than anything being thrown away.
  @Test func pastTheLimitTheCopyStaysAndNothingIsDeleted() throws {
    try vaultOnly.write(data("current"), named: "otp.a", label: "")
    vaultOnly.setModified(date(1000), of: "otp.a")
    for index in 0..<VaultSecretMove.supersededLimit {
      try shared.write(data("v\(index)"), named: "otp.a", label: "")
      shared.setModified(date(1), of: "otp.a")
      #expect(run().failed.isEmpty)
    }
    try shared.write(data("one too many"), named: "otp.a", label: "")
    shared.setModified(date(1), of: "otp.a")
    #expect(run().failed == ["otp.a"])
    #expect(try shared.read("otp.a") == data("one too many"))
    let kept = try vaultOnly.all().filter { $0.name.hasPrefix("superseded.") }
    #expect(kept.count == VaultSecretMove.supersededLimit)
  }

  /// The move's copy is dated when it was copied: an edit from before another device's move is later than the value that
  /// moved, though not later than the copy.
  @Test func aCopyCountsFromTheSourcesDate() throws {
    try shared.write(data("before"), named: "otp.a", label: "")
    shared.setModified(date(1000), of: "otp.a")
    #expect(run().moved == 1)
    // The keychain dates the new item now.
    vaultOnly.setModified(date(3000), of: "otp.a")

    try shared.write(data("edit made at 2000, arriving late"), named: "otp.a", label: "")
    shared.setModified(date(2000), of: "otp.a")
    #expect(run().conflicts == 1)
    #expect(try vaultOnly.read("otp.a") == data("edit made at 2000, arriving late"))
    #expect(try vaultOnly.read("superseded.otp.a") == data("before"))
  }

  /// An edit here goes by its own date from then on.
  @Test func anEditInVaultCountsFromItsOwnDate() throws {
    try shared.write(data("before"), named: "otp.a", label: "")
    shared.setModified(date(1000), of: "otp.a")
    _ = run()
    let tiers = VaultSecretTiers(shared: shared, vaultOnly: vaultOnly)
    try tiers.write(data("edited in Vault"), named: "otp.a", label: "")
    vaultOnly.setModified(date(3000), of: "otp.a")

    try shared.write(data("older edit"), named: "otp.a", label: "")
    shared.setModified(date(2000), of: "otp.a")
    _ = run()
    #expect(try vaultOnly.read("otp.a") == data("edited in Vault"))
    #expect(try vaultOnly.read("superseded.otp.a") == data("older edit"))
  }

  // MARK: The identity

  private func identityTiers() -> (tiers: VaultSecretTiers, shared: MemorySecretBacking, vaultOnly: MemorySecretBacking) {
    let shared = MemorySecretBacking()
    let vaultOnly = MemorySecretBacking()
    return (VaultSecretTiers(shared: shared, vaultOnly: vaultOnly) { _ in true }, shared, vaultOnly)
  }

  private func moveIdentity(_ tiers: VaultSecretTiers) {
    VaultSecretMove(secrets: VaultSecretTiers(shared: shared, vaultOnly: vaultOnly), identity: tiers, stores: []).run()
  }

  /// Another device moved it: the shared delete has synced and the new item hasn't.
  @Test func aMoveInProgressElsewhereMintsNothing() throws {
    let (tiers, sharedGroup, secretsGroup) = identityTiers()
    let real = PersonalIdentity()
    try sharedGroup.write(real.rawRepresentation, named: VaultPersonalIdentity.account, label: "")
    moveIdentity(tiers)
    #expect(sharedGroup.names == [VaultSecretMove.identityMovedMark])
    #expect(try secretsGroup.read(VaultPersonalIdentity.account) == real.rawRepresentation)

    // Here the mark has synced from one group or the other, and the identity hasn't.
    try secretsGroup.delete(VaultPersonalIdentity.account)
    #expect(throws: SharingError.identityOnItsWay) { try VaultPersonalIdentity.current(in: tiers, existsElsewhere: nil) }
    try secretsGroup.delete(VaultSecretMove.identityMovedMark)
    #expect(throws: SharingError.identityOnItsWay) { try VaultPersonalIdentity.current(in: tiers, existsElsewhere: nil) }
    #expect(try secretsGroup.read(VaultPersonalIdentity.account) == nil)

    // Once it arrives it's what `current` returns.
    try secretsGroup.write(real.rawRepresentation, named: VaultPersonalIdentity.account, label: "")
    #expect(try VaultPersonalIdentity.current(in: tiers, existsElsewhere: nil).rawRepresentation == real.rawRepresentation)
  }

  @Test func aKeptValueOrARecoveryBoxIsASignToo() throws {
    let (tiers, _, secretsGroup) = identityTiers()
    #expect(throws: SharingError.identityOnItsWay) {
      try VaultPersonalIdentity.current(in: tiers, existsElsewhere: { true })
    }
    try secretsGroup.write(Data("old".utf8), named: "superseded.personal-identity", label: "")
    #expect(throws: SharingError.identityOnItsWay) { try VaultPersonalIdentity.current(in: tiers, existsElsewhere: nil) }
  }

  /// With no sign of one, the first one is made as it always was.
  @Test func withNoSignAnIdentityIsMade() throws {
    let (tiers, _, secretsGroup) = identityTiers()
    let made = try VaultPersonalIdentity.current(in: tiers, existsElsewhere: { false })
    #expect(try secretsGroup.read(VaultPersonalIdentity.account) == made.rawRepresentation)
  }

  /// What the secrets group has stays, and each identity an old build made in the meantime is kept beside it.
  @Test func aStandInNeverTakesTheRealOnesPlace() throws {
    let (tiers, sharedGroup, secretsGroup) = identityTiers()
    let real = PersonalIdentity()
    try secretsGroup.write(real.rawRepresentation, named: VaultPersonalIdentity.account, label: "")
    secretsGroup.setModified(Date(timeIntervalSince1970: 1), of: VaultPersonalIdentity.account)
    for _ in 0..<2 {
      try sharedGroup.write(PersonalIdentity().rawRepresentation, named: VaultPersonalIdentity.account, label: "")
      sharedGroup.setModified(Date(timeIntervalSince1970: 2), of: VaultPersonalIdentity.account)
      moveIdentity(tiers)
    }
    #expect(try secretsGroup.read(VaultPersonalIdentity.account) == real.rawRepresentation)
    #expect(secretsGroup.names.filter { $0.hasPrefix("superseded.") }.count == 2)
  }

  @Test func theDatesArentSealedOrMoved() throws {
    #expect(!VaultRecovery.isCovered(secret: "moved-date.otp.a"))
    try shared.write(data("a"), named: "otp.a", label: "")
    shared.setModified(date(1), of: "otp.a")
    _ = run()
    #expect(try vaultOnly.read("moved-date.otp.a") != nil)
    // Gone with its secret.
    try vaultOnly.delete("otp.a")
    _ = run()
    #expect(try vaultOnly.read("moved-date.otp.a") == nil)
  }
}
