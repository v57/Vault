import ComponentKit
import SwiftUI
import VaultKit

// A window shows one account (../Ideas/Accounts.md): `VaultAccountScope` at the window's root resolves the account
// the window keeps (`@SceneStorage`) to its vault, hands that vault to the content and down the environment, and
// rebuilds the content when the account changes, so nothing of one account stays on screen in another.
// `VaultAccountPicker` anywhere under it switches the account; New Account… opens here.

extension EnvironmentValues {
  /// The window's vault: Personal, or the account the window shows. Nil outside a `VaultAccountScope`.
  @Entry public var vault: Vault? = nil
  /// The window's account switch, for `VaultAccountPicker`. Nil outside a `VaultAccountScope`.
  @Entry public var vaultAccountWindow: VaultAccountWindow? = nil
}

/// What `VaultAccountScope` gives the picker: the window's account and what its menu does.
public struct VaultAccountWindow: Sendable {
  /// The account the window shows.
  public var selection: Binding<String>
  var newAccount: @MainActor @Sendable () -> Void
  var manage: (@MainActor @Sendable () -> Void)?
  var openInNewWindow: (@MainActor @Sendable (String) -> Void)?
}

/// The window's account: put it at the root of a window's content, with the account the window keeps.
///
/// ```swift
/// @SceneStorage("vault.account") private var accountID = VaultAccount.personal.id
///
/// VaultAccountScope(selection: $accountID, manage: { openSettings() },
///                   openInNewWindow: { openWindow(id: "main", value: $0) }) { vault in
///   ContentView(model: AppModel(vault: vault))
/// }
/// ```
///
/// The content is rebuilt (`.id`) for each account, so state made from the vault starts over. A window holding work
/// that must outlive a switch (an unsaved document, a running job) passes `rebuildsContent: false` and follows
/// `@Environment(\.vault)` itself. An account that is deleted, or whose store can't open, falls back to Personal.
public struct VaultAccountScope<Content: View>: View {
  @Binding var selection: String
  var rebuildsContent: Bool
  var manage: (@MainActor @Sendable () -> Void)?
  var openInNewWindow: (@MainActor @Sendable (String) -> Void)?
  var content: (Vault) -> Content
  @State private var vaults = Vaults.shared
  @State private var opened: Vault?
  @State private var creating = false

  public init(
    selection: Binding<String>, rebuildsContent: Bool = true, manage: (@MainActor @Sendable () -> Void)? = nil,
    openInNewWindow: (@MainActor @Sendable (String) -> Void)? = nil, @ViewBuilder content: @escaping (Vault) -> Content
  ) {
    _selection = selection
    self.rebuildsContent = rebuildsContent
    self.manage = manage
    self.openInNewWindow = openInNewWindow
    self.content = content
  }

  /// Personal is there from the first frame; an account's vault opens in `open()`, which writes `Vaults` state and
  /// so can't run during the body. Until it has (a frame), the content keeps the vault it had, so nothing blinks.
  private var vault: Vault {
    if selection == VaultAccount.personal.id { return vaults.personal }
    return opened ?? vaults.personal
  }

  public var body: some View {
    content(vault)
      .id(rebuildsContent ? vault.accountID : "")
      .environment(\.vault, vault)
      .environment(
        \.vaultAccountWindow,
        VaultAccountWindow(
          selection: $selection, newAccount: { [$creating] in $creating.wrappedValue = true }, manage: manage,
          openInNewWindow: openInNewWindow)
      )
      .kitSheet(isPresented: $creating) {
        VaultAccountSheet(account: nil) { selection = $0.id }
      }
      .onChange(of: selection, initial: true) { open() }
      .onChange(of: vaults.accounts) { open() }
  }

  private func open() {
    guard selection != VaultAccount.personal.id else { return }
    if let account = vaults.account(id: selection), let vault = vaults.vault(for: account) {
      if opened !== vault { opened = vault }
    } else {
      selection = VaultAccount.personal.id
    }
  }
}
