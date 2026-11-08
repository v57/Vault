import ComponentKit
import Observation
import SwiftUI
import VaultKit

/// Asks whether to trust a server's SSH key the first time an app meets it, for every app: `approve` is what a
/// login's `SSHHostTrust.ask` calls, after the handshake and before any password or signature leaves. A yes pins the
/// key for every app; a no ends the login. Show it with `.vaultHostKeyRequests()` on the window's root view. With
/// no window showing it there's no one to ask, so the answer is no.
///
/// ```swift
/// SSHServer(host: host.hostname, port: host.port, user: host.user, key: key, trust: .known(known, otherwise: .ask { key in
///   await VaultHostKeyRequest.shared.approve(key.fingerprint, keyType: key.type, for: host, in: vault)
/// }))
/// ```
@MainActor @Observable
public final class VaultHostKeyRequest {
  public static let shared = VaultHostKeyRequest()

  /// A question on screen or waiting its turn: one per server and key, however many logins wait for its answer.
  struct Pending: Identifiable {
    let id = UUID()
    var name: String
    var address: String
    var port: Int
    var fingerprint: String
    var keyType: String?
    var waiters: [UUID: CheckedContinuation<Bool, Never>]
  }

  private(set) var questions: [Pending] = []
  /// The windows showing the requests.
  private var windows = 0

  public init() {}

  var pending: Pending? { questions.first }

  /// Asks about a saved host's key, unless it's already trusted, and pins it on a yes. A host with another key pinned is
  /// refused without asking (security audit M6): the question is for a first connection, and a changed key is the
  /// user's to clear in Vault (the host's Known host ▸ Forget Key) once they know why it changed.
  public func approve(_ fingerprint: String, keyType: String? = nil, for host: VaultHost, in vault: Vault) async -> Bool {
    if let known = vault.knownHost(for: host)?.fingerprint { return known == fingerprint }
    guard
      await ask(name: host.displayName, address: host.hostname, port: host.port, fingerprint: fingerprint, keyType: keyType)
    else { return false }
    if let store = vault.trustStore(for: host) {
      vault.perform { _ in try store.trust(fingerprint: fingerprint, for: host, keyType: keyType) }
    }
    return true
  }

  /// Asks about the key of an address that's no saved host (a Git remote), and pins it on a yes. Another pinned key is
  /// refused without asking, as above.
  public func approve(_ fingerprint: String, keyType: String? = nil, host: String, port: Int, in vault: Vault) async -> Bool {
    if let known = try? vault.store?.knownFingerprint(host: host, port: port) { return known == fingerprint }
    guard await ask(name: host, address: host, port: port, fingerprint: fingerprint, keyType: keyType) else { return false }
    vault.perform { try $0.trust(fingerprint: fingerprint, host: host, port: port, keyType: keyType) }
    return true
  }

  /// Just the question, for a caller that saves the key itself (Shell's sessions). False right away when no window
  /// can show it. Cancelling the task takes this login's interest away, and the question with it if it was the last.
  public func ask(name: String, address: String, port: Int, fingerprint: String, keyType: String? = nil) async -> Bool {
    guard windows > 0 else { return false }
    let waiter = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        if let index = questions.firstIndex(where: {
          $0.address == address && $0.port == port && $0.fingerprint == fingerprint
        }) {
          questions[index].waiters[waiter] = continuation
        } else {
          questions.append(
            Pending(
              name: name, address: address, port: port, fingerprint: fingerprint, keyType: keyType,
              waiters: [waiter: continuation]))
        }
      }
    } onCancel: {
      Task { @MainActor in self.withdraw(waiter) }
    }
  }

  /// Answers one question and everyone waiting on it. Runs once per question.
  func finish(_ id: UUID, accepted: Bool) {
    guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
    let question = questions.remove(at: index)
    for waiter in question.waiters.values { waiter.resume(returning: accepted) }
  }

  private func withdraw(_ waiter: UUID) {
    guard let index = questions.firstIndex(where: { $0.waiters[waiter] != nil }) else { return }
    questions[index].waiters.removeValue(forKey: waiter)?.resume(returning: false)
    if questions[index].waiters.isEmpty { questions.remove(at: index) }
  }

  func windowAppeared() { windows += 1 }

  /// With the last window gone nobody can answer what's still waiting.
  func windowDisappeared() {
    windows -= 1
    guard windows <= 0 else { return }
    for question in questions { finish(question.id, accepted: false) }
  }
}

extension View {
  /// Shows `VaultHostKeyRequest`'s questions over this window (put it inside `componentKit()`, on every window that
  /// can start a connection).
  public func vaultHostKeyRequests(_ request: VaultHostKeyRequest = .shared) -> some View {
    modifier(HostKeyRequests(request: request))
  }
}

private struct HostKeyRequests: ViewModifier {
  let request: VaultHostKeyRequest

  func body(content: Content) -> some View {
    let question = request.pending
    let id = question?.id
    content
      .kitDialog(
        "Trust this server's key?",
        isPresented: Binding(
          get: { question != nil },
          // Cancel and a click on the dim say no. Trust answers first, so this finds nothing left to answer.
          set: { shown in if !shown, let id { request.finish(id, accepted: false) } }),
        message: question.map { question in
          let place = question.name == question.address ? question.address : "\(question.name) (\(question.address))"
          let port = question.port == 22 ? "" : " on port \(question.port)"
          return "This is the first connection to \(place)\(port). Nothing has been sent to it yet. Trust it only if this is its key: anyone on the network could be answering in its place."
        },
        systemImage: "key.horizontal",
        confirm: "Trust and Connect"
      ) {
        if let question {
          VStack(alignment: .leading, spacing: 2) {
            Text(question.keyType ?? "Fingerprint").kitFont(.caption)
            KitCodeBlock(question.fingerprint, font: .monoSmall)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } action: {
        if let id { request.finish(id, accepted: true) }
      }
      .onAppear { request.windowAppeared() }
      .onDisappear { request.windowDisappeared() }
  }
}
