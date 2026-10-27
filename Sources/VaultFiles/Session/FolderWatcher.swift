#if os(macOS)
  import CoreServices
  import Foundation

  /// Calls a handler when anything under a folder changes (FSEvents, coalesced over `latency` seconds). Runs in the
  /// app's own process, while the app runs: no helper. macOS and Linux; elsewhere the app calls
  /// `DecryptSession.sealChanges()` on a timer.
  public final class FolderWatcher: @unchecked Sendable {
    private final class Handler {
      let call: @Sendable () -> Void
      init(_ call: @escaping @Sendable () -> Void) { self.call = call }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.v57.VaultFiles.FolderWatcher")

    public init(url: URL, latency: TimeInterval = 1, handler: @escaping @Sendable () -> Void) {
      let box = Handler(handler)
      // The stream retains the handler box for as long as it lives, so a late event never reaches a freed one.
      var context = FSEventStreamContext(
        version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
        retain: { info in
          guard let info else { return nil }
          _ = Unmanaged<Handler>.fromOpaque(info).retain()
          return UnsafeRawPointer(info)
        },
        release: { info in
          guard let info else { return }
          Unmanaged<Handler>.fromOpaque(info).release()
        },
        copyDescription: nil)
      let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().call()
      }
      stream = FSEventStreamCreate(
        nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
      if let stream {
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
      }
    }

    /// Stops watching; no handler call starts after it returns.
    public func stop() {
      guard let stream else { return }
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }

    deinit { stop() }
  }
#elseif os(Linux)
  import Foundation
  import SwiftUIPortability

  /// Calls a handler when anything under a folder changes (inotify through SwiftUIPortability's DirectoryWatcher,
  /// coalesced over `latency` seconds), as the macOS one does with FSEvents.
  public final class FolderWatcher: @unchecked Sendable {
    private var watcher: DirectoryWatcher?
    private let queue = DispatchQueue(label: "dev.v57.VaultFiles.FolderWatcher")

    public init(url: URL, latency: TimeInterval = 1, handler: @escaping @Sendable () -> Void) {
      watcher = DirectoryWatcher(paths: [url.path], latency: latency, queue: queue) { _ in handler() }
    }

    /// Stops watching; no handler call starts after it returns.
    public func stop() {
      watcher?.stop()
      watcher = nil
    }

    deinit { stop() }
  }
#endif

#if os(macOS) || os(Linux)
  extension DecryptSession {
    /// Seals changes whenever the working copy changes, reporting each pass that changed
    /// something, or failed, to `onSeal` on the watcher's queue. Keep the watcher; stop it before `lock()`.
    public func watch(latency: TimeInterval = 1, onSeal: @escaping @Sendable (Result<Report, any Error>) -> Void)
      -> FolderWatcher
    {
      let watcher = FolderWatcher(url: copyURL, latency: latency) { [weak self] in
        guard let self, !self.isLocked else { return }
        let result = Result { try self.sealChanges() }
        if case .success(let report) = result, report.isEmpty { return }
        onSeal(result)
      }
      return watcher
    }
  }
#endif
