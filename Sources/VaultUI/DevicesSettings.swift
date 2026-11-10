import ComponentKit
import SwiftUI
import VaultKit

/// The user's devices, the same in every app: this one first, then the others. A row's context menu has Rename…, and
/// on the others Remove… (`Vaults.removeDevice`) for one they don't use any more, such as a Mac before its reinstall, and
/// Lost Device… (`VaultLostDeviceSheet`) for one they lost. Devices taken out that way are listed as not trusted.
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
  @State private var lost: VaultDeviceKey?
  @State private var trusting: VaultRevokedDevice?
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

  /// The app's note, then the card's own sentences, localized here since they're joined.
  private var footer: String {
    guard devices.contains(where: { $0.id != vault.deviceID }) else {
      return String(localized: "Your other devices show up here once a v57 app runs on them.")
    }
    return [
      note,
      idiom == .mac
        ? String(localized: "Right-click a device to rename or remove it.")
        : String(localized: "Touch and hold a device to rename or remove it."),
      String(localized: """
        Removing tidies up after one you don’t use any more. It doesn’t cut it off: it keeps the keys and passwords \
        it has, and it can come back. For one that’s lost or stolen, use Lost Device.
        """),
    ].compactMap { $0 }.joined(separator: " ")
  }

  public var body: some View {
    FormCard("Your Devices", footer: "\(footer)") {
      ForEach(devices) { row($0) }
    }
    if !vault.revokedDevices.isEmpty {
      FormCard(
        "Not Trusted",
        footer: "Taken out through Lost Device. What they publish is ignored, and Macs don’t let them in."
      ) {
        ForEach(vault.revokedDevices) { device in
          FormRow(device.name, help: notTrustedDetails(device), systemImage: "exclamationmark.shield", hue: .red) {
            Button("Trust Again…") { trusting = device }.buttonStyle(.kit)
          }
        }
      }
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
      .kitSheet(item: $lost) { VaultLostDeviceSheet(device: $0, vaults: vaults) }
      .kitConfirmation(
        "Trust \(trusting?.name ?? String(localized: "this device")) again?",
        isPresented: Binding { trusting != nil } set: { if !$0 { trusting = nil } },
        message: "It comes back the next time a v57 app runs on it. Do this only if you have it back.",
        systemImage: "checkmark.shield", confirm: "Trust Again"
      ) { [trusting] in
        if let trusting { vaults.trustAgain(trusting) }
      }
      .kitConfirmation(
        "Remove \(removing?.deviceName ?? String(localized: "this device"))?",
        isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
        message: "\(removing.map(message) ?? "")", systemImage: "trash", confirm: "Remove"
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
          Button("Lost Device…") { lost = device }
            .kitMenuPreview(VaultLostDeviceSheet.menuPreview(device.deviceName))
          Button("Remove…", role: .destructive) { removing = device }
        }
      }
  }

  private func message(_ device: VaultDeviceKey) -> String {
    let onHub = vault.hubHosts.contains { vault.vaultDevice(of: $0) == device.id }
    let message = String(localized: """
      It goes from every v57 app and can’t sign in to your Macs any more. Projects only on it go too, unless their \
      folders are on this \(KitDevice.name). This doesn’t cut it off: it keeps the keys and passwords it has, and if \
      it still runs a v57 app, it comes back when that app opens. For one that’s lost or stolen, use Lost Device.
      """)
    return onHub ? message + " " + String(localized: "Its Hub keeps listing it until you remove it there.") : message
  }

  private func notTrustedDetails(_ device: VaultRevokedDevice) -> String {
    let hasKey = vault.untrustedDeviceKeys.contains { $0.id == device.deviceID }
    return hasKey ? String(localized: "It has published itself since. It’s ignored.") : String(localized: "It hasn’t been heard from since.")
  }

  /// "This Mac · macOS · 77 projects".
  private func details(_ device: VaultDeviceKey) -> String {
    let projects = opened.reduce(0) { count, vault in count + vault.projects.filter { $0.paths[device.id] != nil }.count }
    return [
      device.id == vault.deviceID ? String(localized: "This \(KitDevice.name)") : nil,
      device.platform == "custom" ? nil : device.systemName,
      projects == 0 ? nil : projects == 1 ? String(localized: "1 project") : String(localized: "\(projects) projects"),
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
    if platform == "iOS" { return model.map { $0 == "iPhone" } ?? name.contains("iphone") ? "iphone" : "ipad" }
    if name.contains("macbook") { return "laptopcomputer" }
    if platform == "windows" || platform == "linux" { return "pc" }
    return "desktopcomputer"
  }
}
