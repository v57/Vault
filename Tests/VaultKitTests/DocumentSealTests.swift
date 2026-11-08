import CryptoKit
import Foundation
import Testing

@testable import VaultKit

/// A document's page text, thumbnail and pages are sealed under a key only Vault holds, so the passport number in a
/// scan isn't readable by every app that opens the store (security audit M14).
struct DocumentSealTests {
  let keys = MemoryKeyProvider()

  init() { VaultSecrets.useInMemoryStore() }

  func makeStore() throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac")
  }

  /// Every field of the stored item, as text, the way an app without the key reads it.
  func rawText(_ item: VaultItem?) -> String {
    (item?.values ?? [:]).map { "\($0.key)=\($0.value.stringValue ?? "")" }.joined(separator: "\n")
  }

  @Test func passportNumberIsInNoPlainField() throws {
    let store = try makeStore()
    let number = "TR1234567"
    var document = VaultDocument(title: "Passport", kind: DocumentKind.passport.id)
    document.text = "PASSPORT P<JPN \(number)"
    document.thumbnail = Data("thumbnail \(number)".utf8)
    try store.save(document)
    let page = VaultDocumentFile(document: document.id, data: Data("page \(number)".utf8), text: "page \(number)")
    try store.addFile(page)

    for id in [document.id, page.id] {
      let raw = rawText(try store.item(id: id))
      #expect(!raw.contains(number))
      #expect(!raw.contains(Data("page \(number)".utf8).base64EncodedString()))
      #expect(!raw.contains(Data("thumbnail \(number)".utf8).base64EncodedString()))
    }
    // Vault reads them back as they were.
    let read = try #require(try store.record(VaultDocument.self, id: document.id))
    #expect(read.text == document.text)
    #expect(read.thumbnail == document.thumbnail)
    #expect(try store.files(of: read).map(\.data) == [page.data])
    #expect(try store.files(of: read).map(\.text) == [page.text])
    // Saved again unchanged, the sealed fields stay as they were: the seal is deterministic, so a save doesn't
    // rewrite (and sync) them.
    let sealedFields = ["sealedText", "sealedThumbnail"]
    let before = try store.item(id: document.id)?.values ?? [:]
    try store.save(read)
    let after = try store.item(id: document.id)?.values ?? [:]
    for field in sealedFields { #expect(before[field] != nil && before[field] == after[field]) }
  }

  @Test func anotherKeyOpensNothing() throws {
    let key = SymmetricKey(size: .bits256)
    let sealed = try #require(DocumentSeal.seal(Data("IBAN DE89".utf8), field: "text", key: key))
    #expect(DocumentSeal.open(sealed, field: "text", key: key) == Data("IBAN DE89".utf8))
    #expect(DocumentSeal.open(sealed, field: "text", key: SymmetricKey(size: .bits256)) == nil)
    // Bound to its field: a sealed thumbnail can't be passed off as text.
    #expect(DocumentSeal.open(sealed, field: "thumbnail", key: key) == nil)
  }

  @Test func plainDocumentsFromBeforeAreSealed() throws {
    let store = try makeStore()
    let document = VaultDocument(title: "Card", kind: DocumentKind.other.id)
    // As an older build wrote it: plain text and thumbnail.
    try store.save(id: document.id, kind: VaultDocument.kind, changes: [
      "title": .string("Card"), "kind": .string(DocumentKind.other.id), "text": .string("CARD 4111 1111"),
      "thumbnail": .string(Data([7, 7]).base64EncodedString()),
    ])
    try store.save(id: "page-1", kind: VaultDocumentFile.kind, changes: [
      "document": .string(document.id), "data": .string(Data([1, 2, 3]).base64EncodedString()),
      "text": .string("CARD 4111 1111"),
    ])
    let before = try #require(try store.record(VaultDocument.self, id: document.id))
    #expect(before.text == "CARD 4111 1111")

    #expect(try store.sealDocuments() == 2)
    #expect(!rawText(try store.item(id: document.id)).contains("4111"))
    #expect(!rawText(try store.item(id: "page-1")).contains("4111"))
    let after = try #require(try store.record(VaultDocument.self, id: document.id))
    #expect(after.text == "CARD 4111 1111")
    #expect(after.thumbnail == Data([7, 7]))
    #expect(try store.record(VaultDocumentFile.self, id: "page-1")?.data == Data([1, 2, 3]))
    #expect(try store.sealDocuments() == 0)
  }

  @Test func documentSecretsAreVaultOnly() {
    #expect(VaultSecretTiers.isVaultOnly(VaultDocument.secretName("number", document: "d1")))
  }
}
