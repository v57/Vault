import Foundation
import Testing

@testable import VaultKit

/// Each device labelled by its own system (V-037): an iPhone and an iPad are both `platform` "iOS".
struct DeviceModelTests {
  let keys = MemoryKeyProvider()
  static let key = HubMirrorTests.otherKey + " iPhone"

  init() { VaultSecrets.useInMemoryStore() }

  func store(_ device: String = "phone") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  @Test func theSystemNameFollowsTheModel() {
    func key(_ name: String, platform: String = "iOS", model: String? = nil) -> VaultDeviceKey {
      VaultDeviceKey(id: name, deviceName: name, publicKey: Self.key, platform: platform, model: model)
    }
    #expect(key("iPhone", model: "iPhone").systemName == "iOS")
    #expect(key("Kitchen", model: "iPad").systemName == "iPadOS")
    #expect(key("Studio", platform: "macOS", model: "Mac").systemName == "macOS")
    // Older builds don't say: an iPad goes by its name, anything else on iOS is an iPhone.
    #expect(key("iPad").systemName == "iPadOS")
    #expect(key("iPhone").systemName == "iOS")
    #expect(key("Pocket").systemName == "iOS")
    #expect(key("box", platform: "linux").systemName == "Linux")
  }

  @Test func theModelIsKeptByASaveThatDoesNotKnowIt() throws {
    let store = try store()
    try store.save(VaultDeviceKey(id: "phone", deviceName: "iPhone", publicKey: Self.key, platform: "iOS", model: "iPhone"))
    try store.save(VaultDeviceKey(id: "phone", deviceName: "iPhone", publicKey: Self.key, platform: "iOS"))
    #expect(try store.record(VaultDeviceKey.self, id: "phone")?.model == "iPhone")
  }

  /// A key an older build published gets its model the next time the device notes it ran, throttled or not.
  @Test func markingSeenFillsAMissingModel() throws {
    let store = try store()
    try store.save(VaultDeviceKey(id: "phone", deviceName: "iPhone", publicKey: Self.key, platform: "iOS"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try store.markDeviceSeen(now: now))
    #expect(try store.markDeviceSeen(now: now.addingTimeInterval(60), model: "iPhone"))
    let key = try #require(try store.record(VaultDeviceKey.self, id: "phone"))
    #expect(key.model == "iPhone")
    #expect(key.lastSeen == now)
    #expect(try !store.markDeviceSeen(now: now.addingTimeInterval(120), model: "iPhone"))
  }
}
