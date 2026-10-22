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
  @Environment(\.kitDismiss) private var dismiss
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
      title: idiom == .phone ? "Decrypt “\(name)”" : "Decrypt “\(name)” for Other Apps",
      meta: idiom == .phone
        ? "A plain copy for other apps, until \(lockTime.formatted(date: .omitted, time: .shortened))"
        : idiom.isTouch
          ? "Puts a plain copy in Files (On My \(ThisDevice.word) › Vault) that other apps open in place. Edits are sealed back."
          : "Makes a plain copy that \(KitDesktop.fileManagerName), Terminal and other apps can open. Edits are sealed back as you save.",
      systemImage: "lock.open", hue: .orange, width: 620
    ) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Lock after").kitFont(.headline).padding(.leading, 4)
        if idiom == .phone {
          KitSegmented(selection: $lockAfter).kitSegmentedStyle(.wide)
        } else {
          HStack(spacing: 10) {
            KitSegmented(selection: $lockAfter)
            Text("Locks at \(lockTime.formatted(date: .omitted, time: .shortened)), sealing any changes first.").kitFont(.caption)
          }
        }
      }
      if idiom.isTouch {
        FormCard {
          FormRow("Files › On My \(ThisDevice.word) › Vault", help: "Other apps open the copy in place.", systemImage: "folder", hue: .teal)
          FormRow("Moves out of Files when it locks", help: "Your edits are sealed back first.", systemImage: "lock", hue: .gray) {
            Image(systemName: "checkmark").foregroundStyle(Hue.green.fill)
          }
        }
        Banner("Any app can read it while it’s decrypted.", message: "Lock it as soon as you’re done.", systemImage: "exclamationmark.triangle", hue: .orange)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          Text("Where the plain copy goes").kitFont(.headline).padding(.leading, 4)
          FormCard {
            FormRow(
              "Vault’s own container",
              help: ProjectsView.tilde(app.folders.decryptedRoot.appendingPathComponent(name).path), systemImage: "folder", hue: .teal
            ) {
              Button("Show") { KitDesktop.reveal([app.folders.decryptedRoot]) }.buttonStyle(.kitPlain)
            }
            FormRow("Not indexed by Spotlight", help: "The copy carries .metadata_never_index.", systemImage: "magnifyingglass", hue: .gray) {
              Image(systemName: "checkmark").foregroundStyle(Hue.green.fill)
            }
            FormRow("Not backed up by Time Machine", help: "Excluded from backups while it exists.", systemImage: "clock.arrow.circlepath", hue: .gray) {
              Image(systemName: "checkmark").foregroundStyle(Hue.green.fill)
            }
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
      }
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
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.kitDismiss) private var dismiss
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
      title: "Share “\(name)”",
      meta: person == nil ? "Send your invite; their key comes back the same way."
        : idiom == .phone ? "Exchange keys, compare the code, pick a role" : "Exchange keys, compare the safety code, then choose what \(first) can do.",
      systemImage: "person.badge.plus", hue: .purple, width: 680
    ) {
      AdaptiveStack(spacing: 18) {
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
            Button("Scan Theirs", systemImage: "qrcode.viewfinder") { app.sheet = .scanInvite }
          }
          .buttonStyle(.kit)
          .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 10) {
          if let person, let code = app.sharing.safetyCode(with: person) {
            if candidates.count > 1, idiom != .phone {
              KitSegmented(selection: Binding(get: { person.id }, set: { personID = $0 }), options: candidates.map { ($0.name, $0.id) })
            }
            Text("\(first)’s safety code").kitFont(.headline)
            KitSafetyCode(groups: code)
            Toggle("It matches the code on \(first)’s screen", isOn: $matches).toggleStyle(.kitCheckbox)
            Text("\(first) can").kitFont(.headline).padding(.top, 4)
            KitSegmented(selection: $role, options: [("Read and write", .readWrite), ("Only read", .readOnly)]).kitSegmentedStyle(.wide)
            if idiom != .phone {
              Text("Every change is signed. Devices ignore changes from members who may only read.").kitFont(.caption)
            }
          } else {
            EmptyState(systemImage: "qrcode", title: "Waiting for Their Key", message: "Once they scan your code, their key arrives here and you compare the safety code.")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let folder, let remote = folder.record.remoteID.flatMap(app.vault.remote(id:)) {
        FormCard {
          FormRow(
            "\(remote.name) holds this folder",
            help: idiom == .phone ? "\(first) needs their own access to it" : "\(first) needs their own access to it. Vault only shares the folder key.",
            systemImage: LocationKind(remote.kind).systemImage, hue: .indigo
          ) {
            if idiom != .phone {
              Button("Copy Path") { KitPasteboard.copy(folder.record.remotePath ?? remote.path) }.buttonStyle(.kitPlain)
            }
          }
        }
        if idiom != .phone {
          FormCard {
            FormRow("\(name) · \(app.folders.totals(folderID).items) items", help: "The folder key is wrapped to \(first)’s key and added to the signed member list.", systemImage: "lock.rectangle.stack", hue: .teal)
          }
        }
      }
      if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
    } footer: {
      if let person {
        SheetStatus(idiom == .phone ? "Key arrived" : "\(first)’s key arrived \(person.record.created.map { RelativeTime.dayTime($0) } ?? "")", systemImage: "person", status: .done)
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
  @Environment(\.kitDismiss) private var dismiss
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
  @Environment(\.kitDismiss) private var dismiss
  @State private var message: String?
  @State private var added: String?

  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if idiom == .phone {
      fullScreen
    } else {
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
        Button(added == nil ? "Cancel" : "Done") { finish() }
          .buttonStyle(added == nil ? .kit : .kitPrimary)
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  /// iPhone board 03: the camera fills the screen, the frame and two cards over it (nothing leaves the phone while
  /// it looks).
  private var fullScreen: some View {
    ZStack {
      KitQRScanner { text in accept(text) }.ignoresSafeArea()
      VStack {
        HStack(spacing: 12) {
          Tile(systemImage: "qrcode.viewfinder", size: 34)
          VStack(alignment: .leading, spacing: 1) {
            Text("Scan an Invite").kitFont(.title3)
            Text(added.map { "\($0)’s key arrived" } ?? "Looking for a code").kitFont(.caption)
          }
          Spacer()
          Button("Close", systemImage: "xmark") { finish() }.buttonStyle(.kitRound)
        }
        .padding(12)
        .kitSurface(.floating)
        Spacer()
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
            Tile(systemImage: "checkmark.shield", hue: .green, size: 34)
            VStack(alignment: .leading, spacing: 1) {
              Text("Read on this \(ThisDevice.word)").kitFont(.title3)
              Text("nothing is sent while scanning").kitFont(.caption)
            }
          }
          Text(message ?? "Point at the QR code on their screen, their invite file, or a recovery kit. Then compare the safety code.")
            .kitFont(.caption)
          HStack {
            Button("Paste Link") { if let text = KitPasteboard.string() { accept(text) } }.buttonStyle(.kit)
            if added != nil { Button("Done") { finish() }.buttonStyle(.kitPrimary) }
          }
          .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitSurface(.floating)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }

  private func finish() {
    if added != nil { app.selection = .devices }
    dismiss()
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

/// Side by side where there's room, one over the other on iPhone.
struct AdaptiveStack<Content: View>: View {
  var spacing: CGFloat = 12
  @ViewBuilder var content: Content
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if idiom == .phone {
      VStack(alignment: .leading, spacing: spacing) { content }
    } else {
      HStack(alignment: .top, spacing: spacing) { content }
    }
  }
}
