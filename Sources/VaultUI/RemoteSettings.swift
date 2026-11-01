#if os(macOS)
  import ComponentKit
  import CryptoKit
  import SwiftUI
  import VaultKit

  /// Settings ▸ Remote, the same in every Mac app: whether the user's other devices can reach this Mac over SSH (it
  /// publishes itself as a host, so the v57 apps on the user's other devices find its projects and work on them here), which of
  /// them can sign in, and the other keys in `~/.ssh/authorized_keys` (added by hand or by another tool), with Add
  /// Key… for a pasted one and Remove… for each. Until Remote Login is on, letting devices in is locked and the pane
  /// says what it would bring; once it's on, it offers to turn password login off. Put it in a `SettingsPane`.
  ///
  /// ```swift
  /// SettingsPane("Remote", systemImage: "network", hue: .teal, section: "v57") { VaultRemoteSettings() }
  /// ```
  public struct VaultRemoteSettings: View {
    @State private var vaults: Vaults
    private let keys: VaultAuthorizedKeys
    @State private var entries: [VaultAuthorizedKeys.Entry] = []
    @State private var allowed: Set<String> = []
    /// Whether sshd answers here; nil until the first check. Checked every two seconds while the pane shows, so
    /// turning it on in System Settings shows up here.
    @State private var remoteLoginIsOn: Bool?
    @State private var passwordLoginIsOn = true
    @State private var changingPasswordLogin = false
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
      let loginIsOn = remoteLoginIsOn ?? false
      FormCard(
        "This Mac",
        footer: loginIsOn
          ? "Your other devices find this Mac’s projects and work on them here over SSH, without a Hub. "
            + "Each device signs in with its own key, once you allow it below." : nil
      ) {
        if remoteLoginIsOn == false {
          FormRow(
            "Remote Login Is Off",
            help: "Turn it on in System Settings ▸ General ▸ Sharing; this page notices when it’s on.",
            systemImage: "lock", hue: .orange
          ) {
            Button("Open Sharing…") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") { openURL(url) }
            }
            .buttonStyle(.kit)
          }
        }
        FormRow(
          "Let Your Devices In",
          help: !loginIsOn && host == nil ? "Needs Remote Login" : host.map { "\($0.user)@\($0.hostname)" } ?? "Off",
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
          // Locked until sshd answers: turning it on would publish a Mac nobody can sign in to. Turning off stays.
          .disabled(!loginIsOn && host == nil)
        }
      }
      if remoteLoginIsOn == false {
        FormCard(
          "With Remote Login On",
          footer: "From the v57 apps on your other devices. Each device signs in with its own key, and only once you "
            + "allow it here. Nothing else changes."
        ) {
          // What the v57 apps on the user's other devices (Mac, iPhone, iPad, Windows, Linux) do with this Mac.
          FormRow(
            "Git", help: "Changes, staging, commits and pushes in this Mac’s repositories",
            systemImage: "arrow.triangle.branch", hue: .orange)
          FormRow("Code", help: "Build, Test and Run this Mac’s projects", systemImage: "hammer", hue: .blue)
          FormRow("Shell", help: "A terminal on this Mac, without a password", systemImage: "terminal", hue: .gray)
          FormRow(
            "Database", help: "The databases on this Mac, through an SSH tunnel", systemImage: "cylinder.split.1x2",
            hue: .purple)
          FormRow("Player", help: "Plays the videos on this Mac", systemImage: "play.rectangle", hue: .red)
          FormRow("Get", help: "Starts downloads on this Mac", systemImage: "arrow.down.circle", hue: .green)
        }
      }
      if loginIsOn, host != nil {
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
      if loginIsOn {
        FormCard(
          "Security",
          footer: passwordLoginIsOn
            ? "Your devices sign in with keys and don’t need it. Turning it off asks for an administrator’s password."
            : nil
        ) {
          if passwordLoginIsOn {
            FormRow(
              "Password Login Is On",
              help: "Anyone who knows the password of a user on this Mac can sign in over SSH",
              systemImage: "exclamationmark.shield", hue: .orange
            ) {
              Button("Turn Off…") { setPasswordLogin(false) }.buttonStyle(.kit).disabled(changingPasswordLogin)
            }
          } else {
            FormRow(
              "Keys Only", help: "Password login is off: only keys, like your devices’, get in",
              systemImage: "checkmark.shield", hue: .green
            ) {
              Button("Allow Passwords…") { setPasswordLogin(true) }.buttonStyle(.kit).disabled(changingPasswordLogin)
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
          while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: .seconds(2))
          }
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

    /// Whether Remote Login is on and passwords get in. Remote Login turning on publishes this Mac again, now with
    /// the host key sshd made for it.
    private func check() async {
      let isOn = await Task.detached { VaultThisMac.remoteLoginIsOn() }.value
      let wasOn = remoteLoginIsOn
      withKitAnimation { remoteLoginIsOn = isOn }
      if isOn, wasOn == false { vault.refreshThisMac() }
      let passwords = VaultThisMac.passwordLoginIsOn()
      if passwords != passwordLoginIsOn { withKitAnimation { passwordLoginIsOn = passwords } }
    }

    private func setPasswordLogin(_ isOn: Bool) {
      changingPasswordLogin = true
      Task {
        defer { changingPasswordLogin = false }
        do {
          try await VaultThisMac.setPasswordLogin(isOn)
          failure = nil
        } catch is CancellationError {
        } catch {
          failure = error.localizedDescription
        }
        await check()
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
