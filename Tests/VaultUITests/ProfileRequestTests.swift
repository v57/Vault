import Foundation
import Testing
import VaultKit

@testable import VaultUI

/// `VaultProfileRequest`: the sheet only while the profile is incomplete, one answer per sheet.
@MainActor
struct ProfileRequestTests {
  let vaults: Vaults

  init() throws {
    VaultSecrets.useInMemoryStore()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultUITests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try VaultStore(directory: directory, keys: MemoryKeyProvider(), deviceID: "mac", notifier: nil, owner: "test")
    vaults = Vaults(personal: Vault(store: store), stores: VaultAccountStores(personal: store, notifier: nil))
  }

  @Test func aCompleteProfileComesBackWithoutTheSheet() async {
    vaults.save(VaultProfile(account: "personal", name: "Ada", email: "ada@example.com"))
    let request = VaultProfileRequest()
    let profile = await request.profile(for: .personal, vaults: vaults)
    #expect(profile?.signature == "Ada <ada@example.com>")
    #expect(request.pending == nil)
  }

  @Test func anIncompleteOneShowsTheSheetAndWaitsForItsAnswer() async throws {
    let request = VaultProfileRequest()
    let asking = Task { await request.profile(for: .personal, vaults: vaults, reason: "For this commit.") }
    while request.pending == nil { await Task.yield() }
    #expect(request.pending?.reason == "For this commit.")

    // A second request while the sheet is up doesn't stack another sheet.
    #expect(await request.profile(for: .personal, vaults: vaults) == nil)

    let saved = VaultProfile(account: "personal", name: "Ada", email: "ada@example.com")
    vaults.save(saved)
    request.finish(VaultProfileAnswer(profile: saved, option: false))
    request.finish(nil)  // the sheet's dismissal after Save: already answered
    #expect(await asking.value == saved)
    #expect(request.pending == nil)
    // Saved once, never asked again.
    #expect(await request.profile(for: .personal, vaults: vaults) == saved)
  }

  @Test func cancellingAnswersNil() async {
    let request = VaultProfileRequest()
    let asking = Task { await request.profile(for: .personal, vaults: vaults) }
    while request.pending == nil { await Task.yield() }
    request.finish(nil)
    #expect(await asking.value == nil)
    #expect(vaults.profile(for: .personal).isComplete == false)
  }

  let terminal = VaultProfileOption(
    title: "Use in Terminal too", help: "Writes them to ~/.gitconfig.", systemImage: "terminal",
    accept: "Use in Terminal", decline: "Only in Git")

  @Test func theSheetShowsTheOptionAndPassesItsAnswer() async {
    let request = VaultProfileRequest()
    let asking = Task { await request.answer(for: .personal, vaults: vaults, option: terminal) }
    while request.pending == nil { await Task.yield() }
    #expect(request.pending?.saved == nil)  // the Your Name sheet, with the switch
    let saved = VaultProfile(account: "personal", name: "Ada", email: "ada@example.com")
    request.finish(VaultProfileAnswer(profile: saved, option: true))
    #expect(await asking.value == VaultProfileAnswer(profile: saved, option: true))
  }

  @Test func aSavedProfileAsksOnlyTheOption() async {
    let saved = VaultProfile(account: "personal", name: "Ada", email: "ada@example.com")
    vaults.save(saved)
    let request = VaultProfileRequest()
    #expect(await request.answer(for: .personal, vaults: vaults, option: nil) == VaultProfileAnswer(profile: saved, option: false))

    let asking = Task { await request.answer(for: .personal, vaults: vaults, option: terminal) }
    while request.pending == nil { await Task.yield() }
    #expect(request.pending?.saved == saved)  // the confirmation
    request.finish(nil)  // dismissed: a no, the profile still comes back
    #expect(await asking.value == VaultProfileAnswer(profile: saved, option: false))
  }
}
