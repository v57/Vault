import Foundation

/// Whether the app runs in Apple's App Sandbox, and where it keeps its own data either way, so an app can ship with
/// the sandbox (the App Store) and without it (a direct download) from the same code.
///
/// On the Mac a sandboxed app's Application Support and Documents are its container's
/// (`~/Library/Containers/<bundle id>/Data/…`). Without the sandbox they are the user's own, shared by every app, so the
/// app keeps its data in `Application Support/<bundle id>/` instead (`supportDirectory`, `documentsDirectory`), and
/// `carryOverContainer()` copies what an earlier sandboxed build kept there. iPhone and iPad apps are always
/// sandboxed. On Windows and Linux there's no sandbox and the platform's folders stay as they are.
///
/// ```swift
/// AppSandbox.carryOverContainer()                       // first thing at launch
/// let store = AppSandbox.supportDirectory.appendingPathComponent("default.store")
/// if let folder = await VaultFolderAccess.request(project, name: "Atlas") { open(folder) }  // VaultUI
/// ```
public enum AppSandbox {
  /// Whether the app runs in the sandbox: the system sets `APP_SANDBOX_CONTAINER_ID` for a sandboxed Mac app.
  public static let isOn: Bool = {
    #if os(macOS)
      ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    #elseif canImport(UIKit)
      true
    #else
      false
    #endif
  }()

  /// The app's own folder for its data: Application Support in the sandbox (the container's), and
  /// `Application Support/<bundle id>` on a Mac without it. Not created here.
  public static var supportDirectory: URL {
    #if os(macOS)
      if !isOn { return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID, isDirectory: true) }
    #endif
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  }

  /// The app's documents: Documents in the sandbox (the container's), and `Documents` in `supportDirectory` on a Mac
  /// without it (the user's own Documents is theirs, not the app's).
  public static var documentsDirectory: URL {
    #if os(macOS)
      if !isOn { return supportDirectory.appendingPathComponent("Documents", isDirectory: true) }
    #endif
    // FileManager rather than `URL.documentsDirectory`, which corelibs Foundation (Linux, Windows) doesn't have.
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }

  /// The data folder of the app's sandbox container (`~/Library/Containers/<bundle id>/Data`), where a sandboxed build
  /// of it kept its data; nil in the sandbox and where there's none.
  public static var containerData: URL? {
    #if os(macOS)
      guard !isOn else { return nil }
      let data = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Containers/\(bundleID)/Data", isDirectory: true)
      return FileManager.default.fileExists(atPath: data.path) ? data : nil
    #else
      return nil
    #endif
  }

  /// Carries the app's data over from its sandbox container, once, the first time it runs on a Mac without the
  /// sandbox: the settings into `UserDefaults.standard` (the keys it hasn't set), Application Support into
  /// `supportDirectory` and Documents into `documentsDirectory`, each while the new one doesn't exist yet. Copies: the
  /// container keeps the originals. Call it first thing at launch, before anything reads the settings or the files.
  public static func carryOverContainer(defaults: UserDefaults = .standard) {
    guard let data = containerData, !defaults.bool(forKey: carriedOverKey) else { return }
    let fileManager = FileManager.default
    let preferences = data.appendingPathComponent("Library/Preferences/\(bundleID).plist")
    if let settings = NSDictionary(contentsOf: preferences) as? [String: Any] {
      for (key, value) in settings where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
    }
    let folders = [
      (data.appendingPathComponent("Library/Application Support", isDirectory: true), supportDirectory),
      (data.appendingPathComponent("Documents", isDirectory: true), documentsDirectory),
    ]
    for (old, new) in folders where fileManager.fileExists(atPath: old.path) && !fileManager.fileExists(atPath: new.path) {
      try? fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fileManager.copyItem(at: old, to: new)
    }
    defaults.set(true, forKey: carriedOverKey)
  }

  private static let carriedOverKey = "AppSandbox.carriedOverContainer"

  private static var bundleID: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }
}
