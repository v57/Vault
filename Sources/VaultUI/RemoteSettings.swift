#if os(macOS)
  import ComponentKit
  import CryptoKit
  import SwiftUI
  import VaultKit

  /// Settings ▸ Remote, the same in every Mac app: whether the user's other devices can reach this Mac over SSH (it
  /// publishes itself as a host, so Git and Code on iPhone and iPad find its projects and run them here), which of
  /// them can sign in, and the other keys in `~/.ssh/authorized_keys` (added by hand or by another tool), with Add
  /// Key… for a pasted one and Remove… for each. Put it in a `SettingsPane`.
  ///
  /// ```swift
  /// SettingsPane("Remote", systemImage: "network", hue: .teal, section: "v57") { VaultRemoteSettings() }
  /// ```
  public struct VaultRemoteSettings: View {
    @State private var vaults: Vaults
    private let keys: VaultAuthorizedKeys
    @State private var entries: [VaultAuthorizedKeys.Entry] = []
    @State private var allowed: Set<String> = []
    @State private var remoteLoginIsOn = true
    @State private var failure: String?
    @State private var addingKey = false
    @State private var removing: VaultAuthorizedKeys.Entry?
    @Environment(\.openURL) private var openURL

    public init(vaults: Vaults = .shared, keys: VaultAuthorizedKeys = .user) {
      _vaults = State(initialValue: vaults)
      self.keys = keys
    }

    /// The devices and this Mac's host live in the Personal vault.
    private var vault: Vault { vaults.personal }
    private var devices: [VaultDeviceKey] { vault.deviceKeys.filter { $0.id != vault.deviceID } }

    /// The keys in the file that aren't one of the user's devices'.
    private var otherKeys: [VaultAuthorizedKeys.Entry] {
      let deviceKeys = Set(vault.deviceKeys.compactMap { VaultAuthorizedKeys.keyMaterial(of: $0.publicKey) })
      return entries.filter { $0.device == nil && !deviceKeys.contains($0.material) }
    }

    public var body: some View {
      let host = vault.thisDeviceHost
      FormCard(
        "This Mac",
        footer: "Your iPhone and iPad find this Mac’s projects and work on them here over SSH, without a Hub. "
          + "Each device signs in with its own key, once you allow it below."
      ) {
        FormRow(
          "Let Your Devices In", help: host.map { "\($0.user)@\($0.hostname)" } ?? "Off",
          systemImage: "network", hue: .teal
        ) {
          Toggle(
            "Let Your Devices In",
            isOn: Binding(
              get: { vault.sharesThisMac },
              set: { isOn in
                if isOn { vault.shareThisMac() } else { vault.stopSharingThisMac(keys: keys) }
                reload()
              })
          )
          .toggleStyle(.kitSwitch).labelsHidden()
        }
        if !remoteLoginIsOn {
          FormRow(
            "Remote Login Is Off", help: "System Settings ▸ General ▸ Sharing: your devices can’t sign in until it’s on",
            systemImage: "exclamationmark.triangle", hue: .orange
          ) {
            Button("Open Sharing…") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") { openURL(url) }
            }
            .buttonStyle(.kit)
          }
        }
      }
      if host != nil {
        FormCard(
          "Your Devices",
          footer: devices.isEmpty ? "Your other devices show up here once a v57 app runs on them." : nil
        ) {
          ForEach(devices) { device in
            FormRow(
              device.deviceName, help: Self.fingerprint(device.publicKey), systemImage: Self.symbol(device), hue: .blue
            ) {
              Toggle(
                "Can Sign In",
                isOn: Binding(
                  get: { allowed.contains(device.id) },
                  set: { isOn in
                    vault.setAllowed(isOn, device: device, keys: keys)
                    reload()
                  })
              )
              .toggleStyle(.kitSwitch).labelsHidden()
            }
          }
        }
      }
      FormCard(
        "Other Keys",
        footer: "Other keys in ~/.ssh/authorized_keys, added by hand or by another app. Each can sign in to this Mac as you."
      ) {
        ForEach(otherKeys) { entry in
          FormRow(entry.comment ?? "Unnamed Key", help: Self.fingerprint(entry.line), systemImage: "key", hue: .gray) {
            Button("Remove…", role: .destructive) { removing = entry }.buttonStyle(.kit)
          }
        }
        FormRow("Add Key", help: "A public key line, e.g. from ~/.ssh/id_ed25519.pub", systemImage: "plus", hue: .gray) {
          Button("Add Key…") { addingKey = true }.buttonStyle(.kit)
        }
      }
      if let failure = failure ?? vault.error {
        Text(failure).kitFont(.caption).foregroundStyle(Hue.red.text)
      }
      Color.clear.frame(height: 0)
        .task {
          reload()
          remoteLoginIsOn = await Task.detached { VaultThisMac.remoteLoginIsOn() }.value
        }
        .kitSheet(isPresented: $addingKey) {
          VaultAddKeySheet { line in
            try keys.add(line: line)
            reload()
          }
        }
        .kitConfirmation(
          "Remove \(removing?.comment ?? "this key")?",
          isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }),
          message: "It can’t sign in to this Mac any more. Its line goes from ~/.ssh/authorized_keys.",
          systemImage: "key", confirm: "Remove"
        ) {
          guard let entry = removing else { return }
          do {
            try keys.remove(material: entry.material)
            failure = nil
          } catch {
            failure = error.localizedDescription
          }
          reload()
        }
    }

    private func reload() {
      do {
        entries = try keys.entries()
      } catch {
        failure = error.localizedDescription
      }
      allowed = vault.allowedDevices(keys: keys)
    }

    /// "SHA256:abcd…wxyz": a key line's fingerprint, shortened.
    static func fingerprint(_ line: String) -> String? {
      guard let material = VaultAuthorizedKeys.keyMaterial(of: line),
        let blob = Data(base64Encoded: String(material.split(separator: " ")[1]))
      else { return nil }
      let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
      return "SHA256:\(digest.prefix(4))…\(digest.suffix(4))"
    }

    static func symbol(_ device: VaultDeviceKey) -> String {
      let name = device.deviceName.lowercased()
      if device.platform == "iOS" { return name.contains("iphone") ? "iphone" : "ipad" }
      if name.contains("macbook") { return "laptopcomputer" }
      if device.platform == "windows" || device.platform == "linux" { return "pc" }
      return "desktopcomputer"
    }
  }

  /// Paste a public key line for `~/.ssh/authorized_keys`.
  private struct VaultAddKeySheet: View {
    let add: (String) throws -> Void
    @State private var line = ""
    @State private var failure: String?
    @Environment(\.kitDismiss) private var dismiss

    private var trimmed: String { line.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
      KitSheet(
        title: "Add Key", meta: "It can sign in to this Mac as you.", systemImage: "key", hue: .gray, width: 480
      ) {
        FormCard {
          FormRow(
            "Public Key", systemImage: "key", hue: .gray,
            error: !trimmed.isEmpty && !VaultAuthorizedKeys.isKeyLine(trimmed)
              ? "Paste one public key line, e.g. the contents of ~/.ssh/id_ed25519.pub." : failure,
            field: TextField("Public key", text: $line, prompt: Text("ssh-ed25519 AAAA… name@laptop"), axis: .vertical)
              .kitFont(.mono)
              .lineLimit(3...6)
              .autocorrectionDisabled())
        }
      } footer: {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Add") {
          do {
            try add(trimmed)
            dismiss()
          } catch {
            failure = error.localizedDescription
          }
        }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!VaultAuthorizedKeys.isKeyLine(trimmed))
      }
    }
  }
#endif
