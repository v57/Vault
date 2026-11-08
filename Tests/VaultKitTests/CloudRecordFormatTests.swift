import CryptoKit
import Foundation
import Testing

@testable import VaultKit

#if canImport(CloudKit)
  import CloudKit

  /// `CKRecord` works offline; none of this talks to CloudKit.
  @Suite struct CloudRecordFormatTests {
    private let id = CKRecord.ID(recordName: "r", zoneID: CKRecordZone.ID(zoneName: "Vault"))

    private func format2() throws -> Data {
      try VaultItemSeal.seal(
        kind: "host", fields: Data("{}".utf8), id: "r", account: "personal", keyID: "abcd", key: SymmetricKey(size: .bits256))
    }

    /// `CloudSync.remote` as it was at c4ba614: a record needs a `keyID` and a payload, and the payload it gets.
    private func oldBuildSees(_ record: CKRecord) -> Bool { oldBuildPayload(record) != nil }

    private func oldBuildPayload(_ record: CKRecord) -> Data? {
      guard record["keyID"] as? String != nil else { return nil }
      return record["payload"] as? Data ?? (record["payloadAsset"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
    }

    @Test func aFormat2RecordHasNoKeyIDAndComesBackWithTheHeaders() throws {
      let outgoing = OutgoingRecord(id: "r", keyID: "abcd", payload: try format2(), systemFields: nil, version: 1)
      let record = CloudSync.makeRecord(outgoing, id: id)
      #expect(record["keyID"] == nil)
      #expect(record["payload"] == nil)
      #expect(record[CloudSync.sealedField] as? Data == outgoing.payload)
      #expect(!oldBuildSees(record))
      let remote = try #require(CloudSync.remote(record))
      #expect(remote.keyID == "abcd")
      #expect(remote.payload == outgoing.payload)
    }

    @Test func aFormat1RecordKeepsItsField() throws {
      let outgoing = OutgoingRecord(id: "r", keyID: "abcd", payload: Data(repeating: 7, count: 64), systemFields: nil, version: 1)
      let record = CloudSync.makeRecord(outgoing, id: id)
      #expect(record["keyID"] as? String == "abcd")
      #expect(oldBuildSees(record))
      #expect(CloudSync.remote(record)?.keyID == "abcd")
    }

    /// The record that replaces a format 1 record on the server is built on its system fields alone, so the field is
    /// only cleared there if clearing it counts as a change. If it didn't, the server would keep the old `keyID` beside
    /// the new payload, and old builds would see it.
    @Test func replacingAFormat1RecordClearsTheFieldOnTheServer() throws {
      let original = CKRecord(recordType: CloudSync.recordType, recordID: id)
      original["keyID"] = "abcd" as NSString
      original["payload"] = Data(repeating: 7, count: 64) as NSData
      let system = CloudSync.archive(original)

      let outgoing = OutgoingRecord(id: "r", keyID: "abcd", payload: try format2(), systemFields: system, version: 2)
      let record = CloudSync.makeRecord(outgoing, id: id)
      #expect(record["keyID"] == nil)
      #expect(record.changedKeys().contains("keyID"))
      #expect(record.changedKeys().contains("payload"))
      #expect(record.changedKeys().contains(CloudSync.sealedField))
    }

    /// Security audit M1, whatever the server keeps: if CloudKit ignored the clearing and kept the format 1 `keyID` and
    /// payload, an old build still gets the version it can open, never the new payload under the old key's name (which
    /// it would store over its own copy, losing the item), and a new build reads the format 2 one.
    @Test func aServerThatKeepsClearedFieldsStillGivesOldBuildsWhatTheyCanOpen() throws {
      let format1 = Data(repeating: 7, count: 64)
      let server = CKRecord(recordType: CloudSync.recordType, recordID: id)
      server["keyID"] = "abcd" as NSString
      server["payload"] = format1 as NSData
      let outgoing = OutgoingRecord(id: "r", keyID: "abcd", payload: try format2(), systemFields: CloudSync.archive(server), version: 2)
      let sent = CloudSync.makeRecord(outgoing, id: id)

      // The server applies the changed fields that have a value and keeps the rest.
      for key in sent.changedKeys() where sent[key] != nil { server[key] = sent[key] }
      #expect(oldBuildPayload(server) == format1)
      #expect(CloudSync.remote(server)?.payload == outgoing.payload)

      // And one that honours the clearing: the old build skips it.
      for key in sent.changedKeys() { server[key] = sent[key] }
      #expect(!oldBuildSees(server))
      #expect(CloudSync.remote(server)?.payload == outgoing.payload)
    }

    @Test func aLargeFormat2PayloadGoesAsItsOwnAsset() throws {
      var payload = try format2()
      payload += Data(count: CloudSync.assetThreshold)
      let outgoing = OutgoingRecord(id: "big-\(UUID())", keyID: "abcd", payload: payload, systemFields: nil, version: 1)
      let record = CloudSync.makeRecord(outgoing, id: id)
      defer { CloudSync.removeAssetFile(of: record) }
      #expect(record["payloadAsset"] == nil && record[CloudSync.sealedField] == nil)
      #expect(record[CloudSync.sealedAssetField] is CKAsset)
      #expect(!oldBuildSees(record))
      #expect(CloudSync.remote(record)?.payload == payload)
    }

    @Test func aRecordWithNeitherIsSkipped() throws {
      let record = CKRecord(recordType: CloudSync.recordType, recordID: id)
      record["payload"] = Data(repeating: 7, count: 64) as NSData
      #expect(CloudSync.remote(record) == nil)
    }

    /// A record's asset whose file can't be read isn't a record that was never there: it stops the store finishing.
    @Test func anAssetThatCantBeReadIsUnreadNotDropped() throws {
      let id = CKRecord.ID(recordName: "big", zoneID: CKRecordZone.ID(zoneName: "Vault"))
      let record = CKRecord(recordType: CloudSync.recordType, recordID: id)
      record["payloadAsset"] = CKAsset(fileURL: temporaryDirectory().appendingPathComponent("gone"))
      guard case .unread(let unread) = CloudSync.fetched(record) else {
        Issue.record("It should be unread")
        return
      }
      #expect(unread.id == "big" && unread.hasPayload)

      let empty = CKRecord(recordType: CloudSync.recordType, recordID: id)
      guard case .unread(let nothing) = CloudSync.fetched(empty) else {
        Issue.record("It should be unread")
        return
      }
      #expect(!nothing.hasPayload)
    }
  }
#endif
