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

  /// Whether the lock applies to this run at all: never in demo runs or tests, which hold no real secrets.
  let isActive: Bool

  private init() {
    isActive = !LaunchOptions.flag("--demo") && !VaultSecrets.isInMemory
    isLocked = isActive && VaultAppLock.isEnabled
  }

  /// Asks at once (the launch, the return), whatever the grace period says.
  func unlock() async {
    guard isLocked, !isAsking else { return }
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

  func body(content: Content) -> some View {
    content
      .kitSecretAccess(lock.isActive ? { label in await AppLock.shared.allow(label) } : nil)
      .overlay {
        if lock.isLocked {
          LockScreen()
            .transition(.opacity)
        }
      }
      .onChange(of: scenePhase, initial: true) { _, phase in
        lock.phaseChanged(to: phase)
        if phase == .active, lock.isLocked { Task { await lock.unlock() } }
      }
  }
}

/// What a locked window shows: nothing of the vault, and the button that asks again.
private struct LockScreen: View {
  @State private var lock = AppLock.shared

  var body: some View {
    EmptyState(
      systemImage: "lock", title: "Vault Is Locked",
      message: "Unlock with Touch ID, Face ID or your password to see your passwords, cards and documents."
    ) {
      Button("Unlock") { Task { await lock.unlock() } }
        .buttonStyle(.kit)
        .disabled(lock.isAsking)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.kitWindow)
    .contentShape(Rectangle())
    .accessibilityAddTraits(.isModal)
  }
}
