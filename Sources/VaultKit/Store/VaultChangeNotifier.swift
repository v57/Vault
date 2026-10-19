import Foundation

/// Tells the other apps on the device that the store changed.
public protocol VaultChangeNotifier: Sendable {
  func post()
}

#if canImport(Darwin)
/// The platform's notifier: a Darwin notification.
public typealias SystemChangeNotifier = DarwinChangeNotifier

/// A Darwin notification: it reaches every process on the device, sandboxed or not, the posting one included.
/// It carries no data; observers re-read the store.
public struct DarwinChangeNotifier: VaultChangeNotifier {
  public let name: String

  public init(name: String = VaultConfiguration.changeNotification) {
    self.name = name
  }

  public func post() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
  }
}

/// Calls `handler` (on the main queue) whenever any app posts the change notification.
public final class VaultChangeObserver: @unchecked Sendable {
  private let name: String
  private let handler: @Sendable () -> Void

  public init(name: String = VaultConfiguration.changeNotification, handler: @escaping @Sendable () -> Void) {
    self.name = name
    self.handler = handler
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let me = Unmanaged<VaultChangeObserver>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { me.handler() }
      },
      name as CFString, nil, .deliverImmediately)
  }

  deinit {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(name as CFString), nil)
  }
}
#else
/// The platform's notifier: a change file.
public typealias SystemChangeNotifier = FileChangeNotifier

/// Where Darwin notifications are missing (Windows, Linux): posting writes a new token into a file named after the
/// notification in the user's temporary folder, and observers look at it twice a second. It reaches every process
/// of the user, the posting one included, and carries no data; observers re-read the store.
public struct FileChangeNotifier: VaultChangeNotifier {
  public let name: String

  public init(name: String = VaultConfiguration.changeNotification) {
    self.name = name
  }

  static func url(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dev.v57.notifications", isDirectory: true)
      .appendingPathComponent(name)
  }

  public func post() {
    let url = Self.url(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(UUID().uuidString.utf8).write(to: url, options: .atomic)
  }
}

/// Calls `handler` (on the main queue) whenever any app posts the change notification.
public final class VaultChangeObserver: @unchecked Sendable {
  private let url: URL
  private let handler: @Sendable () -> Void
  private let timer: DispatchSourceTimer
  private var token: Data?

  public init(name: String = VaultConfiguration.changeNotification, handler: @escaping @Sendable () -> Void) {
    url = FileChangeNotifier.url(name)
    self.handler = handler
    token = try? Data(contentsOf: url)
    timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in self?.check() }
    timer.resume()
  }

  private func check() {
    let current = try? Data(contentsOf: url)
    guard current != token else { return }
    token = current
    let handler = self.handler
    DispatchQueue.main.async { handler() }
  }

  deinit { timer.cancel() }
}
#endif
