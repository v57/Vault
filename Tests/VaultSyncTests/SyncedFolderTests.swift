import Foundation
import Testing
import VaultKit

@testable import VaultSync

/// The app's flow, from records: the owner syncs a plain folder through a remote, invites a friend, adds them as a
/// read-only member, and the friend's record (made from the invite) receives every change and sends none.
struct SyncedFolderTests {
  @Test func aFriendJoinsFromAnInviteAndReceivesTheOwnersChanges() async throws {
    let directory = try TemporaryDirectory()
    let remote = MemoryRemoteFileSystem()
    let owner = PersonalIdentity()
    let friend = PersonalIdentity()

    // The owner's folder: plain on the owner's Mac, synced at its own id on the remote.
    var mine = VaultFolder(name: "mods", encrypted: false, remoteID: "remote-1")
    mine.setPath(directory.file("owner/mods").path, for: "owner-mac")
    #expect(mine.syncPath == mine.id)
    #expect(mine.isOwned(by: owner))
    #expect(try mine.ownerSigningKey(for: owner) == owner.publicIdentity.signingKey)
    try await FolderSync.createRemoteFolder(
      remote: remote, remotePath: mine.syncPath, folderID: mine.id, owner: owner, ownerName: "Owner")
    let ownerFolder = try PlainSyncFolder(url: directory.file("owner/mods"))
    let ownerSync = try FolderSync(
      FolderSync.Configuration(
        folder: mine, remote: remote, local: ownerFolder, device: "owner-mac", identity: owner,
        stateDirectory: directory.file("owner-state")))
    try Data("sodium 0.6".utf8).write(to: directory.file("owner/mods/sodium.jar"))
    try await ownerSync.sync()

    // The owner's invite names the folder; the friend's record comes from it.
    let invite = try VaultInvite.make(from: owner, name: "Owner", folderID: mine.id, folderName: mine.name)
    let link = try #require(VaultInvite(url: invite.url))
    var theirs = try #require(VaultFolder.shared(by: link))
    #expect(theirs.id == mine.id)
    #expect(theirs.name == "mods")
    #expect(theirs.syncPath == mine.syncPath)
    #expect(theirs.isShared)
    #expect(!theirs.isOwned(by: friend))
    #expect(try theirs.ownerSigningKey(for: friend) == owner.publicIdentity.signingKey)
    theirs.remoteID = "friends-remote-record"
    theirs.setMode(.readOnly, for: "friend-pc")

    let friendFolder = try PlainSyncFolder(url: directory.file("friend/mods"))
    let friendSync = try FolderSync(
      FolderSync.Configuration(
        folder: theirs, remote: remote, local: friendFolder, device: "friend-pc", identity: friend,
        stateDirectory: directory.file("friend-state")))

    // Before the owner adds them, the friend isn't a member.
    await #expect(throws: FolderSyncError.notAMember) { try await friendSync.sync() }

    try await ownerSync.addMember(friend.publicIdentity, name: "Friend", role: .readOnly)
    try await friendSync.sync()
    #expect(try friendFolder.scan().map(\.path) == ["sodium.jar"])
    #expect(await friendSync.status.role == .readOnly)

    // The owner updates the folder; the friend's copy follows.
    try FileManager.default.removeItem(at: directory.file("owner/mods/sodium.jar"))
    try Data("sodium 0.7".utf8).write(to: directory.file("owner/mods/sodium-0.7.jar"))
    try await ownerSync.sync()
    try await friendSync.sync()
    #expect(try friendFolder.scan().map(\.path) == ["sodium-0.7.jar"])
    #expect(try String(contentsOf: directory.file("friend/mods/sodium-0.7.jar"), encoding: .utf8) == "sodium 0.7")

    // The friend's own edit stays on their side, "changed here".
    try Data("my config".utf8).write(to: directory.file("friend/mods/extra.jar"))
    try await friendSync.sync()
    try await ownerSync.sync()
    #expect(try ownerFolder.scan().map(\.path) == ["sodium-0.7.jar"])
    #expect(await friendSync.status.changedHere.map(\.path) == ["extra.jar"])
  }

  @Test func anInviteWithoutAFolderMakesNoRecord() throws {
    let invite = try VaultInvite.make(from: PersonalIdentity(), name: "Someone")
    #expect(VaultFolder.shared(by: invite) == nil)
  }

  @Test func aDamagedOwnerKeyIsAnError() {
    let folder = VaultFolder(name: "x", ownerSigningKey: "not a key")
    #expect(throws: FolderSyncError.self) { try folder.ownerSigningKey(for: PersonalIdentity()) }
  }
}
