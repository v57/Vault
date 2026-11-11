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

  /// V-039: an app whose sends fail and are tried again later doesn't keep the device's other apps from sending.
  @Test func anAppWhoseSendsFailLetsAnotherAppSend() throws {
    let directory = temporaryDirectory()
    let failing = try FakeApp(directory: directory, keys: keys, device: "phone", name: "hub")
    let vault = try FakeApp(directory: directory, keys: keys, device: "phone", name: "vault")
    failing.store.sendsOwnWrites = false
    try failing.store.save(id: "n", kind: "note", changes: ["title": "ZZ", "text": "x"])
    // The failing app leases the write, builds the record, and CloudKit says try later.
    #expect(failing.sync.idsToSend() == ["n"])
    _ = try #require(failing.sync.record(for: "n"))
    #expect(failing.sync.failed(id: "n", .retryLater) == .retryLater)
    // Long before the lease would have run out, the other app sends it.
    vault.push(cloud)
    #expect(cloud.records["n"] != nil)
    #expect(try vault.store.pendingCount() == 0)
    // The failing app's retry finds nothing left to send.
    #expect(failing.sync.record(for: "n") == nil)
  }

  /// V-039: after the V-035/V-036/V-037 changes (device keys noting `lastSeen` and `model`), two devices still exchange
  /// their notes, hosts and device keys through the cloud in both directions, with nothing left in either outbox.
  @Test func twoDevicesExchangeRecordsBothWays() throws {
    VaultSecrets.useInMemoryStore()
    let phone = try device("iphone")
    let pad = try device("ipad")
    for (app, name) in [(phone, "iPhone"), (pad, "iPad")] {
      try app.store.save(
        VaultDeviceKey(
          id: app.store.deviceID, deviceName: name, publicKey: DeviceSeenTests.key, platform: "iOS", model: name,
          updated: Date(timeIntervalSince1970: 1_790_000_000)))
      #expect(try app.store.markDeviceSeen(model: name))
    }
    phone.sync(cloud)
    pad.sync(cloud)
    try phone.store.save(id: "phone-note", kind: "note", changes: ["title": "ZZ 3b sync iPhone", "text": "a"])
    try phone.store.save(id: "phone-host", kind: "host", changes: ["name": "ZZ3b", "port": 22])
    try pad.store.save(id: "pad-note", kind: "note", changes: ["title": "ZZ 3b sync iPad", "text": "b"])
    phone.sync(cloud)
    pad.sync(cloud)
    phone.sync(cloud)
    for app in [phone, pad] {
      #expect(try app.store.item(id: "phone-note")?.values["title"] == "ZZ 3b sync iPhone")
      #expect(try app.store.item(id: "phone-host")?.values["name"] == "ZZ3b")
      #expect(try app.store.item(id: "pad-note")?.values["title"] == "ZZ 3b sync iPad")
      #expect(try app.store.pendingCount() == 0)
      for other in ["iphone", "ipad"] {
        let key = try #require(try app.store.record(VaultDeviceKey.self, id: other))
        #expect(key.lastSeen != nil)
        #expect(key.model == (other == "iphone" ? "iPhone" : "iPad"))
      }
    }
  }

  @Test func aRecordOnItsWayIsntBuiltTwice() throws {
    let mac = try device("mac")
    try mac.store.save(id: "h", kind: "host", changes: ["name": "a"])
    let id = mac.sync.idsToSend()[0]
    #expect(mac.sync.record(for: id) != nil)
    #expect(mac.sync.record(for: id) == nil)
  }
}

/// A clock far ahead wins merges the same way on every device, and stays on the fields it's on (Ideas/Security V6).
struct ClockSkewTests {
  let cloud = FakeCloud()
  let keys = MemoryKeyProvider()
  let year: TimeInterval = 365 * 24 * 3600

  private func device(_ name: String, offset: TimeInterval = 0) throws -> FakeApp {
    let app = try FakeApp(directory: temporaryDirectory(), keys: keys, device: name, name: "\(name).app")
    app.store.wallClock = { Date.now.addingTimeInterval(offset) }
    return app
  }

  private func clock(of store: VaultStore) throws -> HybridClock {
    try #require(try store.meta("clock").flatMap(HybridClock.init))
  }

  private func sync(_ apps: [FakeApp], rounds: Int = 3) {
    for _ in 0..<rounds {
      for app in apps {
        app.push(cloud)
        app.pull(cloud)
      }
    }
  }

  private func expectSame(_ apps: [FakeApp], id: String, _ values: [String: JSONValue], sourceLocation: SourceLocation = #_sourceLocation) throws {
    for app in apps {
      #expect(try app.store.item(id: id)?.values == values, "\(app.store.deviceID)", sourceLocation: sourceLocation)
    }
    let fields = try apps.map { try #require(try $0.store.item(id: id)).fields }
    #expect(Set(fields).count == 1, sourceLocation: sourceLocation)
  }

  private func isSane(_ store: VaultStore, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let limit = Date.now.addingTimeInterval(VaultStore.clockSkewBound + 60).timeIntervalSince1970 * 1000
    // No clock at all is fine: it saw none it should follow.
    guard let clock = try store.meta("clock").flatMap(HybridClock.init) else { return }
    #expect(Double(clock.millis) < limit, "\(store.deviceID)", sourceLocation: sourceLocation)
  }

  @Test func threeDevicesConvergeAndLocalClocksStaySane() throws {
    let a = try device("a")
    let b = try device("b")
    let future = try device("future", offset: 60 * year)
    let apps = [a, b, future]

    try a.store.save(id: "host", kind: "host", changes: ["name": "prod", "port": 22])
    sync(apps)
    // The fast device's edit has a clock decades ahead. Every device keeps it, and none but its writer follows it.
    try future.store.save(id: "host", kind: "host", changes: ["name": "from the future"])
    sync(apps)
    try expectSame(apps, id: "host", ["name": "from the future", "port": 22])
    try isSane(a.store)
    try isSane(b.store)

    // A normal write elsewhere keeps a normal clock.
    try a.store.save(id: "other", kind: "host", changes: ["name": "other"])
    try isSane(a.store)
    #expect(try a.store.item(id: "other")!.fields.latestClock.millis < Int64(Date.now.addingTimeInterval(60).timeIntervalSince1970 * 1000))

    // Editing the field it holds beats it, on every device, and the store's own clock doesn't move.
    try b.store.save(id: "host", kind: "host", changes: ["name": "from b"])
    try isSane(b.store)
    sync(apps)
    try expectSame(apps, id: "host", ["name": "from b", "port": 22])

    // The fast device isn't shut out either: it writes over b's edit, having seen it.
    try future.store.save(id: "host", kind: "host", changes: ["name": "from the future again"])
    sync(apps)
    try expectSame(apps, id: "host", ["name": "from the future again", "port": 22])
    try isSane(a.store)
    try isSane(b.store)

    // Two edits of the same field by devices that haven't seen each other's: one wins, the same one everywhere.
    try a.store.save(id: "host", kind: "host", changes: ["name": "race a"])
    try future.store.save(id: "host", kind: "host", changes: ["name": "race future"])
    sync(apps)
    let name = try a.store.item(id: "host")?.values["name"]
    #expect(name != nil)
    try expectSame(apps, id: "host", ["name": name!, "port": 22])
  }

  @Test func aSlowDeviceKeepsItsOwnEdits() throws {
    let a = try device("a")
    let slow = try device("slow", offset: -2 * year)
    let apps = [a, slow]
    try a.store.save(id: "host", kind: "host", changes: ["name": "prod", "port": 22])
    sync(apps)
    // Everything it has seen looks ahead of its clock, and its edits still replace what it saw.
    try slow.store.save(id: "host", kind: "host", changes: ["name": "edited on the slow device"])
    #expect(try slow.store.item(id: "host")?.values["name"] == "edited on the slow device")
    sync(apps)
    try expectSame(apps, id: "host", ["name": "edited on the slow device", "port": 22])
    // Its delete takes, though the item's clocks are ahead of it, and so does bringing it back.
    try slow.store.delete(id: "host")
    sync(apps)
    #expect(try a.store.item(id: "host")?.isDeleted == true)
    try slow.store.save(id: "host", kind: "host", changes: ["name": "back again"])
    sync(apps)
    #expect(try a.store.item(id: "host")?.isDeleted == false)
    #expect(try a.store.item(id: "host")?.values["name"] == "back again")
  }

  @Test func aTombstoneFarAheadDoesntKeepAnItemDeleted() throws {
    let a = try device("a")
    let future = try device("future", offset: 60 * year)
    let apps = [a, future]
    try a.store.save(id: "host", kind: "host", changes: ["name": "prod"])
    sync(apps)
    try future.store.delete(id: "host")
    sync(apps)
    #expect(try a.store.item(id: "host")?.isDeleted == true)
    try a.store.save(id: "host", kind: "host", changes: ["name": "back"])
    sync(apps)
    for app in apps {
      #expect(try app.store.item(id: "host")?.isDeleted == false)
      #expect(try app.store.item(id: "host")?.values["name"] == "back")
    }
    try isSane(a.store)
  }

  @Test func aFieldFarAheadDoesntStopADelete() throws {
    let a = try device("a")
    let future = try device("future", offset: 60 * year)
    let apps = [a, future]
    try future.store.save(id: "host", kind: "host", changes: ["name": "prod"])
    sync(apps)
    try a.store.delete(id: "host")
    #expect(try a.store.item(id: "host")?.isDeleted == true)
    sync(apps)
    #expect(try future.store.item(id: "host")?.isDeleted == true)
    try isSane(a.store)
  }

  @Test func dataFromBeforeTheBoundIsntStranded() throws {
    // Written before this change: a far-future field in the store, and the store's own clock dragged along with it.
    let a = try device("a")
    let b = try device("b")
    let apps = [a, b]
    let far = HybridClock(millis: Int64(Date.now.addingTimeInterval(60 * year).timeIntervalSince1970 * 1000), counter: 7, device: "gone")
    try a.store.withLock {
      try a.store.writeRow(id: "host", kind: "host", fields: ItemFields(["name": StampedValue("stuck", clock: far)]), queue: true)
      try a.store.setMeta("clock", far.description)
    }
    sync(apps)
    try expectSame(apps, id: "host", ["name": "stuck"])
    try isSane(b.store)
    // The next write puts this store's clock right, and one to the old field beats it.
    try a.store.save(id: "elsewhere", kind: "host", changes: ["name": "x"])
    try isSane(a.store)
    try a.store.save(id: "host", kind: "host", changes: ["name": "unstuck"])
    sync(apps)
    try expectSame(apps, id: "host", ["name": "unstuck"])
    try isSane(a.store)
    try isSane(b.store)
  }

  @Test func theLastClockThereIsCanBeOvertaken() throws {
    // Nothing a record says can trap the arithmetic or leave a field that can't be written again.
    let a = try device("a")
    let b = try device("b")
    let apps = [a, b]
    let last = HybridClock(millis: .max, counter: .max, device: "zzz")
    try b.store.withLock {
      try b.store.writeRow(id: "host", kind: "host", fields: ItemFields(["name": StampedValue("held", clock: last)]), queue: true)
    }
    sync(apps)
    try expectSame(apps, id: "host", ["name": "held"])
    try isSane(a.store)
    try a.store.save(id: "host", kind: "host", changes: ["name": "taken back"])
    sync(apps)
    try expectSame(apps, id: "host", ["name": "taken back"])
    try a.store.delete(id: "host")
    sync(apps)
    #expect(try b.store.item(id: "host")?.isDeleted == true)
  }

  @Test func aClockAtTheBoundIsFollowedAndOnePastItIsnt() throws {
    let a = try device("a")
    let near = try device("near", offset: VaultStore.clockSkewBound / 2)
    let far = try device("far", offset: 3 * VaultStore.clockSkewBound)
    try near.store.save(id: "one", kind: "host", changes: ["name": "near"])
    near.push(cloud)
    a.pull(cloud)
    let followed = try clock(of: a.store)
    #expect(followed.device == "near")
    try far.store.save(id: "two", kind: "host", changes: ["name": "far"])
    far.push(cloud)
    a.pull(cloud)
    #expect(try clock(of: a.store) == followed)
    #expect(try a.store.item(id: "two")?.values["name"] == "far")
  }

  @Test func aClockCounterPastThirtyTwoBitsSurvivesItsText() {
    let clock = HybridClock(millis: 5, counter: Int(UInt32.max) + 3, device: "a")
    #expect(HybridClock(clock.description) == clock)
    let last = HybridClock(millis: .max, counter: .max, device: "a")
    #expect(HybridClock(last.description) == last)
    #expect(last.overtaken(by: "b") > last)
    #expect(last.overtaken(by: "b").overtaken(by: "b") > last.overtaken(by: "b"))
  }
}
