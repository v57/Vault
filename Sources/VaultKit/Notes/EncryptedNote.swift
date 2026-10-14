import CryptoKit
import Foundation

/// Encrypted notes: Markdown files whose text is sealed with the vault key, so only the v57 apps on the
/// user's devices can read them, while iCloud Drive still syncs them like any file.
///
/// An encrypted note is `Name.mdenc`: the name stays readable (Finder and Files list it), the text doesn't.
/// The file starts with `V57NOTE1`, then the key id, then the AES-GCM box (nonce, ciphertext, tag).
public enum EncryptedNote {
  /// The extension of encrypted notes.
  public static let fileExtension = "mdenc"
  /// The uniform type the apps declare for them.
  public static let typeIdentifier = "dev.v57.md.encrypted"

  static let magic = Data("V57NOTE1".utf8)

  public enum NoteError: LocalizedError {
    case notEncrypted
    case damaged

    public var errorDescription: String? {
      switch self {
      case .notEncrypted: "This file isn't an encrypted note."
      case .damaged: "The encrypted note is damaged."
      }
    }
  }

  public static func isEncrypted(_ data: Data) -> Bool {
    data.starts(with: magic)
  }

  public static func isEncrypted(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == fileExtension
  }

  public static func seal(_ text: String, keys: VaultKeyProvider) throws -> Data {
    let sealed = try VaultCrypto.seal(Data(text.utf8), keys: keys)
    let keyID = Data(sealed.keyID.utf8)
    return magic + Data([UInt8(keyID.count)]) + keyID + sealed.ciphertext
  }

  public static func open(_ data: Data, keys: VaultKeyProvider) throws -> String {
    guard isEncrypted(data) else { throw NoteError.notEncrypted }
    var rest = data.dropFirst(magic.count)
    guard let length = rest.first.map(Int.init), rest.count > length else { throw NoteError.damaged }
    rest = rest.dropFirst()
    let keyID = String(decoding: rest.prefix(length), as: UTF8.self)
    let plaintext = try VaultCrypto.open(Data(rest.dropFirst(length)), keyID: keyID, keys: keys)
    guard let text = String(data: plaintext, encoding: .utf8) else { throw NoteError.damaged }
    return text
  }

  /// A note's text, encrypted or not.
  public static func text(of data: Data, keys: VaultKeyProvider) throws -> String {
    if isEncrypted(data) { return try open(data, keys: keys) }
    return String(decoding: data, as: UTF8.self)
  }

  /// The file name a note gets when its encryption is turned on or off: `Name.md` ↔ `Name.mdenc`.
  public static func url(for url: URL, encrypted: Bool) -> URL {
    let base = url.deletingPathExtension()
    return base.appendingPathExtension(encrypted ? fileExtension : "md")
  }
}

/// Resolves iCloud Drive conflicts on a note (two devices saved it before seeing each other's version) by
/// merging the versions into one, against the last version this device synced.
public enum NoteConflicts {
  /// Merges every unresolved conflict version of the note at `url` into the file and marks them resolved.
  /// Returns the merged text, or nil when there was no conflict.
  @discardableResult
  public static func resolve(at url: URL, base: String?, keys: VaultKeyProvider) throws -> String? {
    guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return nil }
    let encrypted = EncryptedNote.isEncrypted(url)
    var merged = try EncryptedNote.text(of: Data(contentsOf: url), keys: keys)
    for version in versions {
      let theirs = try EncryptedNote.text(of: Data(contentsOf: version.url), keys: keys)
      let device = version.localizedNameOfSavingComputer ?? "Other device"
      // Without a common version, both sides count as changed: anything different is kept twice.
      merged = TextMerge.merge(base: base ?? "", ours: merged, theirs: theirs, theirsLabel: device).text
    }
    let data = encrypted ? try EncryptedNote.seal(merged, keys: keys) : Data(merged.utf8)
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { target in
      do { try data.write(to: target, options: .atomic) } catch { writeError = error }
    }
    if let error = coordinationError ?? writeError { throw error }
    for version in versions { version.isResolved = true }
    try NSFileVersion.removeOtherVersionsOfItem(at: url)
    return merged
  }
}

/// The last text of each note this device saw in sync, the common ancestor for `TextMerge`. Kept encrypted,
/// in the app's caches.
public final class NoteBaseCache: @unchecked Sendable {
  private let directory: URL
  private let keys: VaultKeyProvider

  public init(
    directory: URL = URL.cachesDirectory.appendingPathComponent("NoteBases", isDirectory: true),
    keys: VaultKeyProvider
  ) {
    self.directory = directory
    self.keys = keys
  }

  private func file(for url: URL) -> URL {
    let name = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(16)
      .map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(name)
  }

  public func base(for url: URL) -> String? {
    guard let data = try? Data(contentsOf: file(for: url)) else { return nil }
    return try? EncryptedNote.open(data, keys: keys)
  }

  public func setBase(_ text: String, for url: URL) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? EncryptedNote.seal(text, keys: keys) {
      try? data.write(to: file(for: url), options: .atomic)
    }
  }

  public func moveBase(from old: URL, to new: URL) {
    try? FileManager.default.moveItem(at: file(for: old), to: file(for: new))
  }
}
