import Foundation

/// What can go wrong reading or writing encrypted files and folders.
public enum VaultFilesError: LocalizedError, Equatable {
  /// The data doesn't start like an encrypted file (or folder manifest).
  case notEncrypted
  /// Written by a newer format version this build doesn't read.
  case unsupportedVersion(Int)
  /// The data failed authentication: changed, truncated, reordered, or sealed with another key.
  case damaged
  /// The folder was sealed with another key.
  case wrongKey
  /// No file or folder at this path.
  case notFound(String)
  /// Something is already at this path.
  case exists(String)
  /// A file is in the way where a folder is needed.
  case notADirectory(String)
  /// A folder is in the way where a file is needed.
  case isADirectory(String)
  /// The path or name can't be used (empty, `..`, contains `/` or NUL).
  case invalidName(String)
  /// The file is too large for the format (more than 2^32 chunks).
  case tooLarge

  public var errorDescription: String? {
    switch self {
    case .notEncrypted: "This isn't an encrypted file."
    case .unsupportedVersion(let version): "This file was written by a newer version of Vault (format \(version))."
    case .damaged: "The encrypted data is damaged."
    case .wrongKey: "This folder was encrypted with another key."
    case .notFound(let path): "Nothing at \(path)."
    case .exists(let path): "Something is already at \(path)."
    case .notADirectory(let path): "\(path) isn't a folder."
    case .isADirectory(let path): "\(path) is a folder."
    case .invalidName(let name): "“\(name)” can't be used as a name."
    case .tooLarge: "The file is too large to encrypt."
    }
  }
}
