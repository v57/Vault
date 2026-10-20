import ComponentKit
import SwiftUI
import VaultKit

/// How long a decrypted copy stays.
enum LockAfter: Int, KitOption, CaseIterable {
  case fifteen = 15, thirty = 30, hour = 60, fourHours = 240

  var title: String {
    switch self {
    case .fifteen: "15 min"
    case .thirty: "30 min"
    case .hour: "1 hour"
    case .fourHours: "4 hours"
    }
  }
}

/// Board 04: decrypting for other apps is a visible, timed state, and the sheet says so plainly: when it locks,
/// where the plain copy goes (kept out of Spotlight and backups), and that any app can read it meanwhile.
struct DecryptSheet: View {
  let folderID: String
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @Environment(\.kitIdiom) private var idiom
  @State private var lockAfter = LockAfter.thirty
  @State private var showInFinder = true
  @State private var openTerminal = false
  @State private var error: String?

  var body: some View {
    let folder = app.folders.folder(folderID)
    let name = folder?.name ?? "Folder"
    let totals = app.folders.totals(folderID)
    let lockTime = Date.now.addingTimeInterval(TimeInterval(lockAfter.rawValue * 60))
    KitSheet(
      title: "Decrypt “\(name)” for Other Apps",
      meta: idiom.isTouch
        ? "Puts a plain copy in Files (On My iPad › Vault) that other apps open in place. Edits are sealed back."
        : "Makes a plain copy that \(KitDesktop.fileManagerName), Terminal and other apps can open. Edits are sealed back as you save.",
      systemImage: "lock.open", hue: .orange, width: 620
    ) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Lock after").kitFont(.headline).padding(.leading, 4)
        HStack(spacing: 10) {
          KitSegmented(selection: $lockAfter)
          Text("Locks at \(lockTime.formatted(date: .omitted, time: .shortened)), sealing any changes first.").kitFont(.caption)
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("Where the plain copy goes").kitFont(.headline).padding(.leading, 4)
        FormCard {
          FormRow(
            idiom.isTouch ? "On My iPad › Vault" : "Vault’s own container",
            help: ProjectsView.tilde(app.folders.decryptedRoot.appendingPathComponent(name).path), systemImage: "folder", hue: .teal
          ) {
            Button("Show") { KitDesktop.reveal([app.folders.decryptedRoot]) }.buttonStyle(.kitPlain)
          }
          FormRow("Not indexed by Spotlight", help: "The copy carries .metadata_never_index.", systemImage: "magnifyingglass", hue: .gray) {
            Image(systemName: "checkmark").foregroundStyle(Hue.green.fill)
          }
          #if os(macOS)
            FormRow("Not backed up by Time Machine", help: "Excluded from backups while it exists.", systemImage: "clock.arrow.circlepath", hue: .gray) {
              Image(systemName: "checkmark").foregroundStyle(Hue.green.fill)
            }
          #endif
        }
      }
      #if os(macOS)
        VStack(alignment: .leading, spacing: 6) {
          Text("When it’s ready").kitFont(.headline).padding(.leading, 4)
          HStack(spacing: 18) {
            Toggle("Show in \(KitDesktop.fileManagerName)", isOn: $showInFinder).toggleStyle(.kitCheckbox)
            Toggle("Open in Terminal", isOn: $openTerminal).toggleStyle(.kitCheckbox)
          }
        }
      #endif
      Banner(
        "While it’s decrypted, any app you run can read these files.",
        message: "An SSD can’t reliably erase a deleted plain copy. Lock it as soon as you’re done.",
        systemImage: "exclamationmark.triangle", hue: .orange)
      if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
    } footer: {
      SheetStatus("\(totals.items) items · \(Bytes.text(totals.bytes))", systemImage: "lock.rectangle.stack", hue: .teal)
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Decrypt") { decrypt() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }

  private func decrypt() {
    do {
      let session = try app.folders.decrypt(folderID, for: TimeInterval(lockAfter.rawValue * 60))
      #if os(macOS)
        if showInFinder { KitDesktop.reveal([session.copyURL]) }
        if openTerminal { KitDesktop.openTerminal(at: session.copyURL) }
      #endif
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Board 08: sharing a folder with someone. Their key arrived (by QR code, link or file); both compare the safety
/// code, then the owner picks what they can do. The remote stays theirs to reach: Vault only shares the folder key.
struct ShareSheet: View {
  let folderID: String
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var personID: String?
  @State private var matches = false
  @State private var role = VaultPerson.Role.readWrite
  @State private var link = ""
  @State private var error: String?
  @State private var copies = 0

  var body: some View {
    let folder = app.folders.folder(folderID)
    let name = folder?.name ?? "folder"
    // Whoever's key arrived last (and isn't verified yet) first.
    let candidates = app.sharing.people.filter { $0.record.roles[folderID] == nil && $0.identity != nil }
      .sorted { ($0.status == .verified ? 1 : 0, $1.record.created ?? .distantPast) < ($1.status == .verified ? 1 : 0, $0.record.created ?? .distantPast) }
    let person = candidates.first { $0.id == personID } ?? candidates.first
    let first = person?.name.split(separator: " ").first.map(String.init) ?? "They"
    KitSheet(
      title: "Share “\(name)”", meta: person == nil ? "Send your invite; their key comes back the same way." : "Exchange keys, compare the safety code, then choose what \(first) can do.",
      systemImage: "person.badge.plus", hue: .purple, width: 680
    ) {
      HStack(alignment: .top, spacing: 18) {
        VStack(spacing: 10) {
          KitQRCode(link.isEmpty ? "v57vault://invite" : link, size: 148)
          Text(person == nil ? "They scan this in Vault, or open the link you send." : "\(first) scans this in Vault, or opens the link or file you send.")
            .kitFont(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(width: 190)
          HStack(spacing: 6) {
            Button("Copy Link", systemImage: "link") {
              KitPasteboard.copy(link)
              copies += 1
            }
            .effect(.success, on: copies)
          }
          .buttonStyle(.kit)
          .controlSize(.small)
        }
        VStack(alignment: .leading, spacing: 10) {
          if let person, let code = app.sharing.safetyCode(with: person) {
            if candidates.count > 1 {
              KitSegmented(selection: Binding(get: { person.id }, set: { personID = $0 }), options: candidates.map { ($0.name, $0.id) })
            }
            Text("\(first)’s safety code").kitFont(.headline)
            KitSafetyCode(groups: code)
            Toggle("It matches the code on \(first)’s screen", isOn: $matches).toggleStyle(.kitCheckbox)
            Text("\(first) can").kitFont(.headline).padding(.top, 4)
            KitSegmented(selection: $role, options: [("Read and write", .readWrite), ("Only read", .readOnly)]).kitSegmentedStyle(.wide)
            Text("Every change is signed. Devices ignore changes from members who may only read.").kitFont(.caption)
          } else {
            EmptyState(systemImage: "qrcode", title: "Waiting for Their Key", message: "Once they scan your code, their key arrives here and you compare the safety code.")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let folder, let remote = folder.record.remoteID.flatMap(app.vault.remote(id:)) {
        FormCard {
          FormRow("\(remote.name) holds this folder", help: "\(first) needs their own access to it. Vault only shares the folder key.", systemImage: LocationKind(remote.kind).systemImage, hue: .indigo) {
            Button("Copy Path") { KitPasteboard.copy(folder.record.remotePath ?? remote.path) }.buttonStyle(.kitPlain)
          }
        }
        FormCard {
          FormRow("\(name) · \(app.folders.totals(folderID).items) items", help: "The folder key is wrapped to \(first)’s key and added to the signed member list.", systemImage: "lock.rectangle.stack", hue: .teal)
        }
      }
      if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
    } footer: {
      if let person {
        SheetStatus("\(first)’s key arrived \(person.record.created.map { RelativeTime.dayTime($0) } ?? "")", systemImage: "person", status: .done)
      } else {
        SheetStatus("Waiting for their key", systemImage: "person", status: .working)
      }
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Add \(first)") { add(person) }
        .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(person == nil || !matches)
    }
    .onAppear {
      link = (try? app.sharing.inviteLink(folderID: folderID, folderName: name, role: nil)) ?? ""
    }
  }

  private func add(_ person: PersonItem?) {
    guard let person else { return }
    do {
      if person.status != .verified { app.sharing.verify(person.id) }
      try app.sharing.add(person.id, to: folderID, role: role)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Inviting someone (or a device without iCloud Keychain): your invite as a QR code and a link.
struct InviteSheet: View {
  var forDevice = false
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var link = ""
  @State private var copies = 0

  var body: some View {
    KitSheet(
      title: forDevice ? "Add a Device" : "Invite Someone",
      meta: forDevice
        ? "On Linux, Windows or Android, Vault scans this code from one of your devices to receive your keys."
        : "They scan this code in Vault or open the link. Their key comes back the same way, then you compare the safety code.",
      systemImage: forDevice ? "qrcode.viewfinder" : "person.badge.plus", hue: forDevice ? .blue : .purple, width: 520
    ) {
      HStack(alignment: .top, spacing: 18) {
        KitQRCode(link.isEmpty ? "v57vault://invite" : link, size: 160)
        VStack(alignment: .leading, spacing: 8) {
          if let identity = app.sharing.identity {
            Text("Your identity").kitFont(.headline)
            Text(identity.fingerprint).kitFont(.mono)
            Text(identity.agreementFingerprint).kitFont(.mono)
          }
          Text(link).kitFont(.monoSmall).foregroundStyle(.kitSecondary).lineLimit(4).textSelection(.enabled)
        }
      }
    } footer: {
      Button("Copy Link", systemImage: "link") {
        KitPasteboard.copy(link)
        copies += 1
      }
      .effect(.success, on: copies)
      Button("Done") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
    .onAppear { link = (try? app.sharing.inviteLink(folderID: nil, folderName: nil, role: nil)) ?? "" }
  }
}

/// Scanning someone's invite (their QR code, or the link they sent): their key arrives and they show up in People,
/// waiting for the safety code to be compared.
struct ScanInviteSheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var message: String?
  @State private var added: String?

  var body: some View {
    KitSheet(
      title: "Scan an Invite", meta: "Point the camera at their QR code, or paste the link they sent.",
      systemImage: "qrcode.viewfinder", hue: .purple, width: 520
    ) {
      KitQRScanner { text in accept(text) }
        .frame(height: 300)
      if let message { Text(message).kitFont(.caption).foregroundStyle(added == nil ? AnyShapeStyle(Hue.red.text) : AnyShapeStyle(.kitSecondary)) }
    } footer: {
      if let added { SheetStatus("\(added)’s key arrived", systemImage: "person", status: .done) }
      Button("Paste Link") { if let text = KitPasteboard.string() { accept(text) } }
      Button(added == nil ? "Cancel" : "Done") {
        if added != nil { app.selection = .devices }
        dismiss()
      }
      .buttonStyle(added == nil ? .kit : .kitPrimary)
      .keyboardShortcut(.defaultAction)
    }
  }

  private func accept(_ text: String) {
    guard let invite = VaultInvite(url: text), invite.isSignatureValid else {
      message = "That isn’t a Vault invite, or it was changed after it was made."
      return
    }
    app.sharing.accept(invite)
    added = invite.name
    message = "Compare the safety code with \(invite.name) in Devices & People before sharing anything."
  }
}
