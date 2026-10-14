import Foundation

/// A hybrid logical clock: wall time in milliseconds, a counter for writes inside one millisecond, and the
/// device that wrote. Every field carries the clock of its last write, and merging keeps the later one.
///
/// Unlike a timestamp alone it never runs backwards on one device (the store keeps the last clock it issued
/// or saw, see `VaultStore.nextClock`), and two devices never issue equal clocks (the device id breaks ties),
/// so every device picks the same winner for the same pair of edits.
public struct HybridClock: Hashable, Sendable, Comparable, CustomStringConvertible {
  public var millis: Int64
  public var counter: Int
  public var device: String

  public init(millis: Int64, counter: Int, device: String) {
    self.millis = millis
    self.counter = counter
    self.device = device
  }

  public static let zero = HybridClock(millis: 0, counter: 0, device: "")

  public static func < (lhs: HybridClock, rhs: HybridClock) -> Bool {
    if lhs.millis != rhs.millis { return lhs.millis < rhs.millis }
    if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
    return lhs.device < rhs.device
  }

  /// The clock after `self` for a write at `now` on `device`.
  public func next(now: Date, device: String) -> HybridClock {
    let wall = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
    if wall > millis { return HybridClock(millis: wall, counter: 0, device: device) }
    return HybridClock(millis: millis, counter: counter + 1, device: device)
  }

  /// `millis-counter-device`, with fixed-width numbers so the text sorts like the clock.
  public var description: String {
    String(format: "%013lld-%06x-", millis, counter) + device
  }

  public init?(_ text: String) {
    let parts = text.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, let millis = Int64(parts[0]), let counter = Int(parts[1], radix: 16) else { return nil }
    self.init(millis: millis, counter: counter, device: String(parts[2]))
  }
}

extension HybridClock: Codable {
  public init(from decoder: Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let clock = HybridClock(text) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad clock \(text)"))
    }
    self = clock
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}
