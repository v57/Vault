import ComponentKit
import PlatformScan
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// Board 03: Add Document. The pages (scanned, imported, dropped, opened in Vault) with their edges to correct, what
/// they look like ("Looks like a passport"), the fields read from them, where it's filed, whose it is, tags and the
/// reminder. Editing a document uses the same sheet, and adds pages to it.
struct AddDocumentSheet: View {
  var editing: String?
  @Environment(AppModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.kitIdiom) private var idiom
  @State private var kind = DocumentKind.other.id
  @State private var title = ""
  @State private var collection = ""
  @State private var holder = ""
  @State private var fields: [String: String] = [:]
  @State private var secrets: [String: String] = [:]
  /// The saved secrets not shown yet (Edit): each asks the app lock before its field shows it, and one left hidden
  /// is saved unchanged.
  @State private var hiddenSecrets: Set<String> = []
  @Environment(\.kitSecretAccess) private var secretAccess
  @State private var tags = ""
  @State private var notes = ""
  @State private var remindMonths: Int?
  @State private var look = PageLook.color
  @State private var page: String?
  @State private var kindChosen = false
  @State private var collectionChosen = false
  @State private var showsKinds = false
  @State private var newHolder = ""
  @State private var addsHolder = false
  @State private var error: String?
  @State private var loaded = false
  #if os(iOS)
    @State private var scanning = false
    @State private var importing = false
  #endif

  private var vault: Vault { app.vault }
  private var existing: VaultDocument? { editing.flatMap { id in vault.documents.first { $0.id == id } } }
  private var info: DocumentImport { app.documentImport }

  var body: some View {
    let kinds = vault.documentKinds
    let documentKind = kinds[kind]
    KitSheet(
      title: existing.map { String(localized: "Edit “\($0.displayName(kinds: kinds))”") } ?? String(localized: "Add Document"),
      meta: info.isReading ? String(localized: "Reading the pages on this \(ThisDevice.word)…")
        : idiom == .phone ? String(localized: "Read on this \(ThisDevice.word); nothing leaves it")
        : String(localized: "Pages are read on this \(ThisDevice.word) and encrypted before they’re saved. Nothing leaves it."),
      systemImage: "doc.viewfinder", width: 780
    ) {
      pagesArea
      if let problem = info.problem { Text(problem).kitFont(.caption).foregroundStyle(Hue.red.text) }
      LabeledField("Looks like") {
        HStack(spacing: 8) {
          Button {
            showsKinds = true
          } label: {
            HStack(spacing: 6) {
              Image(systemName: DocumentSymbol.image(documentKind.symbol))
              Text(documentKind.name)
              Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
          }
          .buttonStyle(.kit)
          .kitMenu(isPresented: $showsKinds) {
            ForEach(kinds.all) { option in
              Button(option.name, systemImage: DocumentSymbol.image(option.symbol)) { choose(option) }
                .kitMenuHighlighted(option.id == kind)
            }
          }
          if info.suggestion != nil, !kindChosen, existing == nil {
            Text(info.suggestion?.zone?.isValid == true ? "from the machine-readable zone, check digits match" : "from the words on the pages")
              .kitFont(.caption)
          }
          Spacer()
        }
      }
      LabeledField("Title") {
        TextField(documentKind.name, text: $title).kitField()
      }
      fieldsGrid(documentKind)
      LabeledField("Collection") { collectionChips }
      LabeledField("Whose") { holderChips }
      FieldRow {
        LabeledField("Tags") { TextField("warranty, travel", text: $tags).kitField() }
        if let field = documentKind.remindingField {
          LabeledField("Reminder") {
            let months = remindMonths ?? documentKind.remindMonths ?? 0
            let stepper = KitStepper(value: Binding(get: { max(1, months) }, set: { remindMonths = $0 }), in: 1...24) {
              $0 == 1
                ? String(localized: "1 month before \(field.label.lowercased())")
                : String(localized: "\($0) months before \(field.label.lowercased())")
            }
            .disabled(months == 0)
            let toggle = Toggle("Remind", isOn: Binding(get: { months > 0 }, set: { remindMonths = $0 ? (documentKind.remindMonths ?? 3) : 0 }))
              .toggleStyle(.kitSwitch).labelsHidden()
            // On an iPhone the stepper and the switch don't fit on one line (the sheet grew past the screen): the
            // switch goes on a line of its own above.
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 8) {
                stepper
                Spacer(minLength: 0)
                toggle
              }
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text("Remind me").kitFont(.callout)
                  Spacer(minLength: 0)
                  toggle
                }
                stepper
              }
              .padding(.vertical, 6)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .kitSurface(.field)
          }
        }
      }
      LabeledField("Notes") { TextField("Where the original is, who to call", text: $notes, axis: .vertical).lineLimit(1...4).kitField() }
      if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
      SheetFooterButtons(
        saveTitle: existing == nil ? String(localized: "Add Document") : String(localized: "Save"),
        canSave: !info.isReading && (existing != nil || !info.pages.isEmpty || !title.isEmpty),
        status: String(localized: "Encrypted, synced to your \(app.devices.count) devices"), onSave: save)
    }
    .onAppear(perform: load)
    .onChange(of: info.suggestion) { _, suggestion in apply(suggestion) }
    #if os(iOS)
      .fullScreenCover(isPresented: $scanning) {
        DocumentCamera { pages in
          scanning = false
          app.importScans(pages.map(\.data), into: editing)
        } cancel: {
          scanning = false
        }
        .ignoresSafeArea()
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
        if case .success(let urls) = result { app.importDocuments(urls, into: editing) }
      }
    #endif
  }

  // MARK: Pages

  @ViewBuilder
  private var pagesArea: some View {
    let pages = info.pages
    if pages.isEmpty {
      VStack(spacing: 10) {
        if info.isReading {
          ProgressView().controlSize(.small)
          Text("Reading…").kitFont(.caption)
        } else {
          Image(systemName: "doc.viewfinder").font(.system(size: 26)).foregroundStyle(.kitTertiary)
          Text(existing == nil ? "Drop PDFs or photos here" : "Add pages: drop PDFs or photos here").kitFont(.headline)
          #if os(macOS)
            Text("or use File ▸ Import from iPhone or iPad ▸ Scan Documents").kitFont(.caption)
          #endif
          HStack(spacing: 8) {
            #if os(iOS)
              if DocumentCamera.isAvailable { Button("Scan…") { scanning = true }.buttonStyle(.kitPrimary) }
            #endif
            Button("Choose Files…", action: chooseFiles).buttonStyle(.kit)
          }
        }
      }
      .frame(maxWidth: .infinity, minHeight: existing == nil ? 180 : 110)
      .background {
        RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous)
          .strokeBorder(.kitBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
      }
      .dropDestination(for: URL.self) { urls, _ in
        app.importDocuments(urls, into: editing)
        return !urls.isEmpty
      }
    } else {
      let current = pages.first { $0.id == page } ?? pages[0]
      VStack(spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous).fill(.kitFillSoft)
          if current.corners != nil {
            KitPageCrop(
              imageData: current.preview, aspectRatio: current.aspectRatio,
              corners: Binding(
                get: { KitPageCorners(current.corners ?? KitPageCorners.full.points) },
                set: { corners in
                  if let index = app.documentImport.pages.firstIndex(where: { $0.id == current.id }) {
                    app.documentImport.pages[index].corners = corners.points
                  }
                })
            )
            .padding(14)
          } else {
            KitMarkedPage(imageData: current.preview, aspectRatio: current.aspectRatio).padding(18)
          }
        }
        .frame(height: idiom == .phone ? 260 : 300)
        let strip = KitPageStrip(
          pages: pages.map { KitPage(id: $0.id, label: $0.pageCount > 1 ? String(localized: "\($0.pageCount) pages") : $0.name, imageData: $0.preview, aspectRatio: $0.aspectRatio) },
          selection: Binding(get: { page ?? pages.first?.id }, set: { page = $0 }), height: 52, add: chooseFiles)
        if idiom == .phone {
          // No room beside the strip on an iPhone: the look and Remove Page go under it.
          VStack(alignment: .leading, spacing: 10) {
            strip
            HStack(spacing: 12) { pageControls(current) }
          }
        } else {
          HStack(alignment: .bottom, spacing: 12) {
            strip
            Spacer(minLength: 0)
            pageControls(current)
          }
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        app.importDocuments(urls, into: editing)
        return !urls.isEmpty
      }
    }
  }

  // MARK: Fields

  private func fieldsGrid(_ documentKind: DocumentKind) -> some View {
    let columns = idiom == .phone ? 1 : 2
    return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), alignment: .leading, spacing: 12) {
      ForEach(documentKind.fields, id: \.key) { field in
        LabeledField("\(field.label)") {
          switch field.format {
          case .secret where hiddenSecrets.contains(field.key):
            HStack {
              Text(verbatim: "••••••••").kitFont(.mono).foregroundStyle(.kitSecondary)
              Spacer()
              Button("Show") { show(field) }.buttonStyle(.kitPlain).controlSize(.small)
            }
            .padding(.horizontal, idiom == .mac ? 10 : 12)
            .padding(.vertical, 6)
            .kitSurface(.field)
          case .secret:
            TextField("Hidden until shown", text: Binding(get: { secrets[field.key] ?? "" }, set: { secrets[field.key] = $0 }))
              .kitField(mono: true)
          case .date:
            TextField("2032-03-12", text: binding(field.key))
              .kitField()
              .onSubmit { normalizeDate(field.key) }
          case .months:
            TextField("3 months", text: binding(field.key)).kitField()
          default:
            TextField(field.label, text: binding(field.key)).kitField()
          }
        }
      }
    }
  }

  /// A saved secret into its field, once the app lock allows it (Touch ID, Face ID, unless an unlock still holds).
  private func show(_ field: DocumentField) {
    Task {
      if let secretAccess, !(await secretAccess(field.label)) { return }
      secrets[field.key] = existing?.secret(field.key) ?? ""
      hiddenSecrets.remove(field.key)
    }
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
  }

  /// "12.03.2032", "March 12, 2032" → "2032-03-12", as the record keeps a day.
  private func normalizeDate(_ key: String) {
    guard let text = fields[key], !text.isEmpty else { return }
    if DocumentDay.date(from: text) == nil, let day = DocumentReader.firstDate(in: text) { fields[key] = day }
  }

  private var collectionChips: some View {
    KitFlowLayout(spacing: 4, lineSpacing: 4) {
      chip(isOn: collection.isEmpty, title: "Inbox", systemImage: "tray") { collection = ""; collectionChosen = true }
      ForEach(vault.documentCollections) { item in
        chip(isOn: collection == item.id, title: item.name, systemImage: DocumentSymbol.image(item.symbol)) {
          collection = item.id
          collectionChosen = true
        }
      }
    }
    .padding(3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .kitSurface(.field)
  }

  private var holderChips: some View {
    KitFlowLayout(spacing: 4, lineSpacing: 4) {
      chip(isOn: holder.isEmpty, title: "No one", systemImage: "person.slash") { holder = "" }
      ForEach(vault.holders) { person in
        chip(isOn: holder == person.id, title: person.name, systemImage: nil) { holder = person.id }
      }
      if addsHolder {
        HStack(spacing: 4) {
          TextField("Name", text: $newHolder).kitField().frame(width: 140).onSubmit(addHolder)
          Button("Add", action: addHolder).buttonStyle(.kit).controlSize(.small)
        }
      } else {
        Button("Add Person", systemImage: "plus") { addsHolder = true }.buttonStyle(.kitPlain).controlSize(.small)
      }
    }
    .padding(3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .kitSurface(.field)
  }

  private func chip(isOn: Bool, title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
    Toggle(isOn: Binding(get: { isOn }, set: { if $0 { action() } })) {
      if let systemImage { Label(title, systemImage: systemImage).lineLimit(1) } else { Text(title).lineLimit(1) }
    }
    .toggleStyle(.kitChip)
  }

  // MARK: Actions

  private func load() {
    guard !loaded else { return }
    loaded = true
    if let document = existing {
      kind = document.kind
      title = document.title
      collection = document.collection
      holder = document.holder
      fields = document.fields
      // Not read until shown: the number would sit in a plain field without the app lock asking (F3).
      hiddenSecrets = document.secrets
      tags = document.tags.sorted().joined(separator: ", ")
      notes = document.notes
      remindMonths = document.remindMonths
      kindChosen = true
      collectionChosen = true
    } else {
      if case .documents(let scope) = app.selection, vault.collection(id: scope) != nil {
        collection = scope
        collectionChosen = true
      }
      apply(info.suggestion)
    }
  }

  /// Fills what the pages suggested, leaving alone what the user picked or typed.
  private func apply(_ suggestion: DocumentSuggestion?) {
    guard let suggestion else { return }
    let kinds = vault.documentKinds
    if !kindChosen, existing == nil { kind = suggestion.kind }
    let documentKind = kinds[kind]
    for (key, value) in suggestion.fields {
      if documentKind.field(key)?.format == .secret {
        if (secrets[key] ?? "").isEmpty { secrets[key] = value }
      } else if (fields[key] ?? "").isEmpty, documentKind.field(key) != nil {
        fields[key] = value
      }
    }
    if !collectionChosen, existing == nil { collection = documentKind.collection }
    // The holder by name, when the pages name one we know.
    if holder.isEmpty, let match = app.holder(named: suggestion.fields["name"]) { holder = match }
  }

  private func choose(_ option: DocumentKind) {
    kind = option.id
    kindChosen = true
    if !collectionChosen, existing == nil { collection = option.collection }
    apply(info.suggestion)
  }

  private func addHolder() {
    let name = newHolder.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }
    let colors = ["purple", "teal", "pink", "orange", "indigo", "green"]
    let person = VaultHolder(name: name, color: colors[vault.holders.count % colors.count], order: vault.holders.count)
    vault.save(person)
    holder = person.id
    newHolder = ""
    addsHolder = false
  }

  /// The page's look (photos only) and Remove Page.
  @ViewBuilder private func pageControls(_ current: IncomingPage) -> some View {
    if info.pages.contains(where: { !$0.isPDF }) {
      KitSegmented(selection: $look, segments: [
        KitSegment("Color", value: .color), KitSegment("Grey", value: .grayscale), KitSegment("Document", value: .document),
      ])
      .controlSize(.small)
    }
    if idiom == .phone { Spacer(minLength: 0) }
    Button {
      app.documentImport.pages.removeAll { $0.id == current.id }
      page = nil
    } label: {
      Image(systemName: "trash")
    }
    .buttonStyle(.kit).controlSize(.small)
    .accessibilityLabel("Remove Page")
    .help("Remove Page")
  }

  private func chooseFiles() {
    #if os(iOS)
      importing = true
    #else
      Task {
        let urls = await KitDesktop.chooseFiles(
          title: String(localized: "Add Pages"), prompt: String(localized: "Add"), contentTypes: [.pdf, .image], allowsMultipleSelection: true)
        app.importDocuments(urls, into: editing)
      }
    #endif
  }

  private func save() {
    for field in vault.documentKinds[kind].fields where field.format == .date { normalizeDate(field.key) }
    var document = existing ?? VaultDocument(kind: kind, order: vault.documents.count)
    document.kind = kind
    document.title = title.trimmingCharacters(in: .whitespaces)
    document.collection = collection
    document.holder = holder
    document.fields = fields.mapValues { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.value.isEmpty }
    document.tags = Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    document.notes = notes
    document.remindMonths = remindMonths
    var secretChanges = secrets
    // A secret cleared in the form is removed.
    for key in existing?.secrets ?? [] where secretChanges[key] == nil && !hiddenSecrets.contains(key) { secretChanges[key] = "" }
    do {
      try app.saveDocument(document, secrets: secretChanges, look: look)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
