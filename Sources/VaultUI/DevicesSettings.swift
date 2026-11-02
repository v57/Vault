import ComponentKit
import SwiftUI
import VaultKit

/// The user's devices, the same in every app: this one first, then the others. A row's context menu has Rename…, and
/// on the others Remove… (`Vaults.removeDevice`) for one they don't use any more, such as a Mac before its reinstall.
/// Settings ▸ Remote shows it on the Mac, with a switch on each device (`control`); iPhone and iPad put it in their
/// settings.
///
/// ```swift
/// VaultDevicesSettings()
/// VaultDevicesSettings(note: "Turn on the devices that can sign in.") { device in Toggle(…) }
/// ```
public struct VaultDevicesSettings<Control: View>: View {
  @State private var vaults: Vaults
  @State private var renaming: VaultDeviceKey?
  @State private var removing: VaultDeviceKey?
  /// The accounts' vaults, opened outside the body (opening one writes `Vaults` state).
  @State private var opened: [Vault] = []
  private let note: String?
  @ViewBuilder private let control: (VaultDeviceKey) -> Control
  @Environment(\.kitIdiom) private var idiom

  /// - Parameters:
  ///   - note: what the card's footer says first, about `control`.
  ///   - control: a row's trailing control.
  public init(
    vaults: Vaults = .shared, note: String? = nil, @ViewBuilder control: @escaping (VaultDeviceKey) -> Control
  ) {
    _vaults = State(initialValue: vaults)
    self.note = note
    self.control = control
  }

  /// The devices live in the Personal vault.
  private var vault: Vault { vaults.personal }
  /// This device first, then the others by name.
  private var devices: [VaultDeviceKey] {
    vault.deviceKeys.filter { $0.id == vault.deviceID } + vault.deviceKeys.filter { $0.id != vault.deviceID }
  }

  private var footer: String {
    guard devices.contains(where: { $0.id != vault.deviceID }) else {
      return "Your other devices show up here once a v57 app runs on them."
    }
    return [
      note,
      "\(idiom == .mac ? "Right-click" : "Touch and hold") a device to rename or remove it. Removing tidies up after one "
        + "you don’t use any more. It doesn’t lock it out of your iCloud account.",
    ].compactMap { $0 }.joined(separator: " ")
  }

  public var body: some View {
    FormCard("Your Devices", footer: footer) {
      ForEach(devices) { row($0) }
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
    FormRow(device.deviceName, help: details(device), systemImage: device.systemImage, hue: .blue) {
      control(device)
    }
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

  /// "This Mac · macOS · 77 projects".
  private func details(_ device: VaultDeviceKey) -> String {
    let projects = opened.reduce(0) { count, vault in count + vault.projects.filter { $0.paths[device.id] != nil }.count }
    return [
      device.id == vault.deviceID ? "This \(KitDevice.name)" : nil,
      device.platform == "custom" ? nil : device.platform,
      projects == 0 ? nil : "\(projects) project\(projects == 1 ? "" : "s")",
    ].compactMap { $0 }.joined(separator: " · ")
  }
}

extension VaultDevicesSettings where Control == EmptyView {
  /// The devices with nothing at the end of their rows.
  public init(vaults: Vaults = .shared) {
    self.init(vaults: vaults) { _ in EmptyView() }
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
