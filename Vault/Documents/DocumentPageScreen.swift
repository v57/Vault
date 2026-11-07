import ComponentKit
import PlatformScan
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// A document's pages loaded for the viewer: each file's pages as pictures (a PDF's rendered), in page order.
struct LoadedPage: Identifiable, Hashable {
  var id: String
  var fileID: String
  var label: String
  var image: Data
  var aspectRatio: CGFloat
}

enum DocumentPages {
  /// Every page of a document's files, as pictures (at most 40, PDFs' pages rendered).
  static func load(_ files: [VaultDocumentFile], kind: DocumentKind) -> [LoadedPage] {
    var pages: [LoadedPage] = []
    for (index, file) in files.enumerated() {
      let label = file.name.isEmpty ? (index < kind.sides.count ? kind.sides[index] : "Page \(pages.count + 1)") : file.name
      if file.isPDF {
        for page in 0..<min(file.pageCount, 40 - pages.count) {
          guard let image = PDFPages.render(file.data, page: page, maxPixel: 2000) else { continue }
          pages.append(LoadedPage(
            id: "\(file.id).\(page)", fileID: file.id, label: file.pageCount > 1 ? "\(label) \(page + 1)" : label,
            image: image.data, aspectRatio: CGFloat(image.width) / CGFloat(max(1, image.height))))
        }
      } else {
        let ratio = file.height > 0 ? CGFloat(file.width) / CGFloat(file.height) : kind.aspectRatio
        pages.append(LoadedPage(id: file.id, fileID: file.id, label: label, image: file.data, aspectRatio: ratio))
      }
      if pages.count >= 40 { break }
    }
    return pages
  }
}

/// Board 02: a document open large, its pages in a strip under the viewer, the inspector beside it. The machine-
/// readable zone and what Find on Pages matches are marked on the page, read on this device when the page shows.
struct DocumentPageScreen: View {
  let documentID: String
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var pages: [LoadedPage] = []
  @State private var page: String?
  @State private var zoom: CGFloat = 1
  @State private var rotation = 0
  @State private var lines: [String: [PageTextLine]] = [:]
  @State private var search = ""

  var body: some View {
    let vault = app.vault
    if let document = vault.documents.first(where: { $0.id == documentID }) {
      let kind = vault.documentKinds[document.kind]
      let collection = vault.collection(id: document.collection)
      let current = pages.first { $0.id == page } ?? pages.first
      ListAndInspector(name: "document") {
        VStack(spacing: 12) {
          KitPageViewer(
            imageData: current?.image ?? document.thumbnail, aspectRatio: current?.aspectRatio ?? kind.aspectRatio,
            zoom: zoom, rotation: rotation, highlights: current.map { highlights(on: $0) } ?? []
          ) {
            Button(zoom > 1 ? "Fit" : "Zoom", systemImage: zoom > 1 ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass") {
              withAnimation(.kit) { zoom = zoom > 1 ? 1 : 2 }
            }
            .buttonStyle(.kit)
            Spacer()
            Button("Rotate", systemImage: "rotate.right") { withAnimation(.kit) { rotation += 1 } }
              .buttonStyle(.kit).labelStyle(.iconOnly)
          }
          KitPageStrip(
            pages: pages.map { KitPage(id: $0.id, label: $0.label, imageData: $0.image, aspectRatio: $0.aspectRatio) },
            selection: Binding(get: { page ?? pages.first?.id }, set: { page = $0; rotation = 0; zoom = 1 })
          ) {
            addPages(to: document)
          }
          .frame(height: 96)
        }
        .padding(KitMetrics.gutter)
        .overlay {
          if pages.isEmpty && !document.fileIDs.isEmpty { ProgressView().controlSize(.small) }
        }
      } inspector: {
        DocumentInspector(document: document, isOpen: true)
      }
      .kitToolbar(document.displayName(kinds: vault.documentKinds)) {
        if idiom != .phone {
          ToolGroup(iconOnly: true) {
            Button("Back", systemImage: "chevron.left") { app.openDocument = nil }
              .keyboardShortcut(.escape, modifiers: [])
          }
        }
      } title: {
        KitTitle(
          document.displayName(kinds: vault.documentKinds),
          meta: [collection?.name ?? "Inbox", vault.holder(id: document.holder)?.name ?? "", pagesLine(document)].filter { !$0.isEmpty },
          systemImage: DocumentSymbol.image(kind.symbol), hue: collection.map { Hue(colorName: $0.color) } ?? .gray)
      } tools: {
        ToolGroup {
          Button("Share a Copy…", systemImage: "square.and.arrow.up") { app.sheet = .shareCopy(document.id) }
          Button("Edit", systemImage: "pencil") { app.sheet = .editDocument(document.id) }
        }
        if idiom != .phone { ToolbarSearch(text: $search, prompt: "Find on pages") }
      }
      .task(id: document.fileIDs) { await load(document, kind: kind) }
      .task(id: page ?? pages.first?.id) { await read(current) }
    } else {
      EmptyState(systemImage: "doc", title: "Document Deleted", message: "It was deleted here or on another device.") {
        Button("Back to Documents") { app.openDocument = nil }
      }
    }
  }

  private func pagesLine(_ document: VaultDocument) -> String {
    let count = pages.isEmpty ? document.fileIDs.count : pages.count
    return count == 1 ? "1 page" : "\(count) pages"
  }

  private func load(_ document: VaultDocument, kind: DocumentKind) async {
    guard let store = app.vault.store else { return }
    let files = (try? store.files(of: document)) ?? []
    let loaded = await Task.detached(priority: .userInitiated) { DocumentPages.load(files, kind: kind) }.value
    pages = loaded
    if page == nil || !loaded.contains(where: { $0.id == page }) { page = loaded.first?.id }
  }

  /// Reads the page's lines (once per page) for the marks.
  private func read(_ page: LoadedPage?) async {
    guard let page, lines[page.id] == nil, PageScanner.isAvailable else { return }
    lines[page.id] = (try? await PageScanner.lines(in: page.image)) ?? []
  }

  /// The machine-readable zone, and the lines Find on Pages matches.
  private func highlights(on page: LoadedPage) -> [KitPageHighlight] {
    guard let read = lines[page.id] else { return [] }
    var marks: [KitPageHighlight] = []
    let zoneLines = read.filter(\.looksLikeZone)
    if let first = zoneLines.first {
      let box = zoneLines.dropFirst().reduce(first.box) { $0.union($1.box) }
      let zone = MachineReadableZone(text: zoneLines.map(\.text))
      marks.append(KitPageHighlight(
        id: "mrz", rect: rect(box, pad: 0.008),
        label: zone?.isValid == true ? "Machine-readable zone · check digits match" : "Machine-readable zone",
        systemImage: zone?.isValid == true ? "checkmark.shield" : "exclamationmark.triangle",
        hue: zone?.isValid == true ? .accent : .orange))
    }
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    if !query.isEmpty {
      for (index, line) in read.enumerated() where line.text.lowercased().contains(query) {
        marks.append(KitPageHighlight(id: "find.\(index)", rect: rect(line.box, pad: 0.004), hue: .yellow))
      }
    }
    return marks
  }

  private func rect(_ box: PageRect, pad: Double) -> CGRect {
    CGRect(x: box.x - pad, y: box.y - pad, width: box.width + pad * 2, height: box.height + pad * 2)
  }

  private func addPages(to document: VaultDocument) {
    #if os(macOS)
      Task {
        let urls = await KitDesktop.chooseFiles(
          title: "Add Pages", prompt: "Add", contentTypes: [.pdf, .image], allowsMultipleSelection: true)
        app.importDocuments(urls, into: document.id)
      }
    #else
      app.sheet = .editDocument(document.id)
    #endif
  }
}

// MARK: - Inspector

/// The selected document: what was read on it, its reminder, its pages, the copies given out and what it's linked to.
struct DocumentInspector: View {
  let document: VaultDocument
  var isOpen = false
  @Environment(AppModel.self) private var app
  @State private var files: [FileSummary] = []
  @State private var confirmsDelete = false
  @State private var showsMore = false

  struct FileSummary: Identifiable, Hashable {
    var id: String
    var name: String
    var pages: Int
    var isPDF: Bool
    var created: Date?
  }

  var body: some View {
    let vault = app.vault
    let kind = vault.documentKinds[document.kind]
    let holder = vault.holder(id: document.holder)
    let collection = vault.collection(id: document.collection)
    InspectorHeader(
      document.displayName(kinds: vault.documentKinds),
      meta: [kind.name, holder?.name ?? "", document.fields["country"] ?? document.fields["insurer"] ?? ""].filter { !$0.isEmpty },
      systemImage: DocumentSymbol.image(kind.symbol), hue: collection.map { Hue(colorName: $0.color) } ?? .gray
    ) {
      if let state = validity(kind) { Chip(state.0, hue: state.1).controlSize(.small) }
      if let collection { Chip(collection.name).controlSize(.small) }
      ForEach(document.tags.sorted(), id: \.self) { Chip($0, style: .quiet).controlSize(.small) }
    }
    KitSection(
      kind.name, meta: [document.text.isEmpty ? "typed in" : "read from the pages", document.created.map { "added \(RelativeTime.day($0))" } ?? ""].filter { !$0.isEmpty },
      systemImage: DocumentSymbol.image(kind.symbol), hue: collection.map { Hue(colorName: $0.color) } ?? .gray
    ) {
      ForEach(kind.fields, id: \.key) { field in
        if field.format == .secret {
          if document.secrets.contains(field.key) {
            InspectorRow(field.label) { KitSecretValue(label: field.label) { document.secret(field.key) ?? "" } }
          }
        } else if let value = document.shown(field) {
          InspectorRow(field.label, value: value)
        }
      }
      // Fields of a kind that changed or was deleted stay readable.
      ForEach(document.fields.keys.filter { kind.field($0) == nil }.sorted(), id: \.self) { key in
        InspectorRow(key.capitalized, value: document.fields[key] ?? "")
      }
      if kind.fields.allSatisfy({ document.shown($0) == nil && !document.secrets.contains($0.key) }) && document.fields.isEmpty {
        Text("Nothing filled in yet.").kitFont(.caption).padding(8)
      }
    }
    if let field = kind.remindingField { ReminderSection(document: document, kind: kind, field: field) }
    if !document.fileIDs.isEmpty {
      KitSection(
        "Pages", meta: [counted(files.count, "file"), counted(files.reduce(0) { $0 + $1.pages }, "page"), "encrypted"],
        systemImage: "doc.on.doc", hue: .gray
      ) {
        ForEach(files) { file in
          LinkRow(
            title: file.name.isEmpty ? (file.isPDF ? "PDF" : "Page") : file.name,
            subtitle: [file.pages == 1 ? "1 page" : "\(file.pages) pages", file.isPDF ? "PDF" : "scan", file.created.map { RelativeTime.day($0) } ?? ""]
              .filter { !$0.isEmpty }.joined(separator: " · "),
            systemImage: file.isPDF ? "doc.richtext" : "photo"
          ) {
            app.openDocument = document.id
          }
        }
      }
    }
    if !document.copies.isEmpty {
      KitSection("Copies Shared", meta: [document.copies.count == 1 ? "1 copy" : "\(document.copies.count) copies", "each carries its watermark"], systemImage: "seal", hue: .purple) {
        ForEach(document.copies.sorted { $0.value.date > $1.value.date }, id: \.key) { _, copy in
          HStack(spacing: 10) {
            RowTile(systemImage: "doc.badge.arrow.up")
            VStack(alignment: .leading, spacing: 1) {
              Text(copy.purpose.isEmpty ? "A copy" : copy.purpose).lineLimit(1)
              Text([DocumentDates.long(copy.date), copy.hidden.isEmpty ? "nothing hidden" : "\(copy.hidden.joined(separator: " and ")) hidden"]
                .joined(separator: " · ")).kitFont(.caption).lineLimit(1)
            }
            Spacer()
          }
          .padding(.horizontal, 8).frame(minHeight: 40)
        }
      }
    }
    let linked = links()
    if !linked.isEmpty {
      KitSection("Linked", meta: [linked.count == 1 ? "1 item" : "\(linked.count) items", "every v57 app sees the link"], systemImage: "link", hue: .teal) {
        ForEach(linked, id: \.id) { item in
          LinkRow(title: item.title, subtitle: item.subtitle, systemImage: item.systemImage, action: item.open)
        }
      }
    }
    if !document.notes.isEmpty {
      KitSection("Notes", systemImage: "text.alignleft", hue: .yellow) {
        Text(document.notes).kitFont(.callout).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    HStack(spacing: 6) {
      if !isOpen { Button("Open", systemImage: "eye") { app.openDocument = document.id } }
      Button("Share a Copy…", systemImage: "square.and.arrow.up") { app.sheet = .shareCopy(document.id) }
        .disabled(document.fileIDs.isEmpty)
      Button("More", systemImage: "ellipsis") { showsMore = true }
        .labelStyle(.iconOnly)
        .kitMenu(isPresented: $showsMore) {
          Button("Edit…", systemImage: "pencil") { app.sheet = .editDocument(document.id) }
          Button("Duplicate", systemImage: "plus.square.on.square") { duplicate() }
            .kitMenuDetail("The next resume, or next year's policy")
          Divider()
          Button("Delete…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        }
    }
    .buttonStyle(.kit)
    .padding(.horizontal, 6)
    .kitConfirmation(
      "Delete “\(document.displayName(kinds: app.vault.documentKinds))”?", isPresented: $confirmsDelete,
      message: "Its pages are deleted on all your devices. This can’t be undone.", systemImage: "trash", confirm: "Delete"
    ) {
      let id = document.id
      app.openDocument = nil
      app.selectedDocument = nil
      app.vault.perform { try $0.deleteDocument(id: id) }
    }
    .task(id: document.fileIDs) { loadFiles() }
  }

  /// "Valid for 5 years", "Expires in 74 days", "Expired".
  private func validity(_ kind: DocumentKind) -> (String, Hue)? {
    guard let field = kind.remindingField, let date = document.day(field.key) else { return nil }
    let days = DocumentDay.days(from: .now, to: date)
    if days < 0 { return ("Expired", .red) }
    if days < 90 { return ("\(field.label) in \(DocumentDates.left(date))", .orange) }
    let years = days / 365
    return (years >= 1 ? "Valid for \(years) year\(years == 1 ? "" : "s")" : "Valid for \(days / 30) months", .green)
  }

  private func loadFiles() {
    guard let store = app.vault.store else { return }
    files = ((try? store.files(of: document)) ?? []).map {
      FileSummary(id: $0.id, name: $0.name, pages: $0.pageCount, isPDF: $0.isPDF, created: $0.created)
    }
  }

  private func duplicate() {
    var copy: VaultDocument?
    app.vault.perform { copy = try $0.duplicateDocument(id: document.id) }
    if let copy {
      app.selectedDocument = copy.id
      app.sheet = .editDocument(copy.id)
    }
  }

  private struct Linked {
    var id: String
    var title: String
    var subtitle: String
    var systemImage: String
    var open: () -> Void
  }

  private func links() -> [Linked] {
    let vault = app.vault
    return document.links.sorted().compactMap { id in
      if let login = vault.logins.first(where: { $0.id == id }) {
        return Linked(id: id, title: login.displayName, subtitle: "Login · \(login.domain ?? login.username)", systemImage: "key.horizontal") {
          app.selectedLogin = id
          app.selection = .logins
        }
      }
      if let card = vault.cards.first(where: { $0.id == id }) {
        return Linked(id: id, title: "\(card.title) •••• \(card.last4)", subtitle: "Card", systemImage: "creditcard") {
          app.selection = .cards
        }
      }
      if let other = vault.documents.first(where: { $0.id == id }) {
        let kind = vault.documentKinds[other.kind]
        return Linked(
          id: id, title: other.displayName(kinds: vault.documentKinds),
          subtitle: [vault.collection(id: other.collection)?.name ?? "Inbox", kind.name].joined(separator: " · "),
          systemImage: DocumentSymbol.image(kind.symbol)
        ) {
          app.selectedDocument = id
          if app.openDocument != nil { app.openDocument = id }
        }
      }
      return nil
    }
  }
}

/// When the reminder goes off: months before the reminding date, on or off.
private struct ReminderSection: View {
  let document: VaultDocument
  let kind: DocumentKind
  let field: DocumentField
  @Environment(AppModel.self) private var app

  var body: some View {
    let months = document.remindMonths ?? kind.remindMonths ?? 0
    let date = document.day(field.key)
    KitSection("Reminder", meta: ["on your \(app.devices.count) devices", "nothing leaves them"], systemImage: "bell", hue: .orange) {
      HStack(spacing: 10) {
        KitStepper(
          value: Binding(get: { max(1, months) }, set: { set($0) }), in: 1...24,
          format: { "\($0) month\($0 == 1 ? "" : "s") before it \(field.key == "expires" ? "expires" : field.label.lowercased())" }
        )
        .disabled(months == 0)
        Spacer(minLength: 6)
        if let date, months > 0 {
          Text(DocumentDates.long(DocumentDay.date(date, monthsBefore: months))).kitFont(.callout).monospacedDigit()
        }
        Toggle("Remind", isOn: Binding(get: { months > 0 }, set: { set($0 ? (kind.remindMonths ?? 3) : 0) }))
          .toggleStyle(.kitSwitch).labelsHidden()
      }
      .padding(.horizontal, 8).frame(minHeight: 40)
      if kind.id == DocumentKind.passport.id {
        Text("Many countries want 6 months left when you arrive.").kitFont(.caption).padding(.horizontal, 8).padding(.bottom, 6)
      } else if let notice = kind.noticeField, let value = document.shown(notice) {
        Text("Notice period \(value): Coming Up shows the last day to cancel.").kitFont(.caption)
          .padding(.horizontal, 8).padding(.bottom, 6)
      }
    }
  }

  private func set(_ months: Int) {
    var changed = document
    changed.remindMonths = months == (kind.remindMonths ?? -1) ? nil : months
    app.vault.save(changed)
  }
}
