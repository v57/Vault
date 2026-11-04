import Foundation
import Testing

@testable import VaultKit

/// When the key that needs the user may ask (Ideas/Security V7). A fake stands in for the system's question: nothing here
/// touches a key or shows a prompt.
struct PresenceGateTests {
  final class Fixture: @unchecked Sendable {
    let lock = NSLock()
    var time = ContinuousClock.now
    var asked = 0
    var ended: [Int] = []
    var frontmost = true
    var says = true

    func advance(_ duration: Duration) { lock.withLock { time = time.advanced(by: duration) } }

    lazy var gate = PresenceGate<Int>(
      length: .seconds(900),
      now: { [unowned self] in lock.withLock { time } },
      isFrontmost: { [unowned self] in lock.withLock { frontmost } },
      ask: { [unowned self] _ in
        let (number, yes) = lock.withLock { () -> (Int, Bool) in
          asked += 1
          return (asked, says)
        }
        Thread.sleep(forTimeInterval: 0.01)
        if !yes { throw CocoaError(.userCancelled) }
        return number
      },
      ended: { [unowned self] number in lock.withLock { ended.append(number) } })
  }

  @Test func oneYesLastsTheWindowAndThenItAsksAgain() throws {
    let f = Fixture()
    try f.gate.prepare(reason: "r", unattended: false)
    try f.gate.prepare(reason: "r", unattended: false)
    #expect(f.asked == 1)
    #expect(f.gate.credential == 1)

    f.advance(.seconds(899))
    try f.gate.prepare(reason: "r", unattended: false)
    #expect(f.asked == 1)

    f.advance(.seconds(1))
    #expect(f.gate.credential == nil)
    #expect(f.ended == [1], "what the system gave for that yes is ended with it")
    try f.gate.prepare(reason: "r", unattended: false)
    #expect(f.asked == 2)
  }

  @Test func workNobodyStartedNeverAsks() throws {
    let f = Fixture()
    #expect(throws: PresenceGate<Int>.Refused.self) { try f.gate.prepare(reason: "r", unattended: true) }
    #expect(f.asked == 0)

    // In the window it goes ahead without asking.
    try f.gate.prepare(reason: "r", unattended: false)
    try f.gate.prepare(reason: "r", unattended: true)
    #expect(f.asked == 1)

    f.advance(.seconds(900))
    #expect(throws: PresenceGate<Int>.Refused.self) { try f.gate.prepare(reason: "r", unattended: true) }
    #expect(f.asked == 1)
  }

  @Test func anAppThatIsntInFrontNeverAsks() throws {
    let f = Fixture()
    f.frontmost = false
    #expect(throws: PresenceGate<Int>.Refused.self) { try f.gate.prepare(reason: "r", unattended: false) }
    #expect(f.asked == 0)
    f.frontmost = true
    try f.gate.prepare(reason: "r", unattended: false)
    // A window already open doesn't need it in front.
    f.frontmost = false
    try f.gate.prepare(reason: "r", unattended: false)
    #expect(f.asked == 1)
  }

  @Test func closingEndsTheWindowAtOnce() throws {
    let f = Fixture()
    try f.gate.prepare(reason: "r", unattended: false)
    f.gate.close()
    #expect(f.ended == [1])
    #expect(f.gate.credential == nil)
    #expect(throws: PresenceGate<Int>.Refused.self) { try f.gate.prepare(reason: "r", unattended: true) }
    f.gate.close()
    #expect(f.ended == [1])
  }

  @Test func aNoIsntAskedAgainAndAgain() throws {
    let f = Fixture()
    f.says = false
    #expect(throws: PresenceGate<Int>.Refused.self) { try f.gate.prepare(reason: "r", unattended: false) }
    #expect(throws: PresenceGate<Int>.Refused.self) { try f.gate.prepare(reason: "r", unattended: false) }
    #expect(f.asked == 1)
    #expect(f.gate.credential == nil)

    // The next click, a moment later, is a new question.
    f.says = true
    f.advance(.seconds(2))
    try f.gate.prepare(reason: "r", unattended: false)
    #expect(f.asked == 2)
  }

  @Test func connectionsStartingTogetherShareOneQuestion() async throws {
    let f = Fixture()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { try f.gate.prepare(reason: "r", unattended: false) }
      }
      try await group.waitForAll()
    }
    #expect(f.asked == 1)
  }

  @Test func quietlyReachesWhatItStarts() async throws {
    let viaTask = await VaultIdentity.quietly { await Task { VaultIdentity.isQuietForTesting }.value }
    let viaGroup = await VaultIdentity.quietly {
      await withTaskGroup(of: Bool.self) { group in
        group.addTask { VaultIdentity.isQuietForTesting }
        return await group.next() ?? false
      }
    }
    #expect(viaTask)
    #expect(viaGroup)
    #expect(!VaultIdentity.isQuietForTesting)
  }
}
