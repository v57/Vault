import CryptoKit
import Foundation
import Testing
import VaultFiles
import VaultKit

@testable import VaultSync

struct FolderMembersTests {
  let alice = PersonalIdentity()
  let bob = PersonalIdentity()
  let carol = PersonalIdentity()
  let folderID = "F1"

  func verify(_ list: FolderMembers, minimumVersion: Int = 0) throws -> FolderMembers {
    try FolderMembers(
      verifying: list.fileData, folderID: folderID, ownerSigningKey: alice.publicIdentity.signingKey,
      minimumVersion: minimumVersion)
  }

  @Test func createsVerifiesAndOpensTheKey() throws {
    let key = FolderKey()
    let list = try FolderMembers.create(folderID: folderID, owner: alice, ownerName: "Alice", key: key)
    let read = try verify(list)
    #expect(read == list)
    #expect(read.version == 0 && read.epoch == 0)
    #expect(read.role(of: alice.publicIdentity.signingKey) == .readWrite)
    let keyring = try read.keyring(for: alice)
    #expect(keyring.current == key && keyring.first == key && keyring.key(id: key.id) == key)
    #expect(throws: FolderSyncError.notAMember) { try read.keyring(for: bob) }
  }

  @Test func refusesForgeriesOtherFoldersAndOldCopies() throws {
    var list = try FolderMembers.create(folderID: folderID, owner: alice, ownerName: "Alice")
    // Signed by someone else.
    let forged = try FolderMembers.create(folderID: folderID, owner: bob, ownerName: "Bob")
    #expect(throws: FolderSyncError.notSignedByOwner) { try verify(forged) }
    // Changed after signing.
    var file = try JSONSerialization.jsonObject(with: list.fileData) as! [String: Any]
    var body = String(decoding: Data(base64Encoded: file["list"] as! String)!, as: UTF8.self)
    body = body.replacingOccurrences(of: "\"version\":0", with: "\"version\":9")
    file["list"] = Data(body.utf8).base64EncodedString()
    let tampered = try JSONSerialization.data(withJSONObject: file)
    #expect(throws: FolderSyncError.notSignedByOwner) {
      try FolderMembers(verifying: tampered, folderID: folderID, ownerSigningKey: alice.publicIdentity.signingKey)
    }
    #expect(throws: FolderSyncError.wrongFolder) {
      try FolderMembers(verifying: list.fileData, folderID: "other", ownerSigningKey: alice.publicIdentity.signingKey)
    }
    #expect(throws: FolderSyncError.damaged("member list")) {
      try FolderMembers(verifying: Data("{}".utf8), folderID: folderID, ownerSigningKey: alice.publicIdentity.signingKey)
    }
    let old = list
    try list.add(bob.publicIdentity, name: "Bob", role: .readOnly, owner: alice)
    #expect(list.version == 1)
    #expect(throws: FolderSyncError.olderMemberList(found: 0, known: 1)) { try verify(old, minimumVersion: 1) }
    #expect(try verify(list, minimumVersion: 1).version == 1)
  }

  @Test func onlyTheOwnerChangesIt() throws {
    var list = try FolderMembers.create(folderID: folderID, owner: alice, ownerName: "Alice")
    try list.add(bob.publicIdentity, name: "Bob", role: .readWrite, owner: alice)
    #expect(throws: FolderSyncError.notOwner) { try list.add(carol.publicIdentity, name: "C", role: .readWrite, owner: bob) }
    #expect(throws: FolderSyncError.notOwner) { try list.remove(signingKey: alice.publicIdentity.signingKey, owner: bob) }
    #expect(throws: FolderSyncError.cannotChangeOwner) {
      try list.remove(signingKey: alice.publicIdentity.signingKey, owner: alice)
    }
    #expect(throws: FolderSyncError.cannotChangeOwner) {
      try list.setRole(.readOnly, for: alice.publicIdentity.signingKey, owner: alice)
    }
    #expect(throws: FolderSyncError.unknownMember) { try list.remove(signingKey: carol.publicIdentity.signingKey, owner: alice) }
  }

  @Test func membersOpenEveryEpochAndRemovalRotates() throws {
    let first = FolderKey()
    var list = try FolderMembers.create(folderID: folderID, owner: alice, ownerName: "Alice", key: first)
    try list.add(bob.publicIdentity, name: "Bob", role: .readWrite, owner: alice)
    try list.add(carol.publicIdentity, name: "Carol", role: .readOnly, owner: alice)
    #expect(try verify(list).keyring(for: bob).current == first)
    #expect(try verify(list).keyring(for: carol).current == first)

    let second = try list.remove(signingKey: bob.publicIdentity.signingKey, owner: alice, writesUntil: ["bob-mac": 4])
    let read = try verify(list, minimumVersion: 2)
    #expect(read.epoch == 1 && read.keyIDs == [0: first.id, 1: second.id])
    #expect(throws: FolderSyncError.notAMember) { try read.keyring(for: bob) }
    let carolKeys = try read.keyring(for: carol)
    #expect(carolKeys.current == second && carolKeys.keys[0] == first)
    #expect(try read.keyring(for: alice).current == second)

    // Bob's entries up to where he was removed still count; later ones and other devices' don't.
    #expect(read.canWrite(signingKey: bob.publicIdentity.signingKey, device: "bob-mac", sequence: 4))
    #expect(!read.canWrite(signingKey: bob.publicIdentity.signingKey, device: "bob-mac", sequence: 5))
    #expect(!read.canWrite(signingKey: bob.publicIdentity.signingKey, device: "bob-ipad", sequence: 1))
    #expect(!read.canWrite(signingKey: carol.publicIdentity.signingKey, device: "carol", sequence: 1))
    #expect(read.canWrite(signingKey: alice.publicIdentity.signingKey, device: "any", sequence: 99))

    // Someone added after a rotation reads both epochs.
    let dave = PersonalIdentity()
    try list.add(dave.publicIdentity, name: "Dave", role: .readOnly, owner: alice)
    let daveKeys = try verify(list).keyring(for: dave)
    #expect(daveKeys.keys == [0: first, 1: second])
  }

  @Test func rolesChange() throws {
    var list = try FolderMembers.create(folderID: folderID, owner: alice, ownerName: "Alice")
    try list.add(bob.publicIdentity, name: "Bob", role: .readWrite, owner: alice)
    try list.setRole(.readOnly, for: bob.publicIdentity.signingKey, owner: alice, writesUntil: ["b": 2])
    #expect(list.role(of: bob.publicIdentity.signingKey) == .readOnly)
    #expect(list.canWrite(signingKey: bob.publicIdentity.signingKey, device: "b", sequence: 2))
    #expect(!list.canWrite(signingKey: bob.publicIdentity.signingKey, device: "b", sequence: 3))
    // Adding someone already there changes their role.
    try list.add(bob.publicIdentity, name: "Bob", role: .readWrite, owner: alice)
    #expect(try verify(list).role(of: bob.publicIdentity.signingKey) == .readWrite)
    #expect(list.formerWriters.isEmpty)
  }

  @Test func readsAndWritesOnARemote() async throws {
    let remote = MemoryRemoteFileSystem()
    await #expect(throws: FolderSyncError.noMemberList) {
      try await FolderMembers.read(
        from: remote, folderPath: "shared/F", folderID: folderID, ownerSigningKey: alice.publicIdentity.signingKey)
    }
    let list = try FolderMembers.create(folderID: folderID, owner: alice, ownerName: "Alice")
    try await list.write(to: remote, folderPath: "shared/F")
    #expect(await remote.allFiles == ["shared/F/members"])
    let read = try await FolderMembers.read(
      from: remote, folderPath: "shared/F", folderID: folderID, ownerSigningKey: alice.publicIdentity.signingKey)
    #expect(read == list)
  }
}
