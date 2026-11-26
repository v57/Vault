import ComponentKit
import SwiftUI
import VaultKit

/// The app lock's state in the windows (security audit M13; `VaultAppLock` keeps the setting and the grace period):
/// locked at launch, and again when Vault comes back after more than five minutes away. Demo runs never lock.
@MainActor @Observable
final class AppLock {
  static let shared = AppLock()

  /// Whether the windows show the lock screen instead of the vault.
  private(set) var isLocked: Bool
  /// Whether the system question is up (the lock screen's button waits for it).
  private(set) var isAsking = false
  /// When Vault last stopped being the app in front.
  private var leftAt: Date?
  /// Whether the next return to the front asks by itself: after the launch and after a lock for time away, once.
  /// A cancelled question leaves the lock screen and its Unlock button (the system's question makes the scene
  /// inactive and active again, so asking on every return asked again at once, for good).
  private(set) var asksOnReturn = false

  /// Whether the lock applies to this run at all: never in demo runs or tests, which hold no real secrets.
  let isActive: Bool

  private init() {
    isActive = !LaunchOptions.flag("--demo") && !VaultSecrets.isInMemory
    isLocked = isActive && VaultAppLock.isEnabled
    asksOnReturn = isLocked
  }

  /// Asks at once (the launch, the return), whatever the grace period says.
  func unlock() async {
    guard isLocked, !isAsking else { return }
    asksOnReturn = false
    isAsking = true
    defer { isAsking = false }
    if await VaultAppLock.unlockNow(reason: String(localized: "open your vault")) { isLocked = false }
  }

  /// Before a secret is shown or copied: asks unless an unlock less than five minutes ago still holds.
  func allow(_ label: String) async -> Bool {
    guard isActive else { return true }
    return await VaultAppLock.unlock(reason: String(localized: "show or copy “\(label)”"))
  }

  /// Locks again when Vault comes back after more than `VaultAppLock.grace` away.
  func phaseChanged(to phase: ScenePhase) {
    guard isActive else { return }
    if phase == .active {
      if let leftAt, Date().timeIntervalSince(leftAt) >= VaultAppLock.grace || Date() < leftAt, VaultAppLock.isEnabled {
        VaultAppLock.lockNow()
        isLocked = true
        asksOnReturn = true
      }
      leftAt = nil
    } else if leftAt == nil {
      leftAt = Date()
    }
  }

  /// The setting changed: off unlocks the windows, on locks nothing until the next launch or return.
  func enabledChanged() {
    if !VaultAppLock.isEnabled { isLocked = false }
  }
}

extension View {
  /// Covers the window with the lock screen while Vault is locked, and asks before a secret in it is shown or copied.
  func appLock() -> some View {
    modifier(AppLockCover())
  }
}

private struct AppLockCover: ViewModifier {
  @State private var lock = AppLock.shared
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.kitIdiom) private var idiom

  func body(content: Content) -> some View {
    content
      .kitSecretAccess(lock.isActive ? { label in await AppLock.shared.allow(label) } : nil)
      // Above the window's sheets and full-screen covers too (the first-run welcome, Add Document), which an
      // overlay on the content left showing. On iPhone and iPad it also covers the window whenever the scene isn't
      // active, so the app switcher's snapshot shows no revealed password or code.
      .kitCover(isPresented: lock.isLocked || idiom.isTouch && scenePhase != .active) {
        LockScreen(showsUnlock: lock.isLocked)
      }
      .onChange(of: scenePhase, initial: true) { _, phase in
        lock.phaseChanged(to: phase)
        if phase == .active, lock.isLocked, lock.asksOnReturn { Task { await lock.unlock() } }
      }
  }
}

/// What a locked window shows: nothing of the vault, and the button that asks again.
private struct LockScreen: View {
  /// Locked: the message and Unlock. Unlocked (the app switcher's snapshot), the lock alone.
  var showsUnlock: Bool
  @State private var lock = AppLock.shared

  var body: some View {
    Group {
      if showsUnlock {
        EmptyState(
          systemImage: "lock", title: "Vault Is Locked",
          message: "Unlock with Touch ID, Face ID or your password to see your passwords, cards and documents."
        ) {
          Button("Unlock") { Task { await lock.unlock() } }
            .buttonStyle(.kit)
            .disabled(lock.isAsking)
        }
      } else {
        Image(systemName: "lock").font(.system(size: 34)).foregroundStyle(.kitTertiary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.kitWindow)
    .contentShape(Rectangle())
    .accessibilityAddTraits(.isModal)
  }
}
