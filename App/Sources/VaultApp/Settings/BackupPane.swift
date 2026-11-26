import ComponentKit
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// The encrypted backup (`BackupActions`): one file with every record, key and password, sealed under a passphrase and
/// saved where the user picks. Restoring merges it into the vault here, so it serves a lost keychain and a lost store.
struct BackupPane: View {
  @Environment(AppModel.self) private var app
  @State private var exporting = false
  @State private var choosingFile = false
  @State private var restoring: PickedBackup?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      FormCard(footer: "The file holds your passwords, keys and records, encrypted with the passphrase you choose. Keep it off iCloud, on a drive or a device you control, and keep the passphrase somewhere else. Without the passphrase, nobody can open it, you included.") {
        FormRow("Export Encrypted Backup…", help: "Everything in Personal and your accounts, the vault keys and every saved password, in one file.", systemImage: "square.and.arrow.up", hue: .green) {
          Button("Export…") { exporting = true }.buttonStyle(.kit)
        }
        FormRow("Restore from Backup…", help: "Brings back what the backup holds. What changed here since stays as it is.", systemImage: "arrow.uturn.backward", hue: .blue, error: error.map { "\($0)" }) {
          Button("Restore…") { choosingFile = true }.buttonStyle(.kit)
        }
      }
      .disabled(app.isDemo)
      .help(app.isDemo ? "Not in the demo vault" : "")
      FormCard("What it holds") {
        FormRow("Records", help: "Logins, hosts, notes, projects and everything else, Personal and every account.", systemImage: "tray.full", hue: .blue)
        FormRow("Vault keys", help: "The current one and the older ones, so everything opens.", systemImage: "key.horizontal", hue: .orange)
        FormRow("Passwords and secrets", help: "Logins, one-time codes, cards, passkeys, server and database passwords and imported SSH keys.", systemImage: "lock", hue: .orange)
        FormRow("Your identity", help: "For shared folders and the people you share with.", systemImage: "person", hue: .purple)
        FormRow("This device’s keys", help: "Brought back only on this device. A device SSH key opens only in this device’s Secure Enclave.", systemImage: "shield", hue: .gray)
      }
    }
    .kitSheet(isPresented: $exporting) { ExportBackupSheet() }
    .kitSheet(item: $restoring) { picked in RestoreBackupSheet(picked: picked) }
    .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data, .item]) { result in
      switch result {
      case .success(let url): open(url)
      case .failure(let failure): error = failure.localizedDescription
      }
    }
    .backupDialogDirectory()
  }

  private func open(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try Data(contentsOf: url)
      guard VaultBackup.created(data) != nil else { throw VaultBackup.BackupError.notABackup }
      restoring = PickedBackup(name: url.lastPathComponent, data: data)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct PickedBackup: Identifiable {
  let id = UUID()
  var name: String
  var data: Data
}

/// Choose a passphrase twice, then where to save.
private struct ExportBackupSheet: View {
  @Environment(\.kitDismiss) private var dismiss
  @State private var passphrase = ""
  @State private var again = ""
  @State private var working = false
  @State private var file: BackupFile?
  @State private var saving = false
  @State private var status: String?
  @State private var failed = false

  private var problem: String? {
    if passphrase.count < VaultBackup.minimumPassphraseLength {
      return String(localized: "At least \(VaultBackup.minimumPassphraseLength) characters")
    }
    if again != passphrase { return String(localized: "The two passphrases differ") }
    return nil
  }

  var body: some View {
    KitSheet(
      title: "Export Encrypted Backup", meta: "Saved where you choose, never to iCloud by itself", systemImage: "square.and.arrow.up",
      hue: .green, width: 500
    ) {
      LabeledField("Passphrase") {
        SecureField("At least \(VaultBackup.minimumPassphraseLength) characters", text: $passphrase).kitField()
      }
      LabeledField("Passphrase again") {
        SecureField("The same again", text: $again).kitField()
      }
      Text("Write the passphrase down and keep it apart from the file. There’s no way to open the backup without it.")
        .kitFont(.caption).foregroundStyle(.secondary)
    } footer: {
      SheetStatus(
        status ?? problem ?? String(localized: "Ready"), systemImage: failed ? "xmark.octagon" : "lock",
        hue: failed ? .red : .green, status: working ? .working : .idle)
      Spacer()
      Button(file == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(.kit).keyboardShortcut(.cancelAction)
      Button("Export…") { export() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
        .disabled(problem != nil || working)
    }
    .kitSheetDismissDisabled(!passphrase.isEmpty)
    .fileExporter(isPresented: $saving, document: file, contentType: .data, defaultFilename: BackupActions.defaultFilename) { result in
      switch result {
      case .success(let url):
        status = String(localized: "Saved to \(url.lastPathComponent)")
        failed = false
      case .failure(let error):
        status = error.localizedDescription
        failed = true
      }
    }
    .backupDialogDirectory()
  }

  private func export() {
    working = true
    status = String(localized: "Encrypting…")
    failed = false
    Task {
      defer { working = false }
      do {
        file = BackupFile(data: try await BackupActions.export(passphrase: passphrase))
        status = nil
        saving = true
      } catch {
        status = error.localizedDescription
        failed = true
      }
    }
  }
}

/// The passphrase, what the backup holds, then restore.
private struct RestoreBackupSheet: View {
  let picked: PickedBackup
  @Environment(\.kitDismiss) private var dismiss
  @State private var passphrase = ""
  @State private var contents: VaultBackupContents?
  @State private var thisDevice = false
  @State private var result: VaultBackupRestoreResult?
  @State private var status: String?
  @State private var failed = false
  @State private var working = false

  var body: some View {
    KitSheet(title: "Restore from Backup", meta: "\(picked.name)", systemImage: "arrow.uturn.backward", hue: .blue, width: 520) {
      if let contents {
        FormCard {
          FormRow("Made", help: "\(contents.created.formatted(date: .long, time: .shortened)) on \(contents.deviceName.isEmpty ? "a device" : contents.deviceName)", systemImage: "calendar", hue: .gray)
          FormRow("Records", help: "\(contents.recordCount) in \((contents.accountCount + 1).vaultsLabel)", systemImage: "tray.full", hue: .blue)
          FormRow("Secrets and keys", help: "\(contents.secretCount) passwords and secrets, \(contents.keyCount.keysLabel)", systemImage: "lock", hue: .orange)
          if contents.leftOut > 0 {
            FormRow("Left out when it was made", help: "\(contents.leftOut) records that device couldn’t open", systemImage: "exclamationmark.triangle", hue: .yellow)
          }
        }
        Toggle("This is the device the backup was made on", isOn: $thisDevice)
          .help("Brings back this device’s id and its own keys too. Leave it off on another device.")
        if let result { summary(result) }
      } else {
        LabeledField("Passphrase") {
          SecureField("The backup’s passphrase", text: $passphrase).kitField()
        }
      }
    } footer: {
      SheetStatus(
        status ?? (contents == nil ? String(localized: "Locked") : String(localized: "Merged into this vault; newer changes here stay")),
        systemImage: failed ? "xmark.octagon" : "lock.open", hue: failed ? .red : .blue, status: working ? .working : .idle)
      Spacer()
      Button(result == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(.kit).keyboardShortcut(.cancelAction)
      if result == nil {
        Button(contents == nil ? "Open" : "Restore") { contents == nil ? open() : restore() }
          .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
          .disabled(working || (contents == nil && passphrase.isEmpty))
      }
    }
  }

  private func summary(_ result: VaultBackupRestoreResult) -> some View {
    FormCard("Restored") {
      FormRow("Records", help: "\(result.records) brought back, \(String(localized: "\(result.unchangedRecords) already here"))", systemImage: "tray.full", hue: .green)
      FormRow("Secrets", help: "\(result.secrets) brought back, \(String(localized: "\(result.unchangedSecrets) already here")), \(String(localized: "\(result.keptSecrets) newer here kept"))", systemImage: "lock", hue: .green)
      FormRow("Keys", help: "\(result.keys) brought back, \(String(localized: "\(result.deviceItems) of this device’s"))", systemImage: "key.horizontal", hue: .green)
      if result.refusedRecords > 0 || result.secretsLeftOut > 0 || !result.storesLeftOut.isEmpty {
        FormRow("Left out", help: "\(result.refusedRecords) records refused, \(String(localized: "\(result.secretsLeftOut) secrets with no place here")), \(result.storesLeftOut.count.accountsLabel)", systemImage: "exclamationmark.triangle", hue: .yellow)
      }
    }
  }

  private func open() {
    working = true
    failed = false
    status = String(localized: "Opening…")
    Task {
      defer { working = false }
      do {
        let opened = try await BackupActions.open(picked.data, passphrase: passphrase)
        thisDevice = opened.deviceID == VaultDevice.id
        contents = opened
        passphrase = ""
        status = nil
      } catch {
        status = error.localizedDescription
        failed = true
      }
    }
  }

  private func restore() {
    guard let contents else { return }
    do {
      result = try BackupActions.restore(contents, devicesOwnKeys: thisDevice)
      status = String(localized: "Restored")
      failed = false
    } catch {
      status = error.localizedDescription
      failed = true
    }
  }
}

extension View {
  /// Starts the save and open panels off iCloud: Downloads on the Mac, On My iPhone on iPhone and iPad.
  @ViewBuilder func backupDialogDirectory() -> some View {
    if #available(macOS 15, iOS 18, *), let directory = BackupActions.defaultDirectory {
      fileDialogDefaultDirectory(directory)
    } else {
      self
    }
  }
}
