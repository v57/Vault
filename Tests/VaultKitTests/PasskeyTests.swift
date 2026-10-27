import CryptoKit
import Foundation
import Testing

@testable import VaultKit

struct PasskeyTests {
  let keys = MemoryKeyProvider()

  init() { VaultSecrets.useInMemoryStore() }

  func store() throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
  }

  @Test func cborEncodesWhatWebAuthnNeeds() {
    #expect(CBOR.int(23).encoded == Data([0x17]))
    #expect(CBOR.int(24).encoded == Data([0x18, 0x18]))
    #expect(CBOR.int(1000).encoded == Data([0x19, 0x03, 0xe8]))
    #expect(CBOR.int(-7).encoded == Data([0x26]))
    #expect(CBOR.int(-1).encoded == Data([0x20]))
    #expect(CBOR.text("fmt").encoded == Data([0x63, 0x66, 0x6d, 0x74]))
    #expect(CBOR.bytes(Data(count: 32)).encoded.prefix(2) == Data([0x58, 0x20]))
    #expect(CBOR.map([]).encoded == Data([0xa0]))
  }

  @Test func registrationCarriesTheKey() throws {
    let key = P256.Signing.PrivateKey()
    let id = Data((0..<16).map { UInt8($0) })
    let data = WebAuthn.authenticatorData(relyingParty: "example.com", userVerified: true, credential: (id, key.publicKey))
    #expect(data.prefix(32) == Data(SHA256.hash(data: Data("example.com".utf8))))
    #expect(data[32] == 0x5d)  // UP, UV, BE, BS, AT
    #expect(data[33..<37] == Data(count: 4))
    #expect(data[37..<53] == Data(count: 16))
    #expect(data[53..<55] == Data([0, 16]))
    #expect(data[55..<71] == id)
    let cose = data[71...]
    // {1: 2, 3: -7, -1: 1, -2: x, -3: y}
    #expect(cose.prefix(10) == Data([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]))
    #expect(cose.dropFirst(10).prefix(32) == key.publicKey.rawRepresentation.prefix(32))
    #expect(cose.suffix(32) == key.publicKey.rawRepresentation.suffix(32))

    let object = WebAuthn.attestationObject(authenticatorData: data)
    let header = CBOR.map([(.text("fmt"), .text("none")), (.text("attStmt"), .map([]))]).encoded.dropFirst()
    #expect(object.first == 0xa3)
    #expect(object.dropFirst().prefix(header.count) == header)
    #expect(object.suffix(data.count) == data)
  }

  @Test func assertionVerifies() throws {
    let key = P256.Signing.PrivateKey()
    let hash = Data(SHA256.hash(data: Data("client data".utf8)))
    let (authenticatorData, signature) = try WebAuthn.assertion(
      relyingParty: "example.com", clientDataHash: hash, key: key, userVerified: false)
    #expect(authenticatorData.count == 37)
    #expect(authenticatorData[32] == 0x19)  // UP, BE, BS
    let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
    #expect(key.publicKey.isValidSignature(parsed, for: authenticatorData + hash))
  }

  @Test func passkeyJoinsTheMatchingLogin() throws {
    let store = try store()
    let github = VaultLogin(title: "GitHub", website: "https://github.com/login", username: "Octocat")
    let other = VaultLogin(title: "GitHub (work)", website: "github.com", username: "octo-work")
    try store.save(github)
    try store.save(other)
    let registration = try store.createPasskey(
      relyingParty: "GitHub.com", userName: "octocat", userHandle: Data([1, 2, 3]), userVerified: true)
    let passkey = registration.passkey
    #expect(passkey.login == github.id)
    #expect(passkey.relyingParty == "github.com")
    #expect(try store.record(VaultPasskey.self, id: passkey.id) == passkey)
    #expect(try store.passkeys(relyingParty: "github.com").map(\.id) == [passkey.id])
    #expect(try store.passkeys(relyingParty: "github.com", allowed: [Data([9])]).isEmpty)

    // The key signs, and the site can check it against the public key it got.
    let key = try #require(passkey.privateKey)
    #expect(registration.attestationObject.suffix(32) == key.publicKey.rawRepresentation.suffix(32))
    let hash = Data(repeating: 7, count: 32)
    let assertion = try passkey.assertion(clientDataHash: hash, userVerified: true)
    let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
    #expect(key.publicKey.isValidSignature(signature, for: assertion.authenticatorData + hash))
  }

  @Test func passkeyWithoutALoginMakesOne() throws {
    let store = try store()
    let passkey = try store.createPasskey(
      relyingParty: "example.com", userName: "aiko", userHandle: Data([1]), userVerified: false
    ).passkey
    let loginID = try #require(passkey.login)
    let login = try #require(try store.record(VaultLogin.self, id: loginID))
    #expect(login.website == "example.com")
    #expect(login.username == "aiko")
    #expect(login.password == nil)
  }

  @Test func sameAccountReplacesItsPasskey() throws {
    let store = try store()
    let first = try store.createPasskey(relyingParty: "example.com", userName: "aiko", userHandle: Data([1]), userVerified: true).passkey
    let second = try store.createPasskey(relyingParty: "example.com", userName: "aiko", userHandle: Data([1]), userVerified: true).passkey
    #expect(try store.records(VaultPasskey.self).map(\.id) == [second.id])
    #expect(second.login == first.login)
    #expect(VaultSecrets.secret(VaultPasskey.keySecret(first.id)) == nil)
  }

  @Test func deletingTheLoginDeletesItsPasskeys() throws {
    let store = try store()
    let passkey = try store.createPasskey(relyingParty: "example.com", userName: "aiko", userHandle: Data([1]), userVerified: true).passkey
    let loginID = try #require(passkey.login)
    try store.deleteLogin(id: loginID)
    #expect(try store.records(VaultPasskey.self).isEmpty)
    #expect(VaultSecrets.secret(VaultPasskey.keySecret(passkey.id)) == nil)
  }
}
