import Foundation
import Testing

@testable import VaultKit

/// Vault's app lock (security audit M13): one unlock holds for five minutes, turning the lock off always asks, and a
/// clock set back opens nothing.
@Suite(.serialized)
@MainActor
struct AppLockTests {
  /// How many times the owner was asked, and what they answer.
  final class Owner: @unchecked Sendable {
    private let lock = NSLock()
    private var _asked = 0
    private var _answers = true
    private var _clock = Date(timeIntervalSince1970: 1_800_000_000)

    var asked: Int { lock.withLock { _asked } }
    var answers: Bool {
      get { lock.withLock { _answers } }
      set { lock.withLock { _answers = newValue } }
    }
    var clock: Date { lock.withLock { _clock } }

    func ask() -> Bool { lock.withLock { _asked += 1; return _answers } }
    func wait(_ seconds: TimeInterval) { lock.withLock { _clock += seconds } }
  }

  let owner = Owner()

  init() {
    VaultSecrets.useInMemoryStore()
    VaultAppLock.reset()
    let owner = owner
    VaultAppLock.authenticate = { _ in owner.ask() }
    VaultAppLock.now = { owner.clock }
  }

  func wait(_ seconds: TimeInterval) { owner.wait(seconds) }

  @Test func onByDefaultAndAsksOncePerGracePeriod() async {
    #expect(VaultAppLock.isEnabled)
    #expect(!VaultAppLock.isUnlocked)
    #expect(await VaultAppLock.unlock(reason: "show the password"))
    #expect(owner.asked == 1)
    // A second Show within five minutes doesn't ask.
    wait(4 * 60)
    #expect(await VaultAppLock.unlock(reason: "copy the password"))
    #expect(owner.asked == 1)
    // After five minutes it asks again.
    wait(61)
    #expect(!VaultAppLock.isUnlocked)
    #expect(await VaultAppLock.unlock(reason: "copy the password"))
    #expect(owner.asked == 2)
  }

  @Test func aRefusalOpensNothing() async {
    owner.answers = false
    #expect(!(await VaultAppLock.unlock(reason: "show the password")))
    #expect(!VaultAppLock.isUnlocked)
  }

  @Test func launchAsksEvenInsideTheGracePeriod() async {
    #expect(await VaultAppLock.unlock(reason: "open Vault"))
    #expect(await VaultAppLock.unlockNow(reason: "open Vault"))
    #expect(owner.asked == 2)
    VaultAppLock.lockNow()
    #expect(!VaultAppLock.isUnlocked)
  }

  @Test func aClockSetBackOpensNothing() async {
    #expect(await VaultAppLock.unlock(reason: "show the password"))
    wait(-3600)
    #expect(!VaultAppLock.isUnlocked)
  }

  @Test func turningItOffAsksAndThenNothingDoes() async {
    #expect(await VaultAppLock.unlock(reason: "show the password"))
    owner.answers = false
    // Inside the grace period, turning it off still asks, and a refusal keeps it on.
    #expect(!(await VaultAppLock.setEnabled(false, reason: "turn off the lock")))
    #expect(VaultAppLock.isEnabled)
    owner.answers = true
    #expect(await VaultAppLock.setEnabled(false, reason: "turn off the lock"))
    #expect(!VaultAppLock.isEnabled)
    VaultAppLock.lockNow()
    owner.answers = false
    #expect(VaultAppLock.isUnlocked)
    #expect(await VaultAppLock.unlock(reason: "show the password"))
    #expect(await VaultAppLock.setEnabled(true, reason: ""))
    #expect(!VaultAppLock.isUnlocked)
  }

  /// The reason follows "“Vault” is trying to" on the Mac; on iPhone and iPad it's a line of its own (V-021).
  @Test func aStandaloneReasonStartsWithACapital() {
    #expect(VaultAppLock.sentence("open your vault") == "Open your vault")
    #expect(VaultAppLock.sentence("show or copy “Atlas admin”") == "Show or copy “Atlas admin”")
    #expect(VaultAppLock.sentence("") == "")
  }
}
