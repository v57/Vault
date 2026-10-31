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
    var option: VaultProfileOption?
    /// The saved profile when only `option` is asked about (the confirmation, not the Your Name sheet).
    var saved: VaultProfile?
    var answer: CheckedContinuation<VaultProfileAnswer?, Never>
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
    await answer(for: account, vaults: vaults, reason: reason, gitHub: gitHub, option: nil)?.profile
  }

  /// The profile, as `profile(for:reason:gitHub:)` gets it, and the user's answer to `option`: the Your Name sheet
  /// shows it as a switch (off); with a saved profile, a confirmation asks it instead. Only cancelling the Your Name
  /// sheet answers nil; declining the confirmation, or dismissing it, answers false.
  public func answer(
    for account: VaultAccount, vaults: Vaults = .shared, reason: String? = nil,
    gitHub: (name: String?, email: String?)? = nil, option: VaultProfileOption?
  ) async -> VaultProfileAnswer? {
    let saved = vaults.profile(for: account)
    if saved.isComplete, option == nil { return VaultProfileAnswer(profile: saved, option: false) }
    guard pending == nil else { return nil }
    return await withCheckedContinuation { answer in
      pending = Pending(
        account: account, vaults: vaults, reason: reason, gitHub: gitHub, option: option,
        saved: saved.isComplete ? saved : nil, answer: answer)
    }
  }

  /// Ends the request (nil: cancelled). Runs once per sheet.
  func finish(_ answer: VaultProfileAnswer?) {
    guard let pending else { return }
    self.pending = nil
    // The confirmation's dismissal is a no; only the Your Name sheet can be cancelled.
    pending.answer.resume(returning: answer ?? pending.saved.map { VaultProfileAnswer(profile: $0, option: false) })
  }
}

/// A choice an app offers along with the name and email, e.g. Git's "Use in Terminal too": off unless the user says so.
public struct VaultProfileOption: Sendable, Hashable {
  public var title: String
  /// What turning it on does.
  public var help: String
  public var systemImage: String
  /// The confirmation's buttons, when the profile is already saved.
  public var accept: String
  public var decline: String

  public init(title: String, help: String, systemImage: String, accept: String, decline: String) {
    self.title = title
    self.help = help
    self.systemImage = systemImage
    self.accept = accept
    self.decline = decline
  }
}

/// What `VaultProfileRequest.answer(for:option:)` got: the profile, and whether the user turned the option on.
public struct VaultProfileAnswer: Sendable, Hashable {
  public var profile: VaultProfile
  public var option: Bool
}

extension View {
  /// Shows the Your Name sheet, or the option's confirmation, when `request` asks
  /// (`VaultProfileRequest.profile(for:reason:)`, `answer(for:option:)`).
  public func vaultProfileRequests(_ request: VaultProfileRequest) -> some View {
    kitSheet(item: Binding { request.pending } set: { if $0 == nil { request.finish(nil) } }) { pending in
      if let saved = pending.saved, let option = pending.option {
        VaultProfileOptionSheet(profile: saved, account: pending.account, option: option) {
          request.finish(VaultProfileAnswer(profile: saved, option: $0))
        }
      } else {
        VaultProfileSheet(
          account: pending.account, vaults: pending.vaults, gitHub: pending.gitHub, reason: pending.reason,
          option: pending.option
        ) { request.finish(VaultProfileAnswer(profile: $0, option: $1)) }
      }
    }
  }
}

/// Asks an option about a profile that's already saved: "Use in Terminal too?" for Ada Lovelace <ada@example.com>.
struct VaultProfileOptionSheet: View {
  var profile: VaultProfile
  var account: VaultAccount
  var option: VaultProfileOption
  var done: (Bool) -> Void
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    KitSheet(title: "\(option.title)?", meta: profile.signature, width: 440) {
      Avatar(name: profile.name, kind: .person, hue: account.hue, size: 32)
    } content: {
      Text(option.help)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    } footer: {
      Button(option.decline) { answer(false) }
        .keyboardShortcut(.cancelAction)
      Button(option.accept) { answer(true) }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
  }

  private func answer(_ on: Bool) {
    done(on)
    dismiss()
  }
}
