import Foundation

/// A three-way merge of text by lines, for notes edited on two devices before either saw the other's edit.
///
/// Edits to different lines merge cleanly. When both devices changed the same lines differently, both versions
/// stay in the text between conflict markers, so nothing is lost silently and the note shows what to pick.
public enum TextMerge {
  public struct Result: Equatable, Sendable {
    public var text: String
    public var hasConflicts: Bool
  }

  public static func merge(
    base: String, ours: String, theirs: String, oursLabel: String = "This device", theirsLabel: String = "Other device"
  ) -> Result {
    if ours == theirs { return Result(text: ours, hasConflicts: false) }
    if ours == base { return Result(text: theirs, hasConflicts: false) }
    if theirs == base { return Result(text: ours, hasConflicts: false) }

    let baseLines = lines(base)
    let ourLines = lines(ours)
    let theirLines = lines(theirs)
    let hunks =
      (diff(baseLines, ourLines).map { Hunk(side: 0, change: $0) }
      + diff(baseLines, theirLines).map { Hunk(side: 1, change: $0) })
      .sorted { ($0.change.base.lowerBound, $0.side) < ($1.change.base.lowerBound, $1.side) }

    var output: [Substring] = []
    var conflicts = false
    var position = 0
    var index = 0
    while index < hunks.count {
      // A group of hunks whose base ranges overlap (or insert at the same place).
      var group = [hunks[index]]
      var end = hunks[index].change.base.upperBound
      index += 1
      while index < hunks.count {
        let next = hunks[index].change.base
        let touches = next.lowerBound < end || (next.lowerBound == end && (next.isEmpty || group.last!.change.base.isEmpty))
        guard touches else { break }
        group.append(hunks[index])
        end = max(end, next.upperBound)
        index += 1
      }
      let start = group[0].change.base.lowerBound
      output += baseLines[position..<start]
      position = end

      let mine = content(of: group.filter { $0.side == 0 }, start: start, end: end, base: baseLines, side: ourLines)
      let yours = content(of: group.filter { $0.side == 1 }, start: start, end: end, base: baseLines, side: theirLines)
      let original = Array(baseLines[start..<end])
      if mine == yours || yours == original {
        output += mine
      } else if mine == original {
        output += yours
      } else {
        conflicts = true
        output.append("<<<<<<< \(oursLabel)")
        output += mine
        output.append("=======")
        output += yours
        output.append(">>>>>>> \(theirsLabel)")
      }
    }
    output += baseLines[position...]
    return Result(text: output.joined(separator: "\n"), hasConflicts: conflicts)
  }

  private struct Hunk {
    let side: Int
    let change: Change
  }

  /// One side's lines for the base range `start..<end`, given its hunks inside that range.
  private static func content(
    of hunks: [Hunk], start: Int, end: Int, base: [Substring], side: [Substring]
  ) -> [Substring] {
    guard let first = hunks.first, let last = hunks.last else { return Array(base[start..<end]) }
    let sideStart = first.change.side.lowerBound - (first.change.base.lowerBound - start)
    let sideEnd = last.change.side.upperBound + (end - last.change.base.upperBound)
    return Array(side[sideStart..<sideEnd])
  }

  static func lines(_ text: String) -> [Substring] {
    text.split(separator: "\n", omittingEmptySubsequences: false)
  }

  /// A changed region: `base` lines replaced by `side` lines.
  struct Change: Equatable {
    var base: Range<Int>
    var side: Range<Int>
  }

  /// The regions where `b` differs from `a` (Myers' algorithm on lines, after trimming the common ends).
  static func diff(_ a: [Substring], _ b: [Substring]) -> [Change] {
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
      suffix += 1
    }
    let x = Array(a[prefix..<(a.count - suffix)])
    let y = Array(b[prefix..<(b.count - suffix)])
    let matches = commonLines(x, y)

    var changes: [Change] = []
    var i = 0
    var j = 0
    for (mi, mj) in matches + [(x.count, y.count)] {
      if mi > i || mj > j {
        changes.append(Change(base: (prefix + i)..<(prefix + mi), side: (prefix + j)..<(prefix + mj)))
      }
      i = mi + 1
      j = mj + 1
    }
    return changes
  }

  /// Index pairs of a longest common subsequence (Myers' greedy algorithm with a trace).
  private static func commonLines(_ a: [Substring], _ b: [Substring]) -> [(Int, Int)] {
    let n = a.count
    let m = b.count
    if n == 0 || m == 0 { return [] }
    let maxD = n + m
    let offset = maxD
    var v = [Int](repeating: 0, count: 2 * maxD + 2)
    var trace: [[Int]] = []
    var found = false
    for d in 0...maxD {
      trace.append(v)
      var k = -d
      while k <= d {
        var x: Int
        if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
          x = v[offset + k + 1]
        } else {
          x = v[offset + k - 1] + 1
        }
        var y = x - k
        while x < n, y < m, a[x] == b[y] {
          x += 1
          y += 1
        }
        v[offset + k] = x
        if x >= n && y >= m {
          found = true
          break
        }
        k += 2
      }
      if found { break }
    }
    // Walk the trace back to collect the diagonal (matching) moves.
    var pairs: [(Int, Int)] = []
    var x = n
    var y = m
    for d in stride(from: trace.count - 1, through: 0, by: -1) {
      let v = trace[d]
      let k = x - y
      let previousK: Int
      if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
        previousK = k + 1
      } else {
        previousK = k - 1
      }
      let previousX = d == 0 ? 0 : v[offset + previousK]
      let previousY = previousX - previousK
      while x > previousX && y > previousY {
        x -= 1
        y -= 1
        pairs.append((x, y))
      }
      if d > 0 {
        x = previousX
        y = previousY
      }
    }
    return pairs.reversed()
  }
}
