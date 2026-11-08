import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// Security audit M4: the share extension holds no keys. It seals what's shared to Vault's drop key; only Vault opens it.
struct VaultIncomingTests {
  private let file = SharedFile(
    name: "Passport", contentType: "application/pdf", data: Data("%PDF-1.7 secret page".utf8), width: 595, height: 842,
    pageCount: 2, thumbnail: Data([1, 2, 3]))

  @Test func sharedFilesReachVaultSealed() throws {
    let incoming = VaultIncoming(folder: temporaryDirectory())
    #expect(throws: VaultIncoming.IncomingError.noKey) { try incoming.drop([file]) }

    let key = Curve25519.KeyAgreement.PrivateKey()
    try incoming.publish(key)
    try incoming.drop([file])
    try incoming.drop([file, file])

    // Nothing readable in the folder.
    for url in try FileManager.default.contentsOfDirectory(at: incoming.folder, includingPropertiesForKeys: nil) {
      #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("secret page"))
    }

    // Another key opens nothing, and the drops stay.
    var filed: [[SharedFile]] = []
    #expect(incoming.collect(with: Curve25519.KeyAgreement.PrivateKey()) { filed.append($0) } == (0, 2))
    #expect(filed.isEmpty)

    #expect(incoming.collect(with: key) { filed.append($0) } == (2, 0))
    #expect(filed.map(\.count).sorted() == [1, 2])
    #expect(filed.flatMap { $0 }.allSatisfy { $0 == file })
    #expect(incoming.collect(with: key) { filed.append($0) } == (0, 0))
  }

  /// A drop Vault couldn't file (the store refused) stays for the next time.
  @Test func aDropStaysUntilItsFiled() throws {
    let incoming = VaultIncoming(folder: temporaryDirectory())
    let key = Curve25519.KeyAgreement.PrivateKey()
    try incoming.publish(key)
    try incoming.drop([file])
    struct Refused: Error {}
    #expect(incoming.collect(with: key) { _ in throw Refused() } == (0, 1))
    #expect(incoming.collect(with: key) { _ in } == (1, 0))
  }
}
