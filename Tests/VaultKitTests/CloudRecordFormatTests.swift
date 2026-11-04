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

    /// `CloudSync.remote` as it was at c4ba614: without the field, no record.
    private func oldBuildSees(_ record: CKRecord) -> Bool { record["keyID"] as? String != nil }

    @Test func aFormat2RecordHasNoKeyIDAndComesBackWithTheHeaders() throws {
      let outgoing = OutgoingRecord(id: "r", keyID: "abcd", payload: try format2(), systemFields: nil, version: 1)
      let record = CloudSync.makeRecord(outgoing, id: id)
      #expect(record["keyID"] == nil)
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
    }

    @Test func aRecordWithNeitherIsSkipped() throws {
      let record = CKRecord(recordType: CloudSync.recordType, recordID: id)
      record["payload"] = Data(repeating: 7, count: 64) as NSData
      #expect(CloudSync.remote(record) == nil)
    }
  }
#endif
