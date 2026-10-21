import Foundation

/// A vault's mailbox on the user's Hub (the `hub-vault` service): devices push sealed records, pull what the others
/// pushed, and acknowledge it. `VaultHub` talks to the service; tests use a fake.
public protocol HubMailbox: Sendable {
  func join(vault: String) async throws -> HubMailboxJoin
  /// Returns the vault's last sequence number.
  func push(vault: String, envelopes: [HubEnvelope]) async throws -> Int
  func pull(vault: String, after: Int, limit: Int) async throws -> HubMailboxPull
  func ack(vault: String, seq: Int) async throws
}

public struct HubEnvelope: Sendable, Equatable, Codable {
  public var id: String
  /// Base64 of the sealed record (`HubSync.Sealed`): ciphertext under a vault key, which the Hub never has.
  public var payload: String

  public init(id: String, payload: String) {
    self.id = id
    self.payload = payload
  }
}

public struct HubDeliveredEnvelope: Sendable, Equatable, Codable {
  public var seq: Int
  public var id: String
  /// The sending device's id on the Hub.
  public var from: String
  public var payload: String

  public init(seq: Int, id: String, from: String, payload: String) {
    self.seq = seq
    self.id = id
    self.from = from
    self.payload = payload
  }
}

public struct HubMailboxJoin: Sendable, Equatable {
  public var last: Int
  /// The member devices' Hub ids.
  public var members: [String]

  public init(last: Int, members: [String]) {
    self.last = last
    self.members = members
  }
}

public struct HubMailboxPull: Sendable, Equatable {
  public var envelopes: [HubDeliveredEnvelope]
  public var last: Int
  /// Envelopes this device never got were dropped (it was away too long): it sends everything again.
  public var missed: Bool

  public init(envelopes: [HubDeliveredEnvelope], last: Int, missed: Bool = false) {
    self.envelopes = envelopes
    self.last = last
    self.missed = missed
  }
}

/// Vault records synced through the user's Hub, next to `CloudSync`: for devices without iCloud (Linux, Windows,
/// Android, a Mac on another Apple ID), and a device that has both carries changes between them.
///
/// Every sealed item goes up as an envelope when its version changed since it last went up; envelopes from the other
/// devices merge in field by field (`VaultStore.applyFromPeer`). It keeps its own account of what it sent and pulled
/// (engine state `hub-sync:<vault>`), so CloudKit's outbox is untouched. A new member device, or one that missed
/// envelopes, makes every device send everything again: merging is idempotent, so they converge.
///
/// The vault's id on the Hub is derived from the vault keys, the same on every device that has them.
public final class HubSync: @unchecked Sendable {
  public let store: VaultStore
  public let mailbox: any HubMailbox
  public let deviceID: String
  private let lock = NSLock()
  private var running = false

  /// What one envelope carries.
  struct Sealed: Codable {
    var id: String
    var keyID: String
    var payload: Data
  }

  struct State: Codable {
    /// The last sequence number pulled and acknowledged.
    var pulled = 0
    /// Each item's version as it last went up (or arrived: what came from a peer needn't go back).
    var sent: [String: Int64] = [:]
    /// The members when this device last synced.
    var members: [String] = []
  }

  public struct Result: Sendable, Equatable {
    public var sent = 0
    public var received = 0
    /// Everything was sent again (a new device, or envelopes were missed).
    public var resent = false
  }

  /// - Parameter deviceID: this device's id on the Hub (envelope ids are made unique with it).
  public init(store: VaultStore, mailbox: any HubMailbox, deviceID: String) {
    self.store = store
    self.mailbox = mailbox
    self.deviceID = deviceID
  }

  /// The vault's mailbox id.
  public func vaultID() throws -> String { try store.derivedID("hub-vault") }

  private var stateName: String { "hub-sync:\(deviceID)" }

  /// Joins the vault's mailbox, merges what the other devices sent, then sends what changed here. Overlapping calls
  /// return at once with nothing done.
  @discardableResult
  public func sync(batch: Int = 200) async throws -> Result {
    let start = lock.withLock { () -> Bool in
      if running { return false }
      running = true
      return true
    }
    guard start else { return Result() }
    defer { lock.withLock { running = false } }

    let vault = try vaultID()
    var state = loadState()
    var result = Result()
    let joined = try await mailbox.join(vault: vault)
    // A device that wasn't a member before needs everything: send it all again.
    if !Set(joined.members).isSubset(of: Set(state.members)) {
      state.sent = [:]
      result.resent = true
    }
    state.members = joined.members

    while true {
      let pulled = try await mailbox.pull(vault: vault, after: state.pulled, limit: batch)
      if pulled.missed, !result.resent {
        state.sent = [:]
        result.resent = true
      }
      for envelope in pulled.envelopes where envelope.from != deviceID {
        guard let data = Data(base64Encoded: envelope.payload),
          let sealed = try? JSONDecoder().decode(Sealed.self, from: data)
        else { continue }
        switch try store.applyFromPeer(id: sealed.id, keyID: sealed.keyID, payload: sealed.payload) {
        case .merged(let version, let hasNewerFields):
          // When the sender's copy has everything, the peers have it: it goes up again only once it changes here.
          if !hasNewerFields { state.sent[sealed.id] = version }
          result.received += 1
        case .unchanged(let version):
          if state.sent[sealed.id] == nil { state.sent[sealed.id] = version }
        case .undecryptable: break
        }
      }
      let highest = pulled.envelopes.map(\.seq).max() ?? state.pulled
      if highest > state.pulled {
        state.pulled = highest
        try await mailbox.ack(vault: vault, seq: highest)
      }
      saveState(state)
      if pulled.envelopes.count < batch { break }
    }

    let changed = try store.sealedRecords().filter { state.sent[$0.id] != $0.version }
    for chunk in stride(from: 0, to: changed.count, by: batch).map({ Array(changed[$0..<min($0 + batch, changed.count)]) }) {
      let envelopes = try chunk.map { record in
        let sealed = Sealed(id: record.id, keyID: record.keyID, payload: record.payload)
        return HubEnvelope(
          id: "\(deviceID):\(record.id):\(record.version)",
          payload: try JSONEncoder().encode(sealed).base64EncodedString())
      }
      _ = try await mailbox.push(vault: vault, envelopes: envelopes)
      for record in chunk { state.sent[record.id] = record.version }
      result.sent += chunk.count
      saveState(state)
    }
    return result
  }

  private func loadState() -> State {
    guard let data = try? store.engineState(stateName), let state = try? JSONDecoder().decode(State.self, from: data)
    else { return State() }
    return state
  }

  private func saveState(_ state: State) {
    try? store.setEngineState(try? JSONEncoder().encode(state), for: stateName)
  }
}
