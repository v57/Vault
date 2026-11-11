import Foundation
import Testing

@testable import VaultUI

/// `RelativeTimeSchedule`: a "synced just now" line is redrawn when it would read differently, and only then (V-042).
struct RelativeTimeScheduleTests {
  let synced = Date(timeIntervalSinceReferenceDate: 800_000_000)

  @Test func changesAtEachStepOfTheText() {
    let changes = RelativeTimeSchedule.changes(of: synced, after: synced)
    let offsets = changes.map { $0.timeIntervalSince(synced) }
    // "just now" → "1 min ago" at 45 s, "2 min ago" at 2 min, … "59 min ago", "1 hr ago" … "23 hr ago", then the date
    #expect(offsets.prefix(3) == [45, 120, 180])
    #expect(offsets.contains(59 * 60))
    #expect(offsets.contains(3600))
    #expect(offsets.contains(23 * 3600))
    #expect(offsets.last == 86400)
    #expect(offsets == offsets.sorted())
  }

  @Test func onlyMomentsStillToCome() {
    // Three and a half minutes after the fetch: the next change is "4 min ago"
    let now = synced.addingTimeInterval(210)
    let changes = RelativeTimeSchedule.changes(of: synced, after: now)
    #expect(changes.first == synced.addingTimeInterval(240))
    #expect(changes.allSatisfy { $0 > now })
    // A day later it reads as a date, which no longer changes
    #expect(RelativeTimeSchedule.changes(of: synced, after: synced.addingTimeInterval(86400)).isEmpty)
  }

  @Test func timelineStartsNowAndWaitsWithoutADate() {
    let now = synced.addingTimeInterval(10)
    let entries = RelativeTimeSchedule(synced).entries(from: now, mode: .normal)
    #expect(entries.first == now)
    #expect(entries.dropFirst().first == synced.addingTimeInterval(45))
    #expect(RelativeTimeSchedule(nil).entries(from: now, mode: .normal) == [now])
  }
}
