import ComponentKit
import SwiftUI
import VaultKit

/// Renames a device: this one (no `device`) or another of the user's (`VaultDeviceKey`). The name goes on its
/// SSH key, the Hub, the `authorized_keys` lines Vault writes and the host other devices see (`VaultDevice.name`);
/// empty goes back to the system's.
public struct VaultDeviceNameSheet: View {
  var vault: Vault
  var device: VaultDeviceKey?
  @Environment(\.kitDismiss) private var dismiss
  @State private var name: String

  public init(vault: Vault = Vaults.shared.personal, device: VaultDeviceKey? = nil) {
    self.vault = vault
    self.device = device
    _name = State(initialValue: device?.customName ?? (device == nil ? VaultDevice.customName : nil) ?? "")
  }

  private var isThisDevice: Bool { device == nil || device?.id == vault.deviceID }
  /// What an empty name means.
  private var placeholder: String { isThisDevice ? VaultDevice.systemName : device?.deviceName ?? "" }

  public var body: some View {
    KitSheet(
      title: isThisDevice ? "Rename This \(KitDevice.name)" : "Rename \(device?.deviceName ?? "Device")",
      meta: "Your Hub, its SSH key and the servers that let it in show it.",
      systemImage: KitDevice.systemImage, hue: .gray
    ) {
      FormCard(footer: "Leave it empty to use \(placeholder).") {
        FormRow(
          "Name", help: isThisDevice ? "This device's name" : "Every app on it goes by it", systemImage: "character.cursor.ibeam",
          hue: .gray, field: TextField(placeholder, text: $name).autocorrectionDisabled())
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Rename") {
        vault.renameDevice(device?.id ?? vault.deviceID, to: name)
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
    }
  }
}
