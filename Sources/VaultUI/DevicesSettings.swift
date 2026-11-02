import ComponentKit
import SwiftUI
import VaultKit

/// Settings ▸ Devices, the same in every app: this device and the user's others. A row's context menu has Rename…, and
/// on the others Remove… (`Vaults.removeDevice`) for one they don't use any more, such as a Mac before its reinstall.
/// Put it in a `SettingsPane`.
///
/// ```swift
/// SettingsPane("Devices", systemImage: "laptopcomputer", hue: .blue, section: "v57") { VaultDevicesSettings() }
/// ```
public struct VaultDevicesSettings: View {
  @State private var vaults: Vaults
  @State private var renaming: VaultDeviceKey?
  @State private var removing: VaultDeviceKey?
  /// The accounts' vaults, opened outside the body (opening one writes `Vaults` state).
  @State private var opened: [Vault] = []
  @Environment(\.kitIdiom) private var idiom

  public init(vaults: Vaults = .shared) {
    _vaults = State(initialValue: vaults)
  }

  /// The devices live in the Personal vault.
  private var vault: Vault { vaults.personal }
  private var others: [VaultDeviceKey] { vault.deviceKeys.filter { $0.id != vault.deviceID } }

  public var body: some View {
    if let device = vault.deviceKeys.first(where: { $0.id == vault.deviceID }) {
      FormCard("This \(KitDevice.name)") { row(device) }
    }
    FormCard(
      "Your Other Devices",
      footer: others.isEmpty
        ? "Your other devices show up here once a v57 app runs on them."
        : "\(idiom == .mac ? "Right-click" : "Touch and hold") a device to rename or remove it. Removing tidies up after "
          + "one you don’t use any more. It doesn’t lock it out of your iCloud account."
    ) {
      ForEach(others) { row($0) }
    }
    if let error = vault.error {
      Text(error).kitFont(.caption).foregroundStyle(Hue.red.text)
    }
    Color.clear
      .frame(height: 0)
      .onChange(of: vaults.allAccounts, initial: true) {
        opened = vaults.allAccounts.compactMap { vaults.vault(for: $0) }
      }
      .kitSheet(item: $renaming) { VaultDeviceNameSheet(vault: vault, device: $0) }
      .kitConfirmation(
        "Remove \(removing?.deviceName ?? "this device")?",
        isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
        message: removing.map(message) ?? "", systemImage: "trash", confirm: "Remove"
      ) { [removing] in
        // The confirmation clears `removing` before it runs this.
        if let removing { vaults.removeDevice(removing.id) }
      }
  }

  private func row(_ device: VaultDeviceKey) -> some View {
    FormRow(device.deviceName, help: details(device), systemImage: device.systemImage, hue: .blue)
      .contentShape(Rectangle())
      .kitContextMenu {
        Button("Rename…") { renaming = device }
        if device.id != vault.deviceID {
          Button("Remove…", role: .destructive) { removing = device }
        }
      }
  }

  private func message(_ device: VaultDeviceKey) -> String {
    let onHub = vault.hubHosts.contains { vault.vaultDevice(of: $0) == device.id }
    return "It goes from every v57 app and can’t sign in to your Macs any more. Projects only on it go too, unless "
      + "their folders are on this \(KitDevice.name). If it still runs a v57 app, it comes back when that app opens."
      + (onHub ? " Its Hub keeps listing it until you remove it there." : "")
  }

  /// "macOS · 77 projects".
  private func details(_ device: VaultDeviceKey) -> String {
    let projects = opened.reduce(0) { count, vault in count + vault.projects.filter { $0.paths[device.id] != nil }.count }
    return [
      device.platform == "custom" ? nil : device.platform,
      projects == 0 ? nil : "\(projects) project\(projects == 1 ? "" : "s")",
    ].compactMap { $0 }.joined(separator: " · ")
  }
}

extension VaultDeviceKey {
  /// The device's symbol.
  var systemImage: String {
    let name = deviceName.lowercased()
    if platform == "iOS" { return name.contains("iphone") ? "iphone" : "ipad" }
    if name.contains("macbook") { return "laptopcomputer" }
    if platform == "windows" || platform == "linux" { return "pc" }
    return "desktopcomputer"
  }
}
