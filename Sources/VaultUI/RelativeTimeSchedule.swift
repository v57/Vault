import Foundation
import SwiftUI

/// When a short relative time of `date` ("just now", "3 min ago", "2 hr ago", then the date) reads differently: a
/// `TimelineView` on it redraws only at those moments, not every second, and a line such as "synced just now" ages
/// while nothing else changes (V-042: the Items line kept saying "synced just now" minutes after the last fetch).
/// The steps are those of the app's `RelativeTime.short`: under 45 s "just now", then minutes ("1 min ago" until 2 min),
/// hours from 1 hour, the date from 24 hours.
public struct RelativeTimeSchedule: TimelineSchedule {
  public let date: Date?

  public init(_ date: Date?) {
    self.date = date
  }

  public func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
    [startDate] + (date.map { Self.changes(of: $0, after: startDate) } ?? [])
  }

  /// The moments after `start` when the relative time of `date` reads differently, earliest first; none once it reads
  /// as a date
  public static func changes(of date: Date, after start: Date) -> [Date] {
    let seconds: [TimeInterval] = [45] + (2...59).map { TimeInterval($0 * 60) } + (1...24).map { TimeInterval($0 * 3600) }
    return seconds.map { date.addingTimeInterval($0) }.filter { $0 > start }
  }
}
