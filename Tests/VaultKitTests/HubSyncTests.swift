import Foundation
import Testing

@testable import VaultKit

/// hub-vault's rules, in memory: members, a log with sequence numbers, envelope ids stored once, pruning once every
/// other member acknowledged, and `missed` after envelopes were dropped.
final class FakeMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var members: [String: Int] = [:]
  private var log: [HubDeliveredEnvelope] = []
  private var next = 1
  private var expiredTo = 0
  private(set) var pushes = 0
  /// Which device each call comes from (the hub tells the service; here each device gets a view).
  func device(_ id: String) -> HubMailbox { View(box: self, device: id) }

  var waiting: Int { lock.withLock { log.count } }

  /// Drops every envelope, as retention would.
  func expireAll() {
    lock.withLock {
      expiredTo = next - 1
      log = []
    }
  }

  struct View: HubMailbox {
    let box: FakeMailbox
    let device: String
    func join(vault: String) async throws -> HubMailboxJoin { box.join(device) }
    func push(vault: String, envelopes: [HubEnvelope]) async throws -> Int { box.push(device, envelopes) }
    func pull(vault: String, after: Int, limit: Int) async throws -> HubMailboxPull { box.pull(device, after, limit) }
    func ack(vault: String, seq: Int) async throws { box.ack(device, seq) }
  }

  func join(_ device: String) -> HubMailboxJoin {
    lock.withLock {
      if members[device] == nil { members[device] = 0 }
      return HubMailboxJoin(last: next - 1, members: members.keys.sorted())
    }
  }

  func push(_ device: String, _ envelopes: [HubEnvelope]) -> Int {
    lock.withLock {
      pushes += 1
      // An id is stored once while its envelope waits, as hub-vault's unique (vault, id).
      for envelope in envelopes where !log.contains(where: { $0.id == envelope.id }) {
        log.append(HubDeliveredEnvelope(seq: next, id: envelope.id, from: device, payload: envelope.payload))
        next += 1
      }
      return next - 1
    }
  }

  func pull(_ device: String, _ after: Int, _ limit: Int) -> HubMailboxPull {
    lock.withLock {
      let acked = members[device] ?? 0
      let envelopes = log.filter { $0.seq > after && $0.from != device }.prefix(limit)
      return HubMailboxPull(envelopes: Array(envelopes), last: next - 1, missed: expiredTo > max(acked, after))
    }
  }

  func ack(_ device: String, _ seq: Int) {
    lock.withLock {
      members[device] = max(members[device] ?? 0, seq)
      log.removeAll { envelope in
        members.allSatisfy { member, acked in member == envelope.from || acked >= envelope.seq }
      }
    }
  }
}

struct HubSyncTests {
  let keys = MemoryKeyProvider()
  let mailbox = FakeMailbox()

  init() { VaultSecrets.useInMemoryStore() }

  /// A device on the Hub: its store and its HubSync.
  func device(_ name: String, directory: URL = temporaryDirectory()) throws -> (store: VaultStore, sync: HubSync) {
    let store = try VaultStore(directory: directory, keys: keys, deviceID: name, notifier: nil, owner: "\(name).app")
    return (store, HubSync(store: store, mailbox: mailbox.device("hub-\(name)"), deviceID: "hub-\(name)"))
  }

  @Test func devicesExchangeRecordsThroughTheHub() async throws {
    let mac = try device("mac")
    let linux = try device("linux")
    try await mac.sync.sync()
    try await linux.sync.sync()
    try mac.store.save(VaultHost(id: "h1", name: "prod", hostname: "prod.example.com"))
    #expect(try await mac.sync.sync().sent == 1)
    let received = try await linux.sync.sync()
    #expect(received.received == 1)
    #expect(try linux.store.record(VaultHost.self, id: "h1")?.hostname == "prod.example.com")
    // Nothing new: nothing goes up or comes back.
    #expect(try await linux.sync.sync() == HubSync.Result())
    #expect(try await mac.sync.sync() == HubSync.Result())
    #expect(mailbox.waiting == 0)
  }

  @Test func concurrentEditsMergeFieldByField() async throws {
    let mac = try device("mac")
    let linux = try device("linux")
    try mac.store.save(id: "h1", kind: "host", changes: ["name": "prod", "port": 22])
    try await mac.sync.sync()
    try await linux.sync.sync()

    try mac.store.save(id: "h1", kind: "host", changes: ["port": 2222])
    try linux.store.save(id: "h1", kind: "host", changes: ["name": "Production"])
    try await mac.sync.sync()
    try await linux.sync.sync()
    try await mac.sync.sync()

    let expected: [String: JSONValue] = ["name": "Production", "port": 2222]
    #expect(try mac.store.item(id: "h1")?.values == expected)
    #expect(try linux.store.item(id: "h1")?.values == expected)
    // Settled: another round moves nothing.
    #expect(try await mac.sync.sync().sent == 0)
    #expect(try await linux.sync.sync().sent == 0)
  }

  @Test func deletionsTravel() async throws {
    let mac = try device("mac")
    let linux = try device("linux")
    try mac.store.save(VaultHost(id: "h1", hostname: "a"))
    try await mac.sync.sync()
    try await linux.sync.sync()
    try linux.store.delete(id: "h1")
    try await linux.sync.sync()
    try await mac.sync.sync()
    #expect(try mac.store.record(VaultHost.self, id: "h1") == nil)
  }

  @Test func aNewDeviceGetsEverything() async throws {
    let mac = try device("mac")
    let linux = try device("linux")
    for index in 0..<5 { try mac.store.save(VaultHost(id: "h\(index)", hostname: "host\(index)")) }
    try await mac.sync.sync()
    try await linux.sync.sync()
    #expect(mailbox.waiting == 0)

    // The envelopes are gone once everyone had them; a device joining now still gets the records: the others see
    // a new member and send everything again.
    let pad = try device("pad")
    try await pad.sync.sync()
    let resend = try await mac.sync.sync()
    #expect(resend.resent && resend.sent == 5)
    try await pad.sync.sync()
    #expect(try pad.store.records(VaultHost.self).count == 5)
  }

  @Test func aDeviceThatMissedEnvelopesResends() async throws {
    let mac = try device("mac")
    let linux = try device("linux")
    try mac.store.save(VaultHost(id: "h1", hostname: "a"))
    try await mac.sync.sync()
    try await linux.sync.sync()
    try mac.store.save(VaultHost(id: "h2", hostname: "b"))
    try await mac.sync.sync()
    mailbox.expireAll()
    let result = try await linux.sync.sync()
    #expect(result.resent)
    #expect(result.sent == 1)
  }

  /// A Mac with both: what arrives from the Hub goes into the outbox, so its CloudKit sync carries it to the
  /// iPhone, and the iPhone's iCloud change reaches the Hub-only Linux machine through the Mac.
  @Test func aDeviceWithBothBridgesCloudKitAndTheHub() async throws {
    let cloud = FakeCloud()
    let macDirectory = temporaryDirectory()
    let mac = try device("mac", directory: macDirectory)
    let macCloud = try FakeApp(directory: macDirectory, keys: keys, device: "mac", name: "mac.app")
    let phone = try FakeApp(directory: temporaryDirectory(), keys: keys, device: "phone", name: "phone.app")
    let linux = try device("linux")

    try linux.store.save(VaultHost(id: "from-linux", hostname: "linux"))
    try await linux.sync.sync()
    try await mac.sync.sync()
    macCloud.sync(cloud)
    phone.sync(cloud)
    #expect(try phone.store.record(VaultHost.self, id: "from-linux")?.hostname == "linux")

    try phone.store.save(VaultHost(id: "from-phone", hostname: "phone"))
    phone.sync(cloud)
    macCloud.sync(cloud)
    try await mac.sync.sync()
    try await linux.sync.sync()
    #expect(try linux.store.record(VaultHost.self, id: "from-phone")?.hostname == "phone")
    // CloudKit's bookkeeping survived the Hub's merges: nothing is stuck in the Mac's outbox.
    #expect(try macCloud.store.pendingCount() == 0)
  }

  /// A Hub that holds the call and never answers (hub-server queues calls it can't forward yet): the sync says so
  /// instead of hanging, and goes on once the Hub answers again.
  @Test func aHubThatNeverAnswersTimesOut() async throws {
    struct Stuck: HubMailbox {
      let box: FakeMailbox
      let device: String
      let stuck: @Sendable () -> Bool
      func join(vault: String) async throws -> HubMailboxJoin {
        if stuck() { try await Task.sleep(for: .seconds(3600)) }
        return box.join(device)
      }
      func push(vault: String, envelopes: [HubEnvelope]) async throws -> Int { box.push(device, envelopes) }
      func pull(vault: String, after: Int, limit: Int) async throws -> HubMailboxPull { box.pull(device, after, limit) }
      func ack(vault: String, seq: Int) async throws { box.ack(device, seq) }
    }
    final class Flag: @unchecked Sendable { var on = true }
    let flag = Flag()
    let store = try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: "mac", notifier: nil, owner: "mac.app")
    try store.save(VaultHost(id: "h1", hostname: "a"))
    let sync = HubSync(
      store: store, mailbox: Stuck(box: mailbox, device: "hub-mac", stuck: { flag.on }), deviceID: "hub-mac",
      timeout: .milliseconds(200))
    let started = ContinuousClock.now
    await #expect(throws: HubSync.TimedOut(call: "join")) { try await sync.sync() }
    #expect(ContinuousClock.now - started < .seconds(5))
    flag.on = false
    #expect(try await sync.sync().sent == 1)
  }

  @Test func theHubOnlySeesCiphertext() async throws {
    let mac = try device("mac")
    let peer = mailbox.device("observer")
    _ = try await peer.join(vault: "any")
    try mac.store.save(VaultLogin(id: "l1", title: "Bank", website: "bank.example.com", username: "secret-user"))
    try await mac.sync.sync()
    let seen = try await peer.pull(vault: "any", after: 0, limit: 100).envelopes.map(\.payload).joined()
    let decoded = seen.split(separator: " ").compactMap { Data(base64Encoded: String($0)) }
    let text = String(decoding: decoded.joined(), as: UTF8.self) + seen
    #expect(!text.contains("secret-user"))
    #expect(!text.contains("bank.example.com"))
  }
}
