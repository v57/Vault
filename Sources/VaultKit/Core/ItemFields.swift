import Foundation

/// One field's value and the clock of its last write.
public struct StampedValue: Hashable, Sendable, Codable {
  public var value: JSONValue
  public var clock: HybridClock

  public init(_ value: JSONValue, clock: HybridClock) {
    self.value = value
    self.clock = clock
  }

  enum CodingKeys: String, CodingKey {
    case value = "v"
    case clock = "c"
  }
}

/// An item's fields, each with its own clock: the unit of merging.
///
/// Two copies of an item edited apart (an iPhone and a Mac offline, or two apps racing to the server) merge
/// field by field, and each field keeps its later write. So a rename on one device and a port change on the
/// other both survive, and when both changed the same field every device keeps the same one.
///
/// Deleting writes the `_deleted` field. The item counts as deleted while that write is the item's latest:
/// an edit made after the delete (on a device that hadn't seen it yet) brings the item back.
public struct ItemFields: Hashable, Sendable, Codable {
  public static let deletedKey = "_deleted"

  public var stamped: [String: StampedValue]

  public init(_ stamped: [String: StampedValue] = [:]) {
    self.stamped = stamped
  }

  /// The plain values, without the bookkeeping fields.
  public var values: [String: JSONValue] {
    stamped.filter { !$0.key.hasPrefix("_") }.mapValues(\.value)
  }

  public subscript(key: String) -> JSONValue? { stamped[key]?.value }

  /// The latest clock of any field.
  public var latestClock: HybridClock {
    stamped.values.map(\.clock).max() ?? .zero
  }

  public var isDeleted: Bool {
    guard let deleted = stamped[Self.deletedKey], deleted.value == .bool(true) else { return false }
    return stamped.allSatisfy { $0.key == Self.deletedKey || $0.value.clock < deleted.clock }
  }

  /// Both copies' fields, each from the copy that wrote it last.
  public func merged(with other: ItemFields) -> ItemFields {
    var result = stamped
    for (key, theirs) in other.stamped {
      guard let ours = result[key] else {
        result[key] = theirs
        continue
      }
      if theirs.clock > ours.clock
        || (theirs.clock == ours.clock && theirs.value.tieBreakKey > ours.value.tieBreakKey)
      {
        result[key] = theirs
      }
    }
    return ItemFields(result)
  }

  /// Like `merged(with:)`, but text fields (`textKeys`) that both copies changed since `base` (the version both
  /// started from, the last one the server had) are merged line by line instead of keeping the later write.
  ///
  /// The merge is the same on every device: the copy with the earlier clock is "ours", the later one "theirs",
  /// and the result gets a clock derived from the later one, so devices that merge the same pair converge
  /// (and one that only receives the result takes it, its clock being later than either).
  public func merged(with other: ItemFields, base: ItemFields?, textKeys: Set<String>) -> ItemFields {
    var result = merged(with: other)
    guard !textKeys.isEmpty else { return result }
    for key in textKeys {
      guard let mine = stamped[key], let theirs = other.stamped[key], mine.clock != theirs.clock,
        let mineText = mine.value.stringValue, let theirText = theirs.value.stringValue, mineText != theirText
      else { continue }
      let baseText = base?[key]?.stringValue ?? ""
      guard mineText != baseText, theirText != baseText else { continue }
      let (earlier, later) = mine.clock < theirs.clock ? (mine, theirs) : (theirs, mine)
      let text = TextMerge.merge(
        base: baseText, ours: earlier.value.stringValue ?? "", theirs: later.value.stringValue ?? "",
        oursLabel: "Edited on one device", theirsLabel: "Edited on another device"
      ).text
      let clock = HybridClock(millis: later.clock.millis, counter: later.clock.counter + 1, device: later.clock.device + "+merge")
      result.stamped[key] = StampedValue(.string(text), clock: clock)
    }
    return result
  }

  /// Writes `changes` stamped with `clock`, skipping values that are already there, and reports whether
  /// anything changed. Fields not in `changes` keep their value and clock.
  @discardableResult
  public mutating func apply(_ changes: [String: JSONValue], clock: HybridClock) -> Bool {
    var changed = false
    for (key, value) in changes where stamped[key]?.value != value {
      // A field that was never written and is set to null stays absent.
      if stamped[key] == nil && value == .null { continue }
      stamped[key] = StampedValue(value, clock: clock)
      changed = true
    }
    return changed
  }
}
