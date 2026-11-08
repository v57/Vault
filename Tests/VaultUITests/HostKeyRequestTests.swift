import Foundation
import Testing
import VaultKit

@testable import VaultUI

/// `VaultHostKeyRequest`: a question to answer before a login goes on, and a no when nobody can answer.
@MainActor
struct HostKeyRequestTests {
  let vault: Vault
  let store: VaultStore
  let host = VaultHost(id: "h", name: "prod", hostname: "prod.example.com", user: "me")

  init() throws {
    VaultSecrets.useInMemoryStore()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VaultUITests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try VaultStore(directory: directory, keys: MemoryKeyProvider(), deviceID: "mac", notifier: nil, owner: "test")
    vault = Vault(store: store)
  }

  private func waitForQuestion(_ request: VaultHostKeyRequest) async throws -> VaultHostKeyRequest.Pending {
    for _ in 0..<500 {
      if let pending = request.pending { return pending }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
  }

  /// A login that comes from nowhere a person can see isn't trusted by default, and doesn't wait.
  @Test func noWindowMeansNo() async throws {
    let request = VaultHostKeyRequest()
    #expect(await !request.approve("SHA256:a", for: host, in: vault))
    #expect(try store.knownFingerprint(for: host) == nil)
  }

  @Test func aYesPinsTheKeyOnTheHostsRoute() async throws {
    let request = VaultHostKeyRequest()
    request.windowAppeared()
    let hubHost = VaultHost(
      id: "hub", hostname: "100.96.0.4", hub: .init(hubID: "hub1", deviceID: "studio", deviceName: "Studio"))
    let asking = Task { await request.approve("SHA256:a", keyType: "ECDSA P-256", for: hubHost, in: vault) }
    let question = try await waitForQuestion(request)
    #expect(question.fingerprint == "SHA256:a" && question.address == "100.96.0.4")
    #expect(try store.knownFingerprint(for: hubHost) == nil)
    request.finish(question.id, accepted: true)
    #expect(await asking.value)
    #expect(try store.knownFingerprint(for: hubHost) == "SHA256:a")
    #expect(try store.knownFingerprint(host: "100.96.0.4", port: 22) == nil)
  }

  /// Security audit M6: another key than the pinned one is refused without a first-connection question, and nothing
  /// is re-pinned; once the pin is forgotten, the next connection asks again.
  @Test func aChangedKeyIsRefusedWithoutAsking() async throws {
    let request = VaultHostKeyRequest()
    request.windowAppeared()
    try store.trust(fingerprint: "SHA256:a", for: host)
    try store.trust(fingerprint: "SHA256:git", host: "git.example.com", port: 22)
    #expect(await !request.approve("SHA256:b", for: host, in: vault))
    #expect(await !request.approve("SHA256:b", host: "git.example.com", port: 22, in: vault))
    #expect(request.questions.isEmpty)
    #expect(try store.knownFingerprint(for: host) == "SHA256:a")
    #expect(await request.approve("SHA256:a", for: host, in: vault))

    try store.untrust(fingerprint: "SHA256:a", for: host)
    let asking = Task { await request.approve("SHA256:b", for: host, in: vault) }
    request.finish(try await waitForQuestion(request).id, accepted: true)
    #expect(await asking.value)
    #expect(try store.knownFingerprint(for: host) == "SHA256:b")
  }

  @Test func aNoPinsNothing() async throws {
    let request = VaultHostKeyRequest()
    request.windowAppeared()
    let asking = Task { await request.approve("SHA256:a", for: host, in: vault) }
    request.finish(try await waitForQuestion(request).id, accepted: false)
    #expect(await !asking.value)
    #expect(try store.knownFingerprint(for: host) == nil)
  }

  /// Build, Test and the file list start at once: one question for the server, and everyone gets its answer.
  @Test func loginsToOneServerShareAQuestion() async throws {
    let request = VaultHostKeyRequest()
    request.windowAppeared()
    let first = Task { await request.approve("SHA256:a", for: host, in: vault) }
    let question = try await waitForQuestion(request)
    let second = Task { await request.approve("SHA256:a", for: host, in: vault) }
    for _ in 0..<500 where request.pending?.waiters.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(request.questions.count == 1)
    request.finish(question.id, accepted: true)
    #expect(await first.value)
    #expect(await second.value)
  }

  /// Another key at the same server is another question: a yes to one isn't a yes to the other.
  @Test func anotherKeyIsAnotherQuestion() async throws {
    let request = VaultHostKeyRequest()
    request.windowAppeared()
    let first = Task { await request.ask(name: "a", address: "a", port: 22, fingerprint: "SHA256:a") }
    let question = try await waitForQuestion(request)
    let second = Task { await request.ask(name: "a", address: "a", port: 22, fingerprint: "SHA256:b") }
    for _ in 0..<500 where request.questions.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
    request.finish(question.id, accepted: true)
    #expect(await first.value)
    let next = try #require(request.pending)
    #expect(next.fingerprint == "SHA256:b")
    request.finish(next.id, accepted: false)
    #expect(await !second.value)
  }

  /// SSHKit gave up waiting: the question goes away instead of pinning a key for a login that's over.
  @Test func cancellingWithdrawsTheQuestion() async throws {
    let request = VaultHostKeyRequest()
    request.windowAppeared()
    let asking = Task { await request.ask(name: "a", address: "a", port: 22, fingerprint: "SHA256:a") }
    _ = try await waitForQuestion(request)
    asking.cancel()
    #expect(await !asking.value)
    for _ in 0..<500 where request.pending != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(request.pending == nil)
  }

  @Test func theLastWindowClosingSaysNo() async throws {
    let request = VaultHostKeyRequest()
    request.windowAppeared()
    let asking = Task { await request.ask(name: "a", address: "a", port: 22, fingerprint: "SHA256:a") }
    _ = try await waitForQuestion(request)
    request.windowDisappeared()
    #expect(await !asking.value)
  }
}
