import Channel
import Foundation
import VaultKit

/// The `hub-vault` service on a connected Hub, as `HubSync` uses it. The Hub forwards the calls with this device as
/// the caller; the envelopes are sealed records it can't open.
struct HubVaultMailbox: HubMailbox {
  let client: ClientSender<Void>

  struct VaultBody: Encodable, Sendable { var vault: String }
  struct PushBody: Encodable, Sendable {
    var vault: String
    var envelopes: [HubEnvelope]
  }
  struct PullBody: Encodable, Sendable {
    var vault: String
    var after: Int
    var limit: Int
  }
  struct LeaveBody: Encodable, Sendable {
    var vault: String
    var device: String
  }
  struct AckBody: Encodable, Sendable {
    var vault: String
    var seq: Int
  }
  struct Joined: Decodable, Sendable {
    struct Member: Decodable, Sendable { var device: String }
    var last: Int
    var members: [Member]
  }
  struct Pulled: Decodable, Sendable {
    var envelopes: [HubDeliveredEnvelope]
    var last: Int
    var missed: Bool?
  }

  func join(vault: String) async throws -> HubMailboxJoin {
    let joined: Joined = try await client.send("vault/join", VaultBody(vault: vault))
    return HubMailboxJoin(last: joined.last, members: joined.members.map(\.device))
  }

  func push(vault: String, envelopes: [HubEnvelope]) async throws -> Int {
    try await client.send("vault/push", PushBody(vault: vault, envelopes: envelopes))
  }

  func pull(vault: String, after: Int, limit: Int) async throws -> HubMailboxPull {
    let pulled: Pulled = try await client.send("vault/pull", PullBody(vault: vault, after: after, limit: limit))
    return HubMailboxPull(envelopes: pulled.envelopes, last: pulled.last, missed: pulled.missed ?? false)
  }

  func ack(vault: String, seq: Int) async throws {
    let _: EmptyCodable? = try await client.send("vault/ack", AckBody(vault: vault, seq: seq))
  }

  func leave(vault: String, device: String) async throws {
    let _: EmptyCodable? = try await client.send("vault/leave", LeaveBody(vault: vault, device: device))
  }
}
