import ComponentKit
import Observation
import SwiftUI
import VaultKit

/// Asks for an account's name and email only when an app needs them, once: `profile(for:reason:)` returns the saved
/// profile when it is complete, and otherwise shows the Your Name sheet (prefilled) and returns what the user saved,
/// or nil when they cancelled. Apps call it right before the thing that needs it (a commit, adding a key), never at
/// launch; once saved, every app on every device has it and nobody asks again. Show its sheet with
/// `.vaultProfileRequests(_:)` on the window's root view.
///
/// ```swift
/// @State private var profiles = VaultProfileRequest()
/// guard let profile = await profiles.profile(for: account, reason: "Git puts them on this commit.") else { return }
/// .vaultProfileRequests(profiles)
/// ```
@MainActor @Observable
public final class VaultProfileRequest {
  /// The sheet on screen, if any.
  struct Pending: Identifiable {
    let id = UUID()
    var account: VaultAccount
    var vaults: Vaults
    var reason: String?
    var gitHub: (name: String?, email: String?)?
    var answer: CheckedContinuation<VaultProfile?, Never>
  }

  var pending: Pending?

  public init() {}

  /// The account's complete profile: the saved one, else what the user enters in the Your Name sheet (nil when they
  /// cancel). `reason` says why the app asks now; `gitHub` is the account's GitHub sign-in, for the prefill. A second
  /// request while the sheet is up gets nil.
  public func profile(
    for account: VaultAccount, vaults: Vaults = .shared, reason: String? = nil,
    gitHub: (name: String?, email: String?)? = nil
  ) async -> VaultProfile? {
    let saved = vaults.profile(for: account)
    if saved.isComplete { return saved }
    guard pending == nil else { return nil }
    return await withCheckedContinuation { answer in
      pending = Pending(account: account, vaults: vaults, reason: reason, gitHub: gitHub, answer: answer)
    }
  }

  /// Ends the request with what was saved (nil: cancelled). Runs once per sheet.
  func finish(_ profile: VaultProfile?) {
    guard let pending else { return }
    self.pending = nil
    pending.answer.resume(returning: profile)
  }
}

extension View {
  /// Shows the Your Name sheet when `request` asks (`VaultProfileRequest.profile(for:reason:)`).
  public func vaultProfileRequests(_ request: VaultProfileRequest) -> some View {
    kitSheet(item: Binding { request.pending } set: { if $0 == nil { request.finish(nil) } }) { pending in
      VaultProfileSheet(
        account: pending.account, vaults: pending.vaults, gitHub: pending.gitHub, reason: pending.reason
      ) { request.finish($0) }
    }
  }
}
