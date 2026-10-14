import CryptoKit
import Foundation
import Testing

@testable import VaultKit

struct SyncTests {
  let keys = MemoryKeyProvider()
  let cloud = FakeCloud()

  func device(_ name: String) throws -> FakeApp {
    try FakeApp(directory: temporaryDirectory(), keys: keys, device: name, name: "\(name).app")
  }

  @Test func editsOnTwoDevicesMergeFieldByField() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    try mac.store.save(id: "host1", kind: "host", changes: ["name": "prod", "port": 22, "user": "root"])
    mac.sync(cloud)
    phone.sync(cloud)
    #expect(try phone.store.item(id: "host1")?.values["name"] == "prod")

    // Both offline: the Mac changes the port, the phone renames.
    try mac.store.save(id: "host1", kind: "host", changes: ["port": 2222])
    try phone.store.save(id: "host1", kind: "host", changes: ["name": "Production"])
    phone.sync(cloud)
    mac.sync(cloud)  // conflict: merges the phone's rename and sends the result
    phone.sync(cloud)

    let expected: [String: JSONValue] = ["name": "Production", "port": 2222, "user": "root"]
    #expect(try mac.store.item(id: "host1")?.values == expected)
    #expect(try phone.store.item(id: "host1")?.values == expected)
    #expect(try mac.store.pendingCount() == 0)
    #expect(try phone.store.pendingCount() == 0)
  }

  @Test func bothDevicesKeepTheLaterEditOfOneField() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    try mac.store.save(id: "n", kind: "host", changes: ["name": "first"])
    mac.sync(cloud)
    phone.sync(cloud)
    try mac.store.save(id: "n", kind: "host", changes: ["name": "mac"])
    Thread.sleep(forTimeInterval: 0.005)
    try phone.store.save(id: "n", kind: "host", changes: ["name": "phone"])
    mac.sync(cloud)
    phone.sync(cloud)
    mac.sync(cloud)
    #expect(try mac.store.item(id: "n")?.values["name"] == "phone")
    #expect(try phone.store.item(id: "n")?.values["name"] == "phone")
  }

  @Test func twoAppsOnOneDeviceSendAChangeOnce() throws {
    let directory = temporaryDirectory()
    let git = try FakeApp(directory: directory, keys: keys, device: "mac", name: "git")
    let code = try FakeApp(directory: directory, keys: keys, device: "mac", name: "code")
    try git.store.save(id: "p1", kind: "project", changes: ["name": "Shell"])

    // Git leased its own write: Code leaves it alone.
    code.push(cloud)
    #expect(cloud.saves == 0)
    git.push(cloud)
    #expect(cloud.saves == 1)

    // Code fetches the same record: already in the shared store, nothing changes or goes up again.
    let revision = code.store.revision
    code.pull(cloud)
    code.push(cloud)
    #expect(code.store.revision == revision)
    #expect(cloud.saves == 1)
  }

  @Test func anotherAppSendsWhenTheWriterQuitsBeforeSending() throws {
    let directory = temporaryDirectory()
    let git = try FakeApp(directory: directory, keys: keys, device: "mac", name: "git")
    git.store.lease = 0.05
    let code = try FakeApp(directory: directory, keys: keys, device: "mac", name: "code")
    try git.store.save(id: "p1", kind: "project", changes: ["name": "Shell"])
    // Git quits without sending. Once its lease runs out, Code sends.
    Thread.sleep(forTimeInterval: 0.1)
    code.push(cloud)
    #expect(cloud.saves == 1)
    #expect(cloud.records["p1"] != nil)
    #expect(try code.store.pendingCount() == 0)
  }

  @Test func aChangeMadeDuringASendGoesUpToo() throws {
    let mac = try device("mac")
    try mac.store.save(id: "h", kind: "host", changes: ["name": "a"])
    let id = mac.sync.idsToSend()[0]
    let record = try #require(mac.sync.record(for: id))
    try mac.store.save(id: "h", kind: "host", changes: ["name": "b"])
    guard case .success(let tag) = cloud.save(record) else { Issue.record("save failed"); return }
    #expect(mac.sync.saved(id: id, changeTag: tag, systemFields: Data(tag.utf8)) == .resend)
    mac.push(cloud)
    let phone = try device("phone")
    phone.sync(cloud)
    #expect(try phone.store.item(id: "h")?.values["name"] == "b")
  }

  @Test func deleteSyncsAndALaterEditBringsItBack() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    try mac.store.save(id: "d", kind: "database", changes: ["name": "db"])
    mac.sync(cloud)
    phone.sync(cloud)

    try mac.store.delete(id: "d")
    mac.sync(cloud)
    phone.sync(cloud)
    #expect(try phone.store.items(kind: "database").isEmpty)

    // The phone edits it after the delete (it was offline): the edit wins.
    try phone.store.save(id: "d", kind: "database", changes: ["name": "db2"])
    phone.sync(cloud)
    mac.sync(cloud)
    #expect(try mac.store.items(kind: "database").map(\.id) == ["d"])
  }

  @Test func theSameProjectAddedOnTwoDevicesBecomesOne() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    let id = try mac.store.derivedID("project:github.com/v57/shell")
    #expect(try phone.store.derivedID("project:github.com/v57/shell") == id)
    try mac.store.save(id: id, kind: "project", changes: ["name": "Shell", "path.mac": "/Users/v57/Shell"])
    try phone.store.save(id: id, kind: "project", changes: ["name": "Shell", "path.phone": "/ipad/Shell"])
    mac.sync(cloud)
    phone.sync(cloud)
    mac.sync(cloud)
    #expect(cloud.records.count == 1)
    let values = try #require(try mac.store.item(id: id)?.values)
    #expect(values["path.mac"] == "/Users/v57/Shell")
    #expect(values["path.phone"] == "/ipad/Shell")
  }

  @Test func duplicatesWithDifferentIDsFoldIntoOne() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    try mac.store.save(id: "b-project", kind: "project", changes: ["_identity": "x", "name": "X", "path.mac": "/x"])
    try phone.store.save(id: "a-project", kind: "project", changes: ["_identity": "x", "name": "X", "path.phone": "/y"])
    mac.sync(cloud)
    phone.sync(cloud)
    mac.sync(cloud)
    phone.sync(cloud)
    for app in [mac, phone] {
      let projects = try app.store.items(kind: "project")
      #expect(projects.map(\.id) == ["a-project"])
      #expect(projects.first?.values["path.mac"] == "/x")
      #expect(projects.first?.values["path.phone"] == "/y")
    }
  }

  @Test func recordsSealedWithAnotherDevicesKeyAppearOnceTheKeyArrives() throws {
    let macKeys = MemoryKeyProvider(keys: ["bbbb": SymmetricKey(size: .bits256)])
    let phoneKeys = MemoryKeyProvider(keys: ["aaaa": SymmetricKey(size: .bits256)])
    let mac = try FakeApp(directory: temporaryDirectory(), keys: macKeys, device: "mac", name: "mac")
    let phone = try FakeApp(directory: temporaryDirectory(), keys: phoneKeys, device: "phone", name: "phone")
    try phone.store.save(id: "h", kind: "host", changes: ["name": "from phone"])
    phone.sync(cloud)
    mac.sync(cloud)
    #expect(try mac.store.items(kind: "host").isEmpty)

    // iCloud Keychain delivers the phone's key; the Mac now has both and writes with the smaller id.
    macKeys.add(phoneKeys.allKeys["aaaa"]!, id: "aaaa")
    #expect(try mac.store.items(kind: "host").map(\.id) == ["h"])
    try mac.store.save(id: "h", kind: "host", changes: ["port": 22])
    mac.sync(cloud)
    #expect(cloud.records["h"]?.keyID == "aaaa")
  }

  @Test func purgedTombstonesLeaveEveryStore() throws {
    let mac = try device("mac")
    let phone = try device("phone")
    try mac.store.save(id: "t", kind: "host", changes: ["name": "x"])
    try mac.store.delete(id: "t")
    mac.sync(cloud)
    phone.sync(cloud)
    let purged = try mac.store.purgeTombstones(olderThan: -1)
    #expect(purged == ["t"])
    for id in purged { cloud.delete(id) }
    phone.sync(cloud)
    #expect(try phone.store.item(id: "t") == nil)
  }

  @Test func fieldsAnAppDoesntKnowSurviveItsSaves() throws {
    let mac = try device("mac")
    try mac.store.save(id: "db", kind: "database", changes: ["engine": "mongodb", "replicaSet": "rs0"])
    // An app that only knows `engine` and `name` saves its view.
    try mac.store.save(id: "db", kind: "database", changes: ["engine": "mongodb", "name": "Atlas"])
    #expect(try mac.store.item(id: "db")?.values["replicaSet"] == "rs0")
  }

  @Test func storesSeeEachOthersWritesThroughTheFile() throws {
    let directory = temporaryDirectory()
    let one = try VaultStore(directory: directory, keys: keys, deviceID: "mac", notifier: nil, owner: "one")
    let two = try VaultStore(directory: directory, keys: keys, deviceID: "mac", notifier: nil, owner: "two")
    try one.save(id: "x", kind: "project", changes: ["name": "A"])
    #expect(try two.items(kind: "project").first?.values["name"] == "A")
    try two.save(id: "x", kind: "project", changes: ["name": "B"])
    // The second write's clock is later even though another connection issued the first.
    let item = try #require(try one.item(id: "x"))
    #expect(item.values["name"] == "B")
  }

  @Test func anAppWhoseSyncIsStuckLetsGoOfItsWrites() throws {
    let directory = temporaryDirectory()
    let stuck = try FakeApp(directory: directory, keys: keys, device: "mac", name: "stuck")
    stuck.store.lease = 0.05
    let working = try FakeApp(directory: directory, keys: keys, device: "mac", name: "working")
    try stuck.store.save(id: "x", kind: "host", changes: ["name": "x"])
    // The stuck app keeps asking for its outbox but never sends.
    _ = stuck.sync.idsToSend()
    Thread.sleep(forTimeInterval: 0.07)
    _ = stuck.sync.idsToSend()
    Thread.sleep(forTimeInterval: 0.07)
    working.push(cloud)
    #expect(cloud.records["x"] != nil)
    #expect(try working.store.pendingCount() == 0)
  }
}
