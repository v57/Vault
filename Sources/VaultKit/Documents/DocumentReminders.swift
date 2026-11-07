import Foundation

/// A date a document asks you to act on: a passport expiring, a policy renewing, the last day to give notice.
public struct DocumentEvent: Hashable, Sendable, Identifiable {
  public enum Kind: String, Hashable, Sendable {
    /// The reminding date itself ("Expires", "Renews", "Warranty until").
    case due
    /// The last day to cancel before it renews: the reminding date less the notice period.
    case notice
  }

  public var document: String
  public var kind: Kind
  /// The field's label ("Expires", "Renews").
  public var label: String
  /// The day it happens.
  public var date: Date
  /// The day the reminder goes off.
  public var remindOn: Date

  public var id: String { "\(document).\(kind.rawValue)" }

  public init(document: String, kind: Kind, label: String, date: Date, remindOn: Date) {
    self.document = document
    self.kind = kind
    self.label = label
    self.date = date
    self.remindOn = remindOn
  }
}

extension VaultDocument {
  /// The dates this document reminds about. A notice deadline reminds two weeks before it; the due date reminds the
  /// document's (or its kind's) months before. None when the reminder is off or the date is empty.
  public func events(kind: DocumentKind) -> [DocumentEvent] {
    guard let field = kind.remindingField, let date = day(field.key) else { return [] }
    let months = remindMonths ?? kind.remindMonths ?? 0
    guard months > 0 else { return [] }
    var events = [
      DocumentEvent(
        document: id, kind: .due, label: field.label, date: date,
        remindOn: DocumentDay.date(date, monthsBefore: months))
    ]
    if let notice = kind.noticeField, let text = fields[notice.key], let noticeMonths = Self.months(in: text),
      noticeMonths > 0
    {
      let deadline = DocumentDay.date(date, monthsBefore: noticeMonths)
      let remindOn = Calendar(identifier: .gregorian).date(byAdding: .day, value: -14, to: deadline) ?? deadline
      events.append(DocumentEvent(document: id, kind: .notice, label: "Notice by", date: deadline, remindOn: remindOn))
    }
    return events
  }

  /// The number in a notice period as typed ("3", "3 months").
  static func months(in text: String) -> Int? {
    Int(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
  }
}

public enum DocumentReminders {
  /// Coming Up: dates whose reminder has gone off or that fall within `days`, from today on (a date passed in the
  /// last `grace` days stays, so an expired passport doesn't vanish the day after), soonest first. Of a document's
  /// notice and due dates only the next one shows.
  public static func comingUp(
    _ documents: [VaultDocument], kinds: DocumentKinds, now: Date = .now, within days: Int = 90, grace: Int = 30
  ) -> [DocumentEvent] {
    var result: [DocumentEvent] = []
    for document in documents {
      let events = document.events(kind: kinds[document.kind]).filter { event in
        let left = DocumentDay.days(from: now, to: event.date)
        return left >= -grace && (left <= days || event.remindOn <= now)
      }
      if let next = events.filter({ DocumentDay.days(from: now, to: $0.date) >= 0 }).min(by: { $0.date < $1.date })
        ?? events.max(by: { $0.date < $1.date })
      {
        result.append(next)
      }
    }
    return result.sorted { ($0.date, $0.document) < ($1.date, $1.document) }
  }

  /// Every reminder still to go off, for scheduling notifications on this device.
  public static func upcoming(_ documents: [VaultDocument], kinds: DocumentKinds, now: Date = .now) -> [DocumentEvent] {
    documents.flatMap { $0.events(kind: kinds[$0.kind]) }.filter { $0.remindOn > now }.sorted { $0.remindOn < $1.remindOn }
  }
}
