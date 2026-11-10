import Foundation
import Testing

@testable import VaultKit

/// A device's "seen" (V-036): when it last ran a v57 app, not when its key was published.
struct DeviceSeenTests {
  let keys = MemoryKeyProvider()
  static let key = HubMirrorTests.otherKey + " iPad"

  init() { VaultSecrets.useInMemoryStore() }

  func store(_ device: String = "ipad") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  func published(_ store: VaultStore, updated: Date) throws {
    try store.save(VaultDeviceKey(id: store.deviceID, deviceName: "iPad", publicKey: Self.key, platform: "iOS", updated: updated))
  }

  @Test func markingWritesLastSeenAndKeepsThePublishedDate() throws {
    let store = try store()
    let published = Date(timeIntervalSince1970: 1_800_000_000)
    try self.published(store, updated: published)
    let now = published.addingTimeInterval(14 * 86400)
    #expect(try store.markDeviceSeen(now: now))
    let key = try #require(try store.record(VaultDeviceKey.self, id: "ipad"))
    #expect(key.lastSeen == now)
    #expect(key.updated == published)
    #expect(key.seen == now)
  }

  @Test func markingIsThrottledWithinADay() throws {
    let store = try store()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 8)))
    try published(store, updated: morning.addingTimeInterval(-86400 * 10))
    #expect(try store.markDeviceSeen(now: morning, calendar: calendar))
    // An hour later: nothing written.
    #expect(try !store.markDeviceSeen(now: morning.addingTimeInterval(3600), calendar: calendar))
    // Past the interval: written again.
    let afternoon = morning.addingTimeInterval(VaultDeviceKey.seenInterval + 60)
    #expect(try store.markDeviceSeen(now: afternoon, calendar: calendar))
    // Late, past the interval again; then twenty minutes later, a new day: written although within the interval.
    let lateNight = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 50)))
    #expect(try store.markDeviceSeen(now: lateNight, calendar: calendar))
    #expect(try store.markDeviceSeen(now: lateNight.addingTimeInterval(20 * 60), calendar: calendar))
  }

  @Test func nothingIsMarkedBeforeTheKeyIsPublished() throws {
    let store = try store()
    #expect(try !store.markDeviceSeen())
    #expect(try store.record(VaultDeviceKey.self, id: "ipad") == nil)
  }

  /// Publishing the key again (a rename, a new build, an older build) leaves `lastSeen` alone.
  @Test func savingTheKeyKeepsLastSeen() throws {
    let store = try store()
    try published(store, updated: Date(timeIntervalSince1970: 1_799_000_000))
    let seen = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try store.markDeviceSeen(now: seen))
    try published(store, updated: .now)
    try store.renameDevice("ipad", to: "Studio iPad")
    let key = try #require(try store.record(VaultDeviceKey.self, id: "ipad"))
    #expect(key.lastSeen == seen)
    #expect(key.deviceName == "Studio iPad")
  }

  @Test func aKeyWithoutLastSeenIsSeenWhenPublished() {
    let updated = Date(timeIntervalSince1970: 1_800_000_000)
    let key = VaultDeviceKey(id: "old", deviceName: "Old iPad", publicKey: Self.key, platform: "iOS", updated: updated)
    #expect(key.lastSeen == nil)
    #expect(key.seen == updated)
  }
}
