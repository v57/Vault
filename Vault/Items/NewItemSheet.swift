import ComponentKit
import SwiftUI
import VaultKit

/// Board 09: New. The kind first (Login, Card, Note, SSH Host, Database, Remote), then its fields. A login gets a
/// generated password with its strength, an optional one-time code, and links to the items it belongs with.
struct NewItemSheet: View {
  @State var kind: NewItemKind
  @Environment(AppModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if kind == .remote {
      AddRemoteSheet()
    } else if kind == .folder {
      NewFolderSheet()
    } else {
      sheet
    }
  }

  private var sheet: some View {
    KitSheet(
      title: title,
      meta: "Saved in iCloud Keychain on your \(app.devices.count) devices" + (idiom == .phone ? "" : ". Only v57 apps and AutoFill can read it."),
      systemImage: kindImage(kind), width: 660
    ) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Kind").kitFont(.headline).padding(.leading, 4)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: KitMetrics.gutter), count: idiom == .phone ? 2 : 3), spacing: KitMetrics.gutter) {
          choice(.login, "Login", "Website or app")
          choice(.card, "Card", "Payment card")
          choice(.note, "Note", "Encrypted text")
          choice(.host, "SSH Host", "Shell, Database")
          if idiom != .phone {
            choice(.database, "Database", "A connection")
            choice(.remote, "Remote", "S3, SFTP, SMB")
          }
        }
      }
      switch kind {
      case .login: LoginForm(onSave: { dismiss() })
      case .card: CardForm(onSave: { dismiss() })
      case .note: NoteForm(onSave: { dismiss() })
      case .host: HostForm(onSave: { dismiss() })
      case .database: DatabaseForm(onSave: { dismiss() })
      case .remote, .folder: EmptyView()
      }
    }
  }

  private var title: String {
    switch kind {
    case .login: "New Login"
    case .card: "New Card"
    case .note: "New Note"
    case .host: "New SSH Host"
    case .database: "New Database"
    case .remote: "Add Remote"
    case .folder: "New Encrypted Folder"
    }
  }

  private func kindImage(_ kind: NewItemKind) -> String {
    switch kind {
    case .login: "key.horizontal"
    case .card: "creditcard"
    case .note: "doc.text"
    case .host: "server.rack"
    case .database: "cylinder"
    case .remote: "globe"
    case .folder: "lock.rectangle.stack"
    }
  }

  private func choice(_ value: NewItemKind, _ title: String, _ subtitle: String) -> some View {
    ChoiceCard(isOn: Binding(get: { kind == value }, set: { if $0 { withKitAnimation { kind = value } } })) {
      ChoiceCardLabel(title, subtitle: subtitle) { Tile(systemImage: kindImage(value), size: 28) }
    }
    .kindCardHover()
  }
}

extension View {
  /// The kit's 3D hover on a kind card (New, Add Remote), in the card's own corners.
  func kindCardHover() -> some View { modifier(KindCardHover()) }
}

private struct KindCardHover: ViewModifier {
  @Environment(\.kitIdiom) private var idiom

  func body(content: Content) -> some View {
    content.kitHoverEffect(in: RoundedRectangle(cornerRadius: idiom == .mac ? 12 : idiom == .pad ? 14 : 16, style: .continuous))
  }
}

/// A labelled field over its filled input, as the design's forms draw them.
struct LabeledField<Content: View>: View {
  var label: String
  @ViewBuilder var content: Content

  init(_ label: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).kitFont(.headline).padding(.leading, 4)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The login's fields, its one-time code and its links.
private struct LoginForm: View {
  var onSave: () -> Void
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var title = ""
  @State private var website = ""
  @State private var username = ""
  @State private var password = PasswordGenerator().generate()
  @State private var code: OneTimeCode?
  @State private var codeError: String?
  @State private var scansCamera = false
  @State private var links: Set<String> = []
  @State private var error: String?

  var body: some View {
    let strength = PasswordStrength(password: password)
    VStack(spacing: 12) {
      FieldRow {
        LabeledField("Title") { TextField("Build server console", text: $title).kitField() }
        LabeledField("Website") { TextField("example.com", text: $website).kitField() }
      }
      FieldRow {
        LabeledField("Username") { TextField("you@example.com", text: $username).kitField() }
        LabeledField("Password") {
          TextField("Password", text: $password)
            .kitField(mono: true) {
              Button("Generate", systemImage: "wand.and.stars") { password = PasswordGenerator().generate() }
                .buttonStyle(.kitPlain).controlSize(.small)
            }
          HStack(spacing: 10) {
            MeterBar(
              segments: (0..<4).map { MeterSegment("", value: $0 <= strength.rawValue ? 1 : 0, hue: strengthHue(strength)) },
              total: 4, height: 6
            )
            .frame(width: 120)
            Text(PasswordStrength.description(of: password) + (idiom == .phone ? "" : " from this \(ThisDevice.word)’s generator"))
              .kitFont(.caption).lineLimit(2)
          }
          .padding(.top, 2)
        }
      }
    }
    LabeledField("One-time code") {
      FormCard {
        if let code {
          FormRow("One-time code", help: code.issuer ?? code.account ?? "Added", systemImage: "clock") {
            KitOneTimeCode(period: TimeInterval(code.period), showsSeconds: false) { code.code(at: $0) }
          }
        } else {
          FormRow(
            "Add a code", help: codeError ?? (idiom == .phone ? "Paste the setup key" : "Paste the setup key, or scan the QR code the site shows on screen."),
            systemImage: "clock", error: codeError
          ) {
            HStack(spacing: 6) {
              if KitQRReader.canScanScreen {
                Button("Scan Screen") { scanScreen() }
              } else if idiom == .phone {
                Button { withKitAnimation { scansCamera.toggle() } } label: { Image(systemName: "qrcode.viewfinder") }
                  .accessibilityLabel("Scan Code")
              } else {
                Button("Scan Code") { withKitAnimation { scansCamera.toggle() } }
              }
              Button("Paste Key") { pasteKey() }
            }
            .buttonStyle(.kit)
            .controlSize(.small)
          }
        }
      }
    }
    if scansCamera, code == nil {
      KitQRScanner { text in
        if let parsed = OneTimeCode(text) {
          code = parsed
          codeError = nil
          scansCamera = false
        }
      }
      .frame(height: 220)
    }
    LabeledField("Link to") {
      LinkPicker(selection: $links)
    }
    if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
    SheetFooterButtons(saveTitle: "Save", canSave: !title.isEmpty || !website.isEmpty, status: idiom == .phone ? "Fills through AutoFill" : "Fills in Safari and apps through AutoFill", onSave: save)
  }

  private func strengthHue(_ strength: PasswordStrength) -> Hue {
    switch strength {
    case .weak: .red
    case .fair: .orange
    case .good: .yellow
    case .strong: .green
    }
  }

  /// Finds the setup QR code the site shows on screen (the system asks for screen recording the first time).
  private func scanScreen() {
    Task {
      do {
        let codes = try await KitQRReader.codesOnScreen()
        if let parsed = codes.lazy.compactMap(OneTimeCode.init).first {
          code = parsed
          codeError = nil
        } else {
          codeError = "No setup code on screen. Show the site’s QR code, then scan again."
        }
      } catch {
        codeError = "Allow Vault to record the screen in System Settings to scan the code."
      }
    }
  }

  private func pasteKey() {
    guard let text = KitPasteboard.string(), let parsed = OneTimeCode(text) else {
      codeError = "The pasteboard has no setup key."
      return
    }
    code = parsed
    codeError = nil
  }

  private func save() {
    guard let store = app.vault.store else { return }
    do {
      let login = VaultLogin(title: title.isEmpty ? website : title, website: website, username: username, links: links)
      try store.save(login)
      try store.setPassword(password, forLogin: login.id)
      if let code { try store.setOneTimeCode(code, forLogin: login.id) }
      app.vault.reload()
      app.selectedLogin = login.id
      app.selection = .logins
      onSave()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Chips of what a new item can link to: hosts, databases and folders, the first few, then Other….
private struct LinkPicker: View {
  @Binding var selection: Set<String>
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let options: [(String, String, String)] =
      app.vault.hosts.prefix(1).map { ($0.id, $0.displayName, "server.rack") }
      + app.vault.databases.prefix(1).map { ($0.id, $0.name, "cylinder") }
      + app.folders.folders.prefix(1).map { ($0.id, $0.name, "lock.rectangle.stack") }
    // On iPhone two suggestions, with Other… on a line of its own.
    let shown = idiom == .phone ? Array(options.prefix(2)) : options
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 2) {
        ForEach(shown, id: \.0) { id, title, image in
          Toggle(isOn: Binding(get: { selection.contains(id) }, set: { on in if on { selection.insert(id) } else { selection.remove(id) } })) {
            Label(title, systemImage: image).lineLimit(1)
          }
          .toggleStyle(.kitChip)
        }
        if idiom != .phone { other }
        Spacer(minLength: 0)
      }
      if idiom == .phone { other }
    }
    .padding(3)
    .kitSurface(.field)
  }

  private var other: some View {
    Button("Other…", systemImage: "plus") {}.buttonStyle(.kitPlain).controlSize(.small)
  }
}

/// The sheet's footer as the form's last line: status, Cancel, Save.
struct SheetFooterButtons: View {
  var saveTitle: String
  var canSave: Bool
  var status: String
  var onSave: () -> Void
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    HStack(spacing: 8) {
      SheetStatus(status, systemImage: "checkmark.shield", hue: .green)
      Spacer()
      Button("Cancel") { dismiss() }.buttonStyle(.kit).keyboardShortcut(.cancelAction)
      Button(saveTitle, action: onSave).buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(!canSave)
    }
    .padding(6)
    .kitSurface(.card)
  }
}

private struct CardForm: View {
  var onSave: () -> Void
  @Environment(AppModel.self) private var app
  @State private var title = ""
  @State private var holder = ""
  @State private var number = ""
  @State private var expiry = ""
  @State private var code = ""

  var body: some View {
    VStack(spacing: 12) {
      FieldRow {
        LabeledField("Title") { TextField("Company card", text: $title).kitField() }
        LabeledField("Holder") { TextField("Name on the card", text: $holder).kitField() }
      }
      FieldRow {
        LabeledField("Number") { SecureField("1234 5678 9012 3456", text: $number).kitField(mono: true) }
        HStack(spacing: 12) {
          LabeledField("Expires") { TextField("MM/YY", text: $expiry).kitField(mono: true) }
          LabeledField("Code") { SecureField("123", text: $code).kitField(mono: true) }
        }
      }
    }
    SheetFooterButtons(saveTitle: "Save", canSave: !number.isEmpty, status: "Fills in Safari and apps through AutoFill") {
      guard let store = app.vault.store else { return }
      let card = VaultCard(title: title.isEmpty ? "Card" : title, holder: holder, expiry: expiry)
      try? store.save(card)
      try? store.setCardNumber(number, forCard: card.id)
      try? store.setCardCode(code, forCard: card.id)
      app.vault.reload()
      app.selection = .cards
      onSave()
    }
  }
}

private struct NoteForm: View {
  var onSave: () -> Void
  @Environment(AppModel.self) private var app
  @State private var name = ""
  @State private var text = ""

  var body: some View {
    LabeledField("Title") { TextField("Wi-Fi", text: $name).kitField() }
    LabeledField("Text") {
      TextEditor(text: $text).font(.body).frame(minHeight: 120).scrollContentBackground(.hidden).padding(6).kitSurface(.field)
    }
    SheetFooterButtons(saveTitle: "Save", canSave: !name.isEmpty, status: "Encrypted; Markdown and Shell show it too") {
      app.vault.save(VaultNote(folder: "Vault", name: name, encrypted: true, text: text))
      app.selection = .notes
      onSave()
    }
  }
}

private struct HostForm: View {
  var onSave: () -> Void
  @Environment(AppModel.self) private var app
  @State private var name = ""
  @State private var hostname = ""
  @State private var user = ""
  @State private var port = "22"
  @State private var useDeviceKey = true

  var body: some View {
    VStack(spacing: 12) {
      FieldRow {
        LabeledField("Name") { TextField("atlas-web-1", text: $name).kitField() }
        LabeledField("Address") { TextField("host.example.com", text: $hostname).kitField(mono: true) }
      }
      FieldRow {
        LabeledField("User") { TextField("deploy", text: $user).kitField() }
        LabeledField("Port") { TextField("22", text: $port).kitField(mono: true) }
      }
    }
    Toggle("Sign in with each device’s own key (Secure Enclave)", isOn: $useDeviceKey).toggleStyle(.kitCheckbox)
    SheetFooterButtons(saveTitle: "Save", canSave: !hostname.isEmpty, status: "Shell and Database see it at once") {
      let host = VaultHost(name: name, hostname: hostname, port: Int(port) ?? 22, user: user, auth: useDeviceKey ? .deviceKey : .password, order: app.vault.hosts.count, source: "vault")
      app.vault.save(host)
      app.selectedHost = host.id
      app.selection = .hosts
      onSave()
    }
  }
}

private struct DatabaseForm: View {
  var onSave: () -> Void
  @Environment(AppModel.self) private var app
  @State private var name = ""
  @State private var engine = VaultDatabase.Engine.postgres
  @State private var host = "127.0.0.1"
  @State private var port = "5432"
  @State private var user = ""

  var body: some View {
    LabeledField("Engine") {
      KitSegmented(selection: $engine, options: [("PostgreSQL", VaultDatabase.Engine.postgres), ("MySQL", VaultDatabase.Engine.mysql), ("MongoDB", VaultDatabase.Engine.mongodb), ("Redis", VaultDatabase.Engine.redis)])
    }
    VStack(spacing: 12) {
      FieldRow {
        LabeledField("Name") { TextField("Atlas production", text: $name).kitField() }
        LabeledField("User") { TextField("atlas", text: $user).kitField() }
      }
      FieldRow {
        LabeledField("Host") { TextField("127.0.0.1", text: $host).kitField(mono: true) }
        LabeledField("Port") { TextField("5432", text: $port).kitField(mono: true) }
      }
    }
    SheetFooterButtons(saveTitle: "Save", canSave: !name.isEmpty, status: "Database and Shell see it at once") {
      let database = VaultDatabase(name: name, engine: engine, host: host, port: Int(port) ?? 5432, user: user, order: app.vault.databases.count)
      app.vault.save(database)
      app.selectedDatabase = database.id
      app.selection = .databases
      onSave()
    }
  }
}

/// A new encrypted folder: its name and where it lives. The one mention of the recovery key sits here, where the
/// user first encrypts something.
struct NewFolderSheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss
  @State private var name = ""
  @State private var location: URL?
  @State private var error: String?

  var body: some View {
    KitSheet(title: "New Encrypted Folder", meta: "Only v57 apps can open it: names and files are both encrypted.", systemImage: "lock.rectangle.stack", hue: .teal, width: 520) {
      LabeledField("Name") { TextField("Taxes 2027", text: $name).kitField() }
      LabeledField("Where") {
        HStack {
          Text(location.map { ProjectsView.tilde($0.path) } ?? "Vault’s folder on this device").kitFont(.mono).lineLimit(1).truncationMode(.middle)
          Spacer()
          #if os(macOS)
            Button("Choose…") { Task { location = await KitDesktop.chooseFolders(canCreateDirectories: true).first } }.buttonStyle(.kit).controlSize(.small)
          #endif
        }
        .padding(8)
        .kitSurface(.field)
      }
      if !app.recovery.isOn {
        Text("If your keys are lost, so are its files: iCloud Keychain holds the only copy. ") + Text("Create a recovery key").foregroundStyle(.kitLink)
      }
      if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Create") { create() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(name.isEmpty)
    }
  }

  private func create() {
    let parent = location ?? app.folders.decryptedRoot.deletingLastPathComponent().appendingPathComponent("Folders")
    do {
      let record = try app.folders.create(name: name, at: parent.appendingPathComponent(name, isDirectory: true))
      app.selection = .folder(record.id)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// Two fields side by side, one over the other on iPhone.
struct FieldRow<Content: View>: View {
  @ViewBuilder var content: Content
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if idiom == .phone {
      VStack(spacing: 12) { content }
    } else {
      HStack(alignment: .top, spacing: 12) { content }
    }
  }
}
