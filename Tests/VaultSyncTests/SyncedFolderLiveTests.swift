import Foundation
import Testing
import VaultKit

@testable import VaultSync

/// `VAULT_SYNC_S3=<endpoint> <bucket> <access key> <secret>`: the owner and a read-only friend share a folder through
/// a real S3 server (a throwaway one: Hub's `s3`, which hub-s3-local and the Hub app's Storage run, or MinIO), each
/// under a fresh prefix.
///
/// ```bash
/// bun ~/Developer/Hub/Services/s3/server.ts --host 127.0.0.1 --port 9317 --key k --secret s --path /tmp/s3 &
/// VAULT_SYNC_S3="http://127.0.0.1:9317 hub k s" swift test --filter SyncedFolderLiveTests
/// ```
private let live = ProcessInfo.processInfo.environment["VAULT_SYNC_S3"]?.split(separator: " ").map(String.init)

@Suite(.enabled(if: live?.count == 4))
struct SyncedFolderLiveTests {
  @Test func aReadOnlyFriendReceivesThroughS3() async throws {
    let live = try #require(live)
    let prefix = "vault-sync-test-\(UUID().uuidString.prefix(8))"
    let remoteRecord = VaultRemote(
      name: "test", kind: .s3, endpoint: live[0], bucket: live[1], path: prefix, accessKeyID: live[2], enabled: true)
    let remote = try #require(try RemoteConnections.fileSystem(for: remoteRecord, secret: live[3]))
    let directory = try TemporaryDirectory()
    let owner = PersonalIdentity()
    let friend = PersonalIdentity()

    var mine = VaultFolder(name: "mods", encrypted: false, remoteID: remoteRecord.id)
    mine.remotePath = mine.id
    try await FolderSync.createRemoteFolder(
      remote: remote, remotePath: mine.syncPath, folderID: mine.id, owner: owner, ownerName: "Owner")
    let ownerSync = try FolderSync(
      FolderSync.Configuration(
        folder: mine, remote: remote, local: try PlainSyncFolder(url: directory.file("owner")), device: "owner-mac",
        identity: owner, stateDirectory: directory.file("owner-state")))
    let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try big.write(to: directory.file("owner/big.bin"))
    try Data("a".utf8).write(to: directory.file("owner/a.txt"))
    try await ownerSync.sync()
    try await ownerSync.addMember(friend.publicIdentity, name: "Friend", role: .readOnly)

    let invite = try VaultInvite.make(from: owner, name: "Owner", folderID: mine.id, folderName: mine.name)
    var theirs = try #require(VaultFolder.shared(by: invite))
    theirs.remoteID = remoteRecord.id
    let friendFolder = try PlainSyncFolder(url: directory.file("friend"))
    let friendSync = try FolderSync(
      FolderSync.Configuration(
        folder: theirs, remote: remote, local: friendFolder, device: "friend-pc", identity: friend,
        stateDirectory: directory.file("friend-state")))
    try await friendSync.sync()
    #expect(try friendFolder.scan().map(\.path) == ["a.txt", "big.bin"])
    #expect(try Data(contentsOf: directory.file("friend/big.bin")) == big)

    try Data("b".utf8).write(to: directory.file("owner/a.txt"))
    try await ownerSync.sync()
    try await friendSync.sync()
    #expect(try String(contentsOf: directory.file("friend/a.txt"), encoding: .utf8) == "b")
    #expect(await friendSync.status.remote.chunkCount > 0)
  }
}
