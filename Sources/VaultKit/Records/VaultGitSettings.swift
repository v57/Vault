import Foundation

/// The Git app's choices that the user's devices share, in Personal's vault. One record; a field nobody set means the
/// app's default.
public struct VaultGitSettings: VaultRecord, Hashable {
  public static let kind = "gitSettings"
  public static let recordID = "git.settings"

  public var id: String
  /// How far network actions may go, 1 to 4 (GitKit's `GitSecurityLevel`); nil until the user picks one.
  public var securityLevel: Int?

  public init(securityLevel: Int? = nil) {
    id = Self.recordID
    self.securityLevel = securityLevel
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    securityLevel = read.int("securityLevel")
  }

  public var values: [String: JSONValue] {
    ["securityLevel": securityLevel.map { .int(Int64($0)) } ?? .null]
  }
}
