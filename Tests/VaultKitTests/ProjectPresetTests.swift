import Foundation
import Testing

@testable import VaultKit

/// Code's run presets kept in the vault (`VaultProjectPreset`): on the user's other devices, by project and order,
/// a rename on one device and a reorder on another both kept.
@MainActor
struct ProjectPresetTests {
  let personalKeys = MemoryKeyProvider()
  let database = FakeDatabase()

  init() { VaultSecrets.useInMemoryStore() }

  @Test func syncByProjectInOrder() throws {
    let mac = try FakeDevice("mac", personalKeys: personalKeys)
    let ipad = try FakeDevice("ipad", personalKeys: personalKeys)
    let git = "project-git"
    let second = VaultProjectPreset(
      projectID: git, name: "Build Git for Any iOS Device", action: "build", from: "local",
      project: "Git-Local.xcworkspace", scheme: "Git", target: "Any iOS Device", order: 1)
    let first = VaultProjectPreset(
      projectID: git, name: "Run Git on v57 iPhone", action: "run", from: "local", project: "Git-Local.xcworkspace",
      scheme: "Git", target: "v57 iPhone", order: 0)
    let other = VaultProjectPreset(
      projectID: "project-shell", name: "Run Shell", action: "run", from: "studio-mac", project: "", scheme: "Shell",
      target: "studio-mac")
    for preset in [second, first, other] { mac.vaults.personal.save(preset) }
    #expect(mac.vaults.personal.presets(of: git) == [first, second])

    mac.sync(database)
    ipad.sync(database)
    #expect(ipad.vaults.personal.presets(of: git) == [first, second])
    #expect(ipad.vaults.personal.presets(of: "project-shell") == [other])

    // Renamed on the Mac, reordered on the iPad: both stay.
    var renamed = first
    renamed.name = "Run on my phone"
    mac.vaults.personal.save(renamed)
    var moved = first
    moved.order = 2
    ipad.vaults.personal.save(moved)
    mac.sync(database)
    ipad.sync(database)
    mac.sync(database)
    for device in [mac, ipad] {
      let presets = device.vaults.personal.presets(of: git)
      #expect(presets.map(\.name) == ["Build Git for Any iOS Device", "Run on my phone"])
    }

    // Removed on the iPad: gone on the Mac.
    ipad.vaults.personal.delete(second)
    ipad.sync(database)
    mac.sync(database)
    #expect(mac.vaults.personal.presets(of: git).map(\.id) == [first.id])
  }
}
