import Foundation
import Observation
import Testing

@testable import VaultKit

/// What views of the vault follow: its revision (V-035).
struct VaultObservationTests {
  let keys = MemoryKeyProvider()

  init() { VaultSecrets.useInMemoryStore() }

  func store(device: String = "mac") throws -> VaultStore {
    try VaultStore(directory: temporaryDirectory(), keys: keys, deviceID: device, notifier: nil, owner: device)
  }

  /// A note isn't in the vault's lists, so the sidebar's count follows the revision: a save here must change it.
  @MainActor @Test func aSavedNoteChangesTheObservedRevision() throws {
    let vault = Vault(store: try store())
    let before = vault.revision
    let changed = Flag()
    withObservationTracking { _ = vault.revision } onChange: { changed.value = true }
    vault.save(VaultNote(folder: "Vault", name: "Wi-Fi", encrypted: false, text: "hunter2"))
    #expect(changed.value)
    #expect(vault.revision != before)
  }

  /// A change written to the store by someone else (sync, another app) reaches observers on the next reload, and a
  /// reload that finds nothing new leaves them alone.
  @MainActor @Test func aChangeFromElsewhereChangesTheRevisionOnReload() throws {
    let store = try store()
    let vault = Vault(store: store)
    try store.save(VaultNote(folder: "Vault", name: "Synced", encrypted: false, text: "from the iPad"))
    let changed = Flag()
    withObservationTracking { _ = vault.revision } onChange: { changed.value = true }
    vault.reload()
    #expect(changed.value)
    #expect(vault.revision == store.revision)

    changed.value = false
    withObservationTracking { _ = vault.revision } onChange: { changed.value = true }
    vault.reload()
    #expect(!changed.value)
  }

  @MainActor @Test func lastSyncedIsNilWithoutSync() throws {
    let vault = Vault(store: try store())
    #expect(vault.lastSynced == nil)
    #expect(vault.personalVault.lastSynced == nil)
  }
}

/// Whether an observation fired (its closure is `@Sendable`).
private final class Flag: @unchecked Sendable {
  var value = false
}
