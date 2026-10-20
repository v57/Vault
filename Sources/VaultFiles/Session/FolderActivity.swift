import Foundation

/// What a decrypt session is doing, for the UI: which file it is decrypting or sealing, how far along, and how many
/// of the pass's files are done. `DecryptSession` reports it through `onActivity` and keeps the latest in `activity`.
public struct FolderActivity: Sendable, Equatable {
  public enum Phase: String, Sendable {
    case idle
    /// Decrypting the folder into the working copy (`DecryptSession.start`).
    case decrypting
    /// Sealing changed files back (`sealChanges`, `lock`).
    case sealing
  }

  public var phase: Phase
  /// The file in progress, as a path in the folder.
  public var file: String?
  /// Bytes of the current file done, and its size.
  public var fileBytes: Int64
  public var fileSize: Int64
  /// Files this pass has finished, and how many it has in all (the changed files, when sealing).
  public var completed: Int
  public var total: Int
  /// Bytes this pass has finished, and how many it has in all.
  public var bytesDone: Int64
  public var bytesTotal: Int64

  public init(
    phase: Phase = .idle, file: String? = nil, fileBytes: Int64 = 0, fileSize: Int64 = 0, completed: Int = 0,
    total: Int = 0, bytesDone: Int64 = 0, bytesTotal: Int64 = 0
  ) {
    self.phase = phase
    self.file = file
    self.fileBytes = fileBytes
    self.fileSize = fileSize
    self.completed = completed
    self.total = total
    self.bytesDone = bytesDone
    self.bytesTotal = bytesTotal
  }

  public static let idle = FolderActivity()

  /// The pass's progress from 0 to 1, by bytes (by files when they're all empty).
  public var fraction: Double {
    if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
    return total > 0 ? Double(completed) / Double(total) : 0
  }

  /// "Sealing main.swift · 2 of 5", "Decrypting big.bin · 1 of 40", or "Idle".
  public var summary: String {
    switch phase {
    case .idle: return "Idle"
    case .decrypting, .sealing:
      let verb = phase == .sealing ? "Sealing" : "Decrypting"
      let name = file.map { " " + ($0.split(separator: "/").last.map(String.init) ?? $0) } ?? ""
      return "\(verb)\(name) · \(min(completed + 1, max(total, 1))) of \(max(total, 1))"
    }
  }
}
