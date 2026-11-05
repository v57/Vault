import ComponentKit
import SwiftUI
import VaultKit

/// Settings ▸ Privacy's switch for iCloud (`VaultICloud`): one for every v57 app on this device, since they share what
/// syncs, so turning it off in one app turns it off in all of them. Where the platform has no iCloud it says so.
///
/// ```swift
/// SettingsPane("Privacy", systemImage: "hand.raised", hue: .blue) { VaultICloudCard() }
/// ```
public struct VaultICloudCard: View {
  @State private var status = VaultICloudStatus.shared
  @State private var isConfirming = false

  public init() {}

  public var body: some View {
    if VaultICloud.isSupported {
      FormCard("iCloud", footer: footer) {
        FormRow(
          "Use iCloud", help: "\(status.isOff ? "Off" : "On") for every v57 app on this device", systemImage: "icloud",
          hue: .blue
        ) {
          Toggle("Use iCloud", isOn: isOn)
            .toggleStyle(.kitSwitch)
            .kitLabelsHidden()
        }
        if let error = status.error {
          FormRow("Couldn’t change it", help: error, systemImage: "exclamationmark.triangle", hue: .red)
        }
      }
      .kitConfirmation(
        "Turn Off iCloud?", isPresented: $isConfirming,
        message: "Every v57 app on this device stops syncing through iCloud and iCloud Keychain. What’s already there "
          + "stays, and your other devices keep it.",
        systemImage: "icloud.slash", confirm: "Turn Off"
      ) {
        withAnimation(.kit) { status.setOff(true) }
      }
    } else {
      FormCard("iCloud") {
        FormRow("Not on this device", help: "iCloud is only on Apple devices.", systemImage: "icloud.slash", hue: .gray)
      }
    }
  }

  private var isOn: Binding<Bool> {
    Binding {
      !status.isOff
    } set: { on in
      if on {
        withAnimation(.kit) { status.setOff(false) }
      } else {
        isConfirming = true
      }
    }
  }

  private var footer: String {
    status.isOff
      ? "Nothing goes to iCloud from this device. Changes stay here, and go up if you turn it on again. What’s already "
        + "in iCloud stays there."
      : "Keeps your v57 data on your other devices, encrypted on this device first. Passwords and keys go through "
        + "iCloud Keychain."
  }
}
