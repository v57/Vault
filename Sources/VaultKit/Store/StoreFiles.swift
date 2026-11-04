import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Android)
  import Android
#endif

/// Putting a finished file into place so that a crash or a power cut leaves the old state or the new one, and two
/// processes racing get one winner.
enum StoreFiles {
  /// Forces a file to the disk itself. On Apple platforms a plain `fsync` stops at the drive's cache, so `F_FULLFSYNC`
  /// first; elsewhere `FileHandle.synchronize` is `fsync` on Linux and `FlushFileBuffers` on Windows.
  static func sync(_ url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    #if canImport(Darwin)
      if fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 { return }
    #endif
    try handle.synchronize()
  }

  /// Forces a folder's list of names to disk: what makes a rename survive a power cut. Windows has no such call, and
  /// `MoveFileEx` with `MOVEFILE_WRITE_THROUGH` covers it there.
  static func syncFolder(_ url: URL) {
    #if !os(Windows)
      let descriptor = open(url.path, O_RDONLY)
      guard descriptor >= 0 else { return }
      defer { close(descriptor) }
      _ = fsync(descriptor)
    #endif
  }

  /// Moves `source` to `destination` unless something is there already. Returns false when something is, leaving `source`.
  ///
  /// A hard link fails atomically when the name is taken, on every POSIX system and with no call that differs between
  /// them; a kill between the link and the unlink leaves a temporary file behind and nothing else wrong. A file system
  /// without hard links, and Windows, get a move, which `FileManager` refuses when the destination exists; there a race
  /// could still fail with an error, and the next open sees the winner's file.
  static func moveWithoutReplacing(_ source: URL, to destination: URL) throws -> Bool {
    #if !os(Windows)
      if link(source.path, destination.path) == 0 {
        unlink(source.path)
        return true
      }
      if errno == EEXIST { return false }
    #endif
    guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
    do {
      try FileManager.default.moveItem(at: source, to: destination)
      return true
    } catch {
      if FileManager.default.fileExists(atPath: destination.path) { return false }
      throw error
    }
  }
}
