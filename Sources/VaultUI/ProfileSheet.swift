import ComponentKit
import SwiftUI
import VaultKit

/// Your Name: the name and email an account goes by on commits, on servers' `authorized_keys` and on the user's Hub
/// (`VaultProfile`). The first app that needs them shows it, prefilled from what the device already has
/// (`Vaults.suggestedProfile(for:gitHub:)`); Settings ▸ Accounts edits them. Present it with `.kitSheet`.
///
/// ```swift
/// if !Vaults.shared.profile(for: account).isComplete { askingName = true }
/// .kitSheet(isPresented: $askingName) {
///   VaultProfileSheet(account: account, reason: "Git signs this commit with them.") { commit(as: $0) }
/// }
/// ```
public struct VaultProfileSheet: View {
  var account: VaultAccount
  var vaults: Vaults
  var reason: String?
  var done: (VaultProfile) -> Void
  @Environment(\.kitDismiss) private var dismiss
  @State private var name: String
  @State private var email: String

  /// `gitHub`: the account's GitHub sign-in, when the app has one (its name, and its email if the token may read it),
  /// for the prefill; `reason`: why the app asks now, under the sheet's title; `done` gets what was saved.
  public init(
    account: VaultAccount, vaults: Vaults = .shared, gitHub: (name: String?, email: String?)? = nil,
    reason: String? = nil, done: @escaping (VaultProfile) -> Void = { _ in }
  ) {
    self.account = account
    self.vaults = vaults
    self.reason = reason
    self.done = done
    let suggested = vaults.suggestedProfile(for: account, gitHub: gitHub)
    _name = State(initialValue: suggested.name)
    _email = State(initialValue: suggested.email)
  }

  private var profile: VaultProfile { VaultProfile(account: account.id, name: name, email: email).trimmed }

  /// Why the email can't be saved, nil when it can (or is still empty).
  private var emailError: String? {
    let email = profile.email
    guard !email.isEmpty else { return nil }
    return Self.isEmail(email) ? nil : "Not an email address"
  }

  /// One `@` with something on both sides, a dot in the domain and no spaces: enough to catch a slip, not RFC 5322.
  static func isEmail(_ text: String) -> Bool {
    let parts = text.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !text.contains(where: \.isWhitespace) else { return false }
    let domain = parts[1]
    return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
  }

  public var body: some View {
    let profile = profile
    KitSheet(
      title: account.isPersonal ? "Your Name" : "Your Name at \(account.name)",
      meta: [reason, Self.uses].compactMap { $0 }.joined(separator: " ")
    ) {
      Avatar(name: profile.name.isEmpty ? "?" : profile.name, kind: .person, hue: account.hue, size: 32)
    } content: {
      FormCard(footer: account.isPersonal ? nil : "Use the address \(account.name) knows you by: its commits go out with it.") {
        FormRow(
          "Name", help: "As people should see it", systemImage: "person", hue: account.hue,
          field: TextField("Ada Lovelace", text: $name).autocorrectionDisabled())
        FormRow(
          "Email", help: "For git, GitHub matches it to your account", systemImage: "envelope", hue: account.hue,
          error: emailError, field: emailField)
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Save") { save() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!profile.isComplete || emailError != nil)
    }
  }

  static let uses =
    "Your commits, your keys on servers and your Hub show them. They stay in your vault: the terminal's git settings don't change."

  private var emailField: some View {
    let field = TextField("ada@example.com", text: $email).autocorrectionDisabled()
    #if os(iOS)
      return field.keyboardType(.emailAddress).textInputAutocapitalization(.never).textContentType(.emailAddress)
    #else
      return field.textContentType(.emailAddress)
    #endif
  }

  private func save() {
    let profile = profile
    guard profile.isComplete, emailError == nil else { return }
    vaults.save(profile)
    done(profile)
    dismiss()
  }
}
