import CryptoKit
import Foundation
import Testing

@testable import VaultKit

struct IdentityTests {
  init() { VaultSecrets.useInMemoryStore() }

  @Test func privateKeysRoundTrip() throws {
    let identity = PersonalIdentity()
    let copy = try PersonalIdentity(rawRepresentation: identity.rawRepresentation)
    #expect(copy.publicIdentity == identity.publicIdentity)
    #expect(throws: SharingError.invalidIdentity) { try PersonalIdentity(rawRepresentation: Data([1, 2, 3])) }
  }

  @Test func publicTextRoundTrips() throws {
    let identity = PersonalIdentity().publicIdentity
    let text = identity.text
    #expect(text.hasPrefix("v57id:"))
    #expect(text.count == 6 + 87)
    #expect(PublicIdentity(text) == identity)
    #expect(PublicIdentity("v57id:abc") == nil)
    #expect(PublicIdentity("hello") == nil)
    #expect(PublicIdentity(String(text.dropLast())) == nil)
  }

  @Test func fingerprints() throws {
    let identity = PersonalIdentity().publicIdentity
    #expect(identity.fingerprint.wholeMatch(of: /Ed25519 [0-9A-F]{4}…[0-9A-F]{4}/) != nil)
    #expect(identity.agreementFingerprint.wholeMatch(of: /X25519 [0-9A-F]{4}…[0-9A-F]{4}/) != nil)
    #expect(identity.fullFingerprint.split(separator: " ").count == 16)
    let hash = Data(SHA256.hash(data: identity.signingKey))
    #expect(identity.fullFingerprint.hasPrefix(String(format: "%02X%02X", hash[0], hash[1])))
  }

  @Test func signatures() throws {
    let identity = PersonalIdentity()
    let message = Data("members v3".utf8)
    let signature = try identity.signature(for: message)
    #expect(identity.publicIdentity.isValidSignature(signature, for: message))
    #expect(!identity.publicIdentity.isValidSignature(signature, for: Data("members v4".utf8)))
  }

  @Test func theUsersIdentityIsMadeOnceAndKeptInMemory() throws {
    #expect(VaultPersonalIdentity.backing is MemorySecretBacking)
    let first = try VaultPersonalIdentity.current()
    let second = try VaultPersonalIdentity.current()
    #expect(first.publicIdentity == second.publicIdentity)
    #expect(VaultPersonalIdentity.exists)
    #expect(try VaultPersonalIdentity.existing()?.publicIdentity == first.publicIdentity)
  }

  @Test func injectedBacking() throws {
    // A backing that already holds an identity (another app made it) is used as is.
    let identity = PersonalIdentity()
    let memory = MemorySecretBacking([VaultPersonalIdentity.account: identity.rawRepresentation])
    #expect(try memory.read(VaultPersonalIdentity.account) == identity.rawRepresentation)
  }
}

struct SafetyCodeTests {
  @Test func sameOnBothSides() {
    let alice = PersonalIdentity().publicIdentity
    let bob = PersonalIdentity().publicIdentity
    let code = SafetyCode.compute(alice, bob)
    #expect(code == SafetyCode.compute(bob, alice))
    #expect(code.count == 12)
    #expect(code.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) })
    #expect(SafetyCode.matches(code.joined(separator: " "), bob, alice))
    #expect(SafetyCode.text(alice, bob) == code.joined(separator: " "))
  }

  @Test func aSwappedKeyChangesTheCode() throws {
    let alice = PersonalIdentity().publicIdentity
    let bob = PersonalIdentity().publicIdentity
    let mallory = PersonalIdentity().publicIdentity
    #expect(SafetyCode.compute(alice, bob) != SafetyCode.compute(alice, mallory))
    // Only the agreement key swapped.
    let swapped = try PublicIdentity(signingKey: bob.signingKey, agreementKey: mallory.agreementKey)
    #expect(SafetyCode.compute(alice, bob) != SafetyCode.compute(alice, swapped))
    // Each half is the side's own 30 digits.
    let halves = [SafetyCode.digits(for: alice), SafetyCode.digits(for: bob)].sorted()
    #expect(SafetyCode.compute(alice, bob).joined() == halves.joined())
  }

  @Test func fixedKeysGiveAFixedCode() throws {
    let a = try PublicIdentity(
      signingKey: Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).publicKey.rawRepresentation,
      agreementKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32)).publicKey
        .rawRepresentation)
    let b = try PublicIdentity(
      signingKey: Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32)).publicKey.rawRepresentation,
      agreementKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32)).publicKey
        .rawRepresentation)
    // Stable across runs and devices.
    #expect(SafetyCode.compute(a, b) == SafetyCode.compute(a, b))
    #expect(SafetyCode.digits(for: a) == SafetyCode.digits(for: a))
    #expect(SafetyCode.digits(for: a) != SafetyCode.digits(for: b))
  }
}

struct KeyWrapTests {
  @Test func sealsAKeyForOnePerson() throws {
    let bob = PersonalIdentity()
    let folderKey = SymmetricKey(size: .bits256)
    let context = Data("folder-1".utf8)
    let sealed = try KeyWrap.seal(folderKey, to: bob.publicIdentity, context: context)
    #expect(sealed.count == 1 + 32 + 12 + 32 + 16)
    let opened = try KeyWrap.openKey(sealed, with: bob, context: context)
    #expect(opened == folderKey)
    // Sealing twice gives different bytes (a fresh ephemeral key each time).
    #expect(try KeyWrap.seal(folderKey, to: bob.publicIdentity, context: context) != sealed)
  }

  @Test func othersCantOpenIt() throws {
    let bob = PersonalIdentity()
    let eve = PersonalIdentity()
    let sealed = try KeyWrap.seal(Data("secret".utf8), to: bob.publicIdentity, context: Data("a".utf8))
    #expect(throws: SharingError.cannotOpen) { try KeyWrap.open(sealed, with: eve, context: Data("a".utf8)) }
    #expect(throws: SharingError.cannotOpen) { try KeyWrap.open(sealed, with: bob, context: Data("b".utf8)) }
    var tampered = sealed
    tampered[tampered.count - 1] ^= 1
    #expect(throws: SharingError.cannotOpen) { try KeyWrap.open(tampered, with: bob, context: Data("a".utf8)) }
    #expect(throws: SharingError.cannotOpen) { try KeyWrap.open(Data([1, 2]), with: bob) }
    #expect(try KeyWrap.open(sealed, with: bob, context: Data("a".utf8)) == Data("secret".utf8))
  }
}

struct PersonTests {
  let keys = MemoryKeyProvider()

  func store() throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
  }

  @Test func recordRoundTrip() throws {
    let store = try store()
    let identity = PersonalIdentity().publicIdentity
    let person = VaultPerson(name: "Bob", identity: identity, roles: ["f1": .readWrite, "f2": .readOnly])
    #expect(person.status == .waiting)
    #expect(VaultPerson(name: "Carol").status == .invited)
    try store.save(person)
    let read = try #require(try store.record(VaultPerson.self, id: person.id))
    #expect(read == person)
    #expect(read.identity == identity)
    #expect(read.role(in: "f2") == .readOnly)
    #expect(try store.item(id: person.id)?.values["role.f1"] == "readWrite")
  }

  @Test func rolesMergeAndClear() throws {
    let store = try store()
    var person = VaultPerson(name: "Bob", roles: ["f1": .readWrite])
    try store.save(person)
    person.roles = ["f2": .readOnly]
    try store.save(person)
    #expect(try store.record(VaultPerson.self, id: person.id)?.roles == ["f2": .readOnly])
  }

  @Test func addingAndVerifying() throws {
    let store = try store()
    let invited = VaultPerson(name: "Bob")
    try store.save(invited)
    let identity = PersonalIdentity().publicIdentity
    let added = try store.addPerson(identity, name: "Robert", personID: invited.id)
    #expect(added.id == invited.id)
    #expect(added.name == "Bob")
    #expect(added.status == .waiting)
    // The same keys again find the same person.
    #expect(try store.addPerson(identity, name: "Other").id == invited.id)
    #expect(try store.person(signingKey: identity.signingKey)?.id == invited.id)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try store.markVerified(personID: invited.id, now: now)
    let verified = try #require(try store.record(VaultPerson.self, id: invited.id))
    #expect(verified.status == .verified)
    #expect(verified.verified == now)
  }

  @MainActor @Test func theVaultListsPeople() throws {
    let store = try store()
    try store.save(VaultPerson(name: "zoe"))
    try store.save(VaultPerson(name: "Adam"))
    #expect(Vault(store: store).people.map(\.name) == ["Adam", "zoe"])
  }
}

struct InviteTests {
  @Test func roundTripsThroughALink() throws {
    let alice = PersonalIdentity()
    let invite = try VaultInvite.make(
      from: alice, name: "Alice & Co+", folderID: "folder-1", folderName: "Design / Specs", role: .readOnly,
      created: Date(timeIntervalSince1970: 1_800_000_000.7))
    #expect(invite.isSignatureValid)
    let url = invite.url
    #expect(url.hasPrefix("v57vault://invite?"))
    let read = try #require(VaultInvite(url: url))
    #expect(read == invite)
    #expect(read.identity == alice.publicIdentity)
    #expect(read.name == "Alice & Co+")
    #expect(read.folderName == "Design / Specs")
    #expect(read.role == .readOnly)
    #expect(read.created == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(url.count < 400)
  }

  @Test func withoutAFolder() throws {
    let invite = try VaultInvite.make(from: PersonalIdentity(), name: "Alice")
    let read = try #require(VaultInvite(url: invite.url))
    #expect(read.folderID == nil && read.role == nil)
  }

  @Test func aChangedInviteIsRejected() throws {
    let invite = try VaultInvite.make(from: PersonalIdentity(), name: "Alice", folderID: "f", role: .readOnly)
    let url = invite.url
    #expect(VaultInvite(url: url.replacingOccurrences(of: "name=Alice", with: "name=Mallory")) == nil)
    #expect(VaultInvite(url: url.replacingOccurrences(of: "role=readOnly", with: "role=readWrite")) == nil)
    #expect(VaultInvite(url: "v57vault://invite?name=x") == nil)
    #expect(VaultInvite(url: "https://example.com") == nil)
  }
}
