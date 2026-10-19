#if !canImport(CloudKit)
  import Foundation

  /// Where CloudKit is missing (Windows, Linux) the vault stays on the device: the same API, never running.
  public final class CloudSync: @unchecked Sendable {
    public let store: VaultStore
    public private(set) var lastError: String?

    public init(store: VaultStore, onChange: @escaping @Sendable () -> Void = {}) {
      self.store = store
    }

    public static var isEntitled: Bool { false }
    public func start() {}
    public var isRunning: Bool { false }
    public func syncNow() {}
  }
#endif
