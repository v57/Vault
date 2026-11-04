import Foundation

/// When a key that needs the user may ask for them, and how long a yes lasts. It holds what the system gave for that yes
/// (`Credential`), so ending the window ends that too. No platform code here, so it runs in tests with no prompt and no key.
///
/// It never asks unless all of these hold: nothing is open, the caller isn't working unattended, and the app is in front.
/// A window ends on its clock (one that goes on counting through sleep) or at `close()`, whichever is first.
final class PresenceGate<Credential>: @unchecked Sendable {
  struct Refused: Error {}

  typealias Instant = ContinuousClock.Instant

  private let length: Duration
  private let now: @Sendable () -> Instant
  private let isFrontmost: @Sendable () -> Bool
  private let ask: @Sendable (String) throws -> Credential
  private let ended: @Sendable (Credential) -> Void

  private let lock = NSLock()
  private var open: (credential: Credential, until: Instant)?
  /// Held across a question, so connections starting together share one answer.
  private let askLock = NSLock()
  private var refused: Instant?

  init(
    length: Duration, now: @escaping @Sendable () -> Instant = { ContinuousClock.now }, isFrontmost: @escaping @Sendable () -> Bool,
    ask: @escaping @Sendable (String) throws -> Credential, ended: @escaping @Sendable (Credential) -> Void = { _ in }
  ) {
    self.length = length
    self.now = now
    self.isFrontmost = isFrontmost
    self.ask = ask
    self.ended = ended
  }

  /// What the open window holds, nil when none is open.
  var credential: Credential? {
    var over: Credential?
    let current: Credential? = lock.withLock {
      guard let open else { return nil }
      if now() < open.until { return open.credential }
      over = open.credential
      self.open = nil
      return nil
    }
    if let over { ended(over) }
    return current
  }

  /// Returns once a window is open, asking if it may. `unattended`: nobody started this just now, so it never asks.
  func prepare(reason: String, unattended: Bool) throws {
    if credential != nil { return }
    guard !unattended, isFrontmost() else { throw Refused() }
    askLock.lock()
    defer { askLock.unlock() }
    if credential != nil { return }
    // Others that waited on a question just refused don't ask it again, one after another.
    if let refused, now() < refused.advanced(by: .seconds(2)) { throw Refused() }
    do {
      let answer = try ask(reason)
      let until = now().advanced(by: length)
      let replaced = lock.withLock {
        defer { open = (answer, until) }
        return open?.credential
      }
      if let replaced { ended(replaced) }
    } catch {
      refused = now()
      throw Refused()
    }
  }

  /// Ends the window now: the screen locked, or the system stopped honoring it.
  func close() {
    let over = lock.withLock {
      defer { open = nil }
      return open?.credential
    }
    if let over { ended(over) }
  }
}
