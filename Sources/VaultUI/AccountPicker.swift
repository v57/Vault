import ComponentKit
import SwiftUI
import VaultKit

/// The window's account picker: ComponentKit's `KitAccountPicker` over the vault's accounts, switching the
/// `VaultAccountScope` it is in. Put it first in the sidebar (`.compact` in a device chooser's header); it draws
/// nothing while Personal is the only account, or outside a scope.
///
/// ```swift
/// KitSidebar(selection: $selection) {
///   VaultAccountPicker(meta: "\(projects.count) projects")
///   KitSection("Projects", …) { … }
/// }
/// ```
public struct VaultAccountPicker: View {
  var meta: String?
  var style: KitAccountPicker.Style
  @Environment(\.vaultAccountWindow) private var window
  @State private var vaults = Vaults.shared

  public init(meta: String? = nil, style: KitAccountPicker.Style = .sidebar) {
    self.meta = meta
    self.style = style
  }

  public var body: some View {
    if let window {
      KitAccountPicker(
        accounts: vaults.allAccounts.map(\.kitAccount), selection: window.selection, meta: meta, style: style,
        openInNewWindow: window.openInNewWindow.map { open in { open($0) } }, newAccount: { window.newAccount() },
        manage: window.manage.map { manage in { manage() } })
    }
  }
}

extension VaultAccount {
  /// The account as ComponentKit's picker shows it.
  public var kitAccount: KitAccount { KitAccount(id: id, name: name, hue: hue) }

  /// Its tile's hue (`color` is a ComponentKit hue's name).
  public var hue: Hue { Hue(rawValue: color) ?? .blue }
}
