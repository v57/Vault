import Foundation

/// Tells the other apps on the device that the store changed.
public protocol VaultChangeNotifier: Sendable {
  func post()
}

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
