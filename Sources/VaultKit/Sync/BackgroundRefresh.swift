import Foundation

#if canImport(BackgroundTasks) && os(iOS)
  import BackgroundTasks
#endif

/// Asking the system for a later turn in the background (iPad and iPhone), so remotes are checked now and then
/// while the app isn't open: the system decides when, and runs no helper. The app handles the turn with SwiftUI's
/// `.backgroundTask(.appRefresh(VaultBackgroundRefresh.identifier))` and asks again at its end. Elsewhere it does
/// nothing (the Mac checks while an app is open).
///
/// ```swift
/// WindowGroup { … }
///   .backgroundTask(.appRefresh(VaultBackgroundRefresh.identifier)) { await model.refreshInBackground() }
/// VaultBackgroundRefresh.schedule(after: 15 * 60)
/// ```
public enum VaultBackgroundRefresh {
  /// The task's identifier; the app lists it under `BGTaskSchedulerPermittedIdentifiers`.
  public static let identifier = "dev.v57.vault.refresh"

  /// Asks for a turn no sooner than `interval` from now (the system may give it later, or not at all).
  public static func schedule(after interval: TimeInterval) {
    #if canImport(BackgroundTasks) && os(iOS)
      let request = BGAppRefreshTaskRequest(identifier: identifier)
      request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
      try? BGTaskScheduler.shared.submit(request)
    #endif
  }

  /// Takes back the request (remote checks turned off).
  public static func cancel() {
    #if canImport(BackgroundTasks) && os(iOS)
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    #endif
  }
}
