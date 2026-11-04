import Foundation
import Testing
import VaultKit

@testable import VaultUI

@MainActor
struct LostDeviceFlowTests {
  let store: VaultStore
  let vaults: Vaults
  let device = VaultDeviceKey(
    id: "lost", deviceName: "Lost Mac", publicKey: "ssh-ed25519 QUFBQQ== Lost Mac", platform: "macOS")
  let keysFile: VaultAuthorizedKeys

  init() throws {
    VaultSecrets.useInMemoryStore()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultUITests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try VaultStore(directory: directory, keys: MemoryKeyProvider(), deviceID: "mac", notifier: nil, owner: "test")
    try store.save(device)
    vaults = Vaults(personal: Vault(store: store))
    keysFile = VaultAuthorizedKeys(url: directory.appendingPathComponent("authorized_keys"))
    try keysFile.allow(device)
  }

  private func flow(_ actions: VaultLostDeviceActions = .init()) -> VaultLostDeviceFlow {
    VaultLostDeviceFlow(device: device, vaults: vaults, actions: actions, thisMac: keysFile)
  }

  private func settle(_ flow: VaultLostDeviceFlow, _ id: String) async throws {
    for _ in 0..<500 {
      if flow.state(id) != .working { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw CancellationError()
  }

  @Test func nothingHappensUntilAStepIsClicked() throws {
    var ran = false
    let flow = flow(.init(hubs: [.init(id: "h", name: "Hub", systemImage: "server.rack") {
      ran = true
      return "ok"
    }]))
    #expect(!ran)
    #expect(flow.progress.isEmpty)
    #expect(try store.isRevoked(device: "lost") == false)
    #expect(vaults.personal.deviceKeys.map(\.id) == ["lost"])
    #expect(try keysFile.allowedDevices(among: [device]) == ["lost"])
    #expect(try store.pendingIDs() == [device.id])
  }

  @Test func theStepsDoWhatTheySay() async throws {
    let flow = flow()
    flow.stopTrusting()
    try await settle(flow, VaultLostDeviceFlow.trust)
    #expect(try store.isRevoked(device: "lost"))
    #expect(vaults.personal.deviceKeys.isEmpty)

    flow.sweepThisMac()
    try await settle(flow, VaultLostDeviceFlow.thisMacSweep)
    #expect(try keysFile.entries().isEmpty)

    let before = try store.primaryKeyForTest()
    flow.rotateKeys()
    try await settle(flow, VaultLostDeviceFlow.rotate)
    guard case .done = flow.state(VaultLostDeviceFlow.rotate) else {
      Issue.record("\(flow.state(VaultLostDeviceFlow.rotate))")
      return
    }
    #expect(try store.primaryKeyForTest() != before)
  }

  private struct Boom: LocalizedError {
    var errorDescription: String? { "No route to host" }
  }

  /// A failed step says why, a retry can succeed, and any step can be skipped and brought back.
  @Test func aStepCanFailBeRetriedAndBeSkipped() async throws {
    let attempts = Attempts()
    let action = VaultLostDeviceActions.Action(id: "s", name: "Server", systemImage: "terminal") {
      if attempts.next() == 1 { throw Boom() }
      return "Took out 2 lines."
    }
    let flow = flow(.init(servers: [action]))
    flow.run(action)
    try await settle(flow, "s")
    #expect(flow.state("s") == .failed("No route to host"))
    flow.run(action)
    try await settle(flow, "s")
    #expect(flow.state("s") == .done("Took out 2 lines."))

    flow.skip("other")
    #expect(flow.state("other") == .skipped)
    flow.reset("other")
    #expect(flow.state("other") == .waiting)
  }

  @Test func oneClickSweepsWhatIsLeftAndOnlyThat() async throws {
    let attempts = Attempts()
    func server(_ id: String, unavailable: String? = nil) -> VaultLostDeviceActions.Action {
      .init(id: id, name: id, systemImage: "terminal", unavailable: unavailable) {
        _ = attempts.next()
        return "done"
      }
    }
    let flow = flow(.init(servers: [server("a"), server("b"), server("c", unavailable: "no"), server("d")]))
    flow.skip("b")
    flow.sweepAllServers()
    try await settle(flow, "a")
    try await settle(flow, "d")
    #expect(flow.state("a") == .done("done"))
    #expect(flow.state("b") == .skipped)
    #expect(flow.state("c") == .waiting)
    #expect(attempts.count == 2)
  }

  @Test func theAppleAccountStepIsTheUsersWord() {
    let flow = flow()
    #expect(!flow.leftAppleAccount)
    flow.skip(VaultLostDeviceFlow.appleAccount)
    #expect(!flow.leftAppleAccount)
    flow.confirmLeftAppleAccount()
    #expect(flow.leftAppleAccount)
  }

  @Test func itListsWhatToChangeByHand() throws {
    try store.save(VaultLogin(id: "l", title: "Example", website: "https://example.com", username: "me"))
    try store.save(VaultHost(id: "h", name: "prod", hostname: "prod.example.com", user: "me", auth: .password))
    vaults.personal.reload(force: true)
    let list = flow().secretsToChange
    #expect(list.map(\.title).contains("Logins"))
    #expect(list.first { $0.title == "Servers with a password" }?.names == ["prod"])
  }
}

final class Attempts: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func next() -> Int { lock.withLock { value += 1; return value } }
}

extension VaultStore {
  func primaryKeyForTest() throws -> String {
    try save(id: "probe", kind: "probe", changes: ["at": .string(UUID().uuidString)])
    return try sealedRecords().first { $0.id == "probe" }?.keyID ?? ""
  }
}
