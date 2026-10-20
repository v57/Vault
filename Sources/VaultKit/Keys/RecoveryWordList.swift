import Foundation

/// The 2048 words a recovery key is written in: each word carries 11 bits, so 24 of them hold the 256-bit secret
/// and an 8-bit checksum (BIP-39's encoding).
///
/// Any list of 2048 different lowercase words works. A list whose words differ in their first four letters (like
/// `english`) also reads a word typed as its first four letters or more ("aban" or "aband" for "abandon").
public struct RecoveryWordList: Sendable {
  public let words: [String]
  private let indices: [String: Int]
  /// Words by their first four letters, when those are unique.
  private let prefixes: [String: Int]?

  /// The list, or nil unless it has 2048 different lowercase words.
  public init?(words: [String]) {
    guard words.count == 2048, Set(words).count == 2048,
      words.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLowercase && $0.isLetter } })
    else { return nil }
    self.init(validated: words)
  }

  init(validated words: [String]) {
    precondition(words.count == 2048)
    self.words = words
    indices = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
    let prefixes = Dictionary(words.enumerated().map { (String($1.prefix(4)), $0) }, uniquingKeysWith: { a, _ in a })
    self.prefixes = prefixes.count == words.count ? prefixes : nil
  }

  /// The index of a typed word (lowercase): the word itself, or its first four letters or more when the list
  /// tells words apart by them. Nil for anything else, never a guess.
  public func index(of typed: String) -> Int? {
    if let index = indices[typed] { return index }
    guard typed.count >= 4, let prefixes, let index = prefixes[String(typed.prefix(4))],
      words[index].hasPrefix(typed)
    else { return nil }
    return index
  }

  /// Words one or two edits away from what was typed (a letter changed, added, dropped or two swapped), closest
  /// first, for the UI to offer. Never applied on its own.
  public func suggestions(for typed: String, limit: Int = 4) -> [String] {
    let typed = Array(typed)
    var found: [(distance: Int, word: String)] = []
    for word in words {
      let distance = Self.editDistance(typed, Array(word), limit: 2)
      if distance <= 2 { found.append((distance, word)) }
    }
    return found.sorted { ($0.distance, $0.word) < ($1.distance, $1.word) }.prefix(limit).map(\.word)
  }

  /// Damerau-Levenshtein (optimal string alignment) distance, or `limit + 1` once it is sure to exceed `limit`.
  static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
    if abs(a.count - b.count) > limit { return limit + 1 }
    if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
    var previous2 = [Int](repeating: 0, count: b.count + 1)
    var previous = Array(0...b.count)
    for i in 1...a.count {
      var current = [Int](repeating: 0, count: b.count + 1)
      current[0] = i
      var rowMin = current[0]
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
          current[j] = min(current[j], previous2[j - 2] + 1)
        }
        rowMin = min(rowMin, current[j])
      }
      if rowMin > limit { return limit + 1 }
      previous2 = previous
      previous = current
    }
    return previous[b.count]
  }
}
