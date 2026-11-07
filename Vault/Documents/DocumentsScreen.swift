import ComponentKit
import PlatformScan
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

/// Which documents the library shows.
enum DocumentFilter: String, KitOption, CaseIterable {
  case all, comingUp, recent

  var title: String {
    switch self {
    case .all: "All"
    case .comingUp: "Coming Up"
    case .recent: "Recent"
    }
  }
}

/// Board 01 and 05: a scope's documents as cards per collection (or a list), Coming Up above them, the selected one
/// in the inspector; a document opens large in the same place (board 02).
struct DocumentsScreen: View {
  let scope: String
  @Environment(AppModel.self) private var app

  var body: some View {
    if let id = app.openDocument, app.vault.documents.contains(where: { $0.id == id }) {
      DocumentPageScreen(documentID: id)
    } else {
      DocumentLibrary(scope: scope)
    }
  }
}

private struct DocumentLibrary: View {
  let scope: String
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @State private var filter = DocumentFilter.all
  @State private var holder: String?
  @State private var search = ""
  @KitStorage("documents.list") private var showsList = false
  @State private var listSelection: Set<String> = []
  @State private var scanning = false
  @State private var pushed: String?

  private var vault: Vault { app.vault }

  private var documents: [VaultDocument] {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    let kinds = vault.documentKinds
    let soon = Set(vault.documentEvents.map(\.document))
    var list = vault.documents(in: scope).filter { document in
      (holder == nil || document.holder == holder)
        && (filter != .comingUp || soon.contains(document.id))
        && (query.isEmpty || Self.matches(document, query, kinds: kinds))
    }
    if filter == .recent {
      list.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
      list = Array(list.prefix(24))
    }
    return list
  }

  static func matches(_ document: VaultDocument, _ query: String, kinds: DocumentKinds) -> Bool {
    document.displayName(kinds: kinds).lowercased().contains(query) || kinds[document.kind].name.lowercased().contains(query)
      || document.fields.values.contains { $0.lowercased().contains(query) }
      || document.tags.contains { $0.lowercased().contains(query) } || document.text.lowercased().contains(query)
  }

  private var title: String {
    switch scope {
    case DocumentScope.all: "All Documents"
    case DocumentScope.inbox: "Inbox"
    default: vault.collection(id: scope)?.name ?? "Documents"
    }
  }

  private var tile: (String, Hue) {
    switch scope {
    case DocumentScope.all: ("doc.on.doc", .purple)
    case DocumentScope.inbox: ("tray", .gray)
    default:
      vault.collection(id: scope).map { (DocumentSymbol.image($0.symbol), Hue(colorName: $0.color)) } ?? ("doc", .gray)
    }
  }

  var body: some View {
    let documents = documents
    let all = vault.documents(in: scope)
    let pages = all.reduce(0) { $0 + $1.fileIDs.count }
    let people = Set(all.map(\.holder).filter { !$0.isEmpty }).count
    ListAndInspector(name: "documents") {
      VStack(spacing: 0) {
        filterBar
        if all.isEmpty && search.isEmpty {
          emptyLibrary
        } else if showsList && idiom != .phone {
          DocumentTable(documents: documents, selection: $listSelection)
            .padding(KitMetrics.gutter)
        } else {
          CardScroll {
            if filter != .recent && holder == nil && search.isEmpty { ComingUpSection(scope: scope) }
            sections(documents)
            if documents.isEmpty {
              Text(search.isEmpty ? "Nothing here with these filters." : "No documents match “\(search)”.")
                .kitFont(.caption).padding(12)
            }
          }
        }
      }
      .paneStatusBar(systemImage: "lock", hue: .green, status: .done) {
        Text("Pages encrypted on this \(ThisDevice.word)")
        Text(app.isDemo || vault.sync?.isRunning == true ? "synced through iCloud \(app.syncedLine.replacingOccurrences(of: "synced ", with: ""))" : "on this device")
          .foregroundStyle(.kitSecondary)
        Text(counted(vault.documents.count, "document")).foregroundStyle(.kitSecondary)
      }
      .dropDestination(for: URL.self) { urls, _ in
        app.importDocuments(urls)
        return !urls.isEmpty
      }
      #if os(macOS)
        // File ▸ Import from iPhone or iPad: Take Photo, Scan Documents (Continuity Camera).
        .importsItemProviders([.pdf, .image]) { providers in
          Task { await importProviders(providers) }
          return !providers.isEmpty
        }
      #endif
    } inspector: {
      if listSelection.count > 1 && showsList {
        FileTogetherInspector(ids: listSelection)
      } else if let document = vault.documents.first(where: { $0.id == app.selectedDocument }) {
        DocumentInspector(document: document)
      } else {
        EmptyState(systemImage: "doc.on.doc", title: "No Document Selected", message: "Pick a document to see what was read on it.")
      }
    }
    .kitToolbar(title, meta: [counted(all.count, "document"), counted(pages, "page"), people > 0 ? counted(people, "person", plural: "people") : ""].filter { !$0.isEmpty }, systemImage: tile.0, hue: tile.1) {
      if idiom == .phone {
        Button("Add", systemImage: "plus") { startScan() }.buttonStyle(.kitRound)
      } else {
        ToolGroup {
          if DocumentCamera.isAvailable { Button("Scan", systemImage: "doc.viewfinder") { scanning = true } }
          Button("Import", systemImage: "square.and.arrow.down") { chooseFiles() }
        }
        ToolbarSearch(text: $search, prompt: "Names, numbers, text on pages")
      }
    }
    .phoneBottomBar(prompt: "Names, numbers, text on pages", search: $search) {
      Button("Import", systemImage: "square.and.arrow.down") { chooseFiles() }
    }
    .onAppear {
      if vault.documentCollections.isEmpty, !app.isDemo { vault.perform { try $0.addDefaultDocumentCollections() } }
      if app.selectedDocument == nil || !all.contains(where: { $0.id == app.selectedDocument }) {
        app.selectedDocument = documents.first?.id
      }
      listSelection = app.selectedDocument.map { [$0] } ?? []
    }
    .onChange(of: listSelection) { _, ids in if ids.count == 1 { app.selectedDocument = ids.first } }
    #if os(iOS)
      .fullScreenCover(isPresented: $scanning) {
        DocumentCamera { pages in
          scanning = false
          app.importScans(pages.map(\.data))
        } cancel: {
          scanning = false
        }
        .ignoresSafeArea()
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
        if case .success(let urls) = result { app.importDocuments(urls) }
      }
    #endif
    .navigationDestination(item: $pushed) { id in DocumentPageScreen(documentID: id) }
  }

  #if os(iOS)
    @State private var importing = false
  #endif

  // MARK: Parts

  private var filterBar: some View {
    HStack(spacing: 8) {
      KitSegmented(selection: $filter)
      if !vault.holders.isEmpty, idiom != .phone {
        HStack(spacing: 2) {
          holderToggle(nil, "Everyone")
          ForEach(vault.holders) { person in holderToggle(person.id, person.name.split(separator: " ").first.map(String.init) ?? person.name) }
        }
        .padding(3)
        .kitSurface(.field)
      }
      Spacer()
      if idiom != .phone {
        Text(showsList ? "By date" : "By collection").kitFont(.caption).lineLimit(1).fixedSize()
        KitSegmented(selection: $showsList, segments: [
          KitSegment("Cards", value: false, systemImage: "square.grid.2x2"),
          KitSegment("List", value: true, systemImage: "list.bullet"),
        ])
        .labelStyle(.iconOnly)
      }
    }
    .padding(.horizontal, KitMetrics.gutter + 4)
    .padding(.vertical, 6)
  }

  private func holderToggle(_ id: String?, _ name: String) -> some View {
    Toggle(isOn: Binding(get: { holder == id }, set: { if $0 { holder = id } })) {
      HStack(spacing: 5) {
        if let id, let person = vault.holder(id: id) {
          Avatar(name: person.name, hue: Hue(colorName: person.color), size: 14)
        } else {
          Image(systemName: "person.2").font(.system(size: 10, weight: .semibold))
        }
        Text(name).lineLimit(1)
      }
      .fixedSize()
    }
    .toggleStyle(.kitChip)
  }

  @ViewBuilder
  private func sections(_ documents: [VaultDocument]) -> some View {
    if scope == DocumentScope.all && filter == .all && search.isEmpty {
      ForEach(vault.documentCollections) { collection in
        let inside = documents.filter { $0.collection == collection.id }
        if !inside.isEmpty {
          CollectionSection(collection: collection, documents: inside, limit: 4, pushed: $pushed)
        }
      }
      let unfiled = documents.filter { $0.collection.isEmpty || vault.collection(id: $0.collection) == nil }
      if !unfiled.isEmpty {
        CollectionSection(
          collection: VaultDocumentCollection(id: DocumentScope.inbox, name: "Inbox", symbol: "tray", color: "gray"),
          documents: unfiled, limit: 4, pushed: $pushed)
      }
    } else if !documents.isEmpty {
      let collection = vault.collection(id: scope)
        ?? VaultDocumentCollection(id: scope, name: filter == .all ? title : filter.title, symbol: scope == DocumentScope.inbox ? "tray" : "doc", color: scope == DocumentScope.inbox ? "gray" : "purple")
      CollectionSection(collection: collection, documents: documents, limit: nil, pushed: $pushed)
    }
  }

  private var emptyLibrary: some View {
    EmptyState(
      systemImage: tile.0, title: scope == DocumentScope.inbox ? "Inbox Is Empty" : "No Documents Yet",
      message: "Scan a passport, import a policy, or drop PDFs and photos here. Pages are read on this \(ThisDevice.word) and encrypted before they’re saved."
    ) {
      if DocumentCamera.isAvailable { Button("Scan…") { startScan() } }
      Button("Import…") { chooseFiles() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Actions

  private func startScan() {
    if DocumentCamera.isAvailable { scanning = true } else { app.newDocument() }
  }

  private func chooseFiles() {
    #if os(iOS)
      importing = true
    #else
      Task {
        let urls = await KitDesktop.chooseFiles(
          title: "Import Documents", prompt: "Import", contentTypes: [.pdf, .image], allowsMultipleSelection: true)
        app.importDocuments(urls)
      }
    #endif
  }

  private func importProviders(_ providers: [NSItemProvider]) async {
    var pages: [Data] = []
    for provider in providers {
      for type in [UTType.pdf, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
        if let data = try? await provider.loadData(type.identifier) {
          pages.append(data)
          break
        }
      }
    }
    app.importScans(pages, isScan: false)
  }
}

extension NSItemProvider {
  fileprivate func loadData(_ type: String) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      _ = loadDataRepresentation(forTypeIdentifier: type) { data, error in
        if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? PageReadError("No data")) }
      }
    }
  }
}

// MARK: - Coming Up

/// The next 90 days of expiries, renewals and notice dates, and the inbox's waiting scans.
private struct ComingUpSection: View {
  let scope: String
  @Environment(AppModel.self) private var app

  var body: some View {
    let vault = app.vault
    let inScope = Set(vault.documents(in: scope).map(\.id))
    let events = vault.documentEvents.filter { inScope.contains($0.document) }
    let inbox = vault.documents(in: DocumentScope.inbox)
    if !events.isEmpty || (!inbox.isEmpty && scope == DocumentScope.all) {
      KitSection(
        "Coming Up", meta: ["next 90 days", "reminders on your \(app.devices.count) devices"], systemImage: "bell", hue: .orange
      ) {
        ForEach(events) { event in
          if let document = vault.documents.first(where: { $0.id == event.document }) {
            EventRow(event: event, document: document)
          }
        }
        if !inbox.isEmpty && scope == DocumentScope.all {
          HStack(spacing: 10) {
            RowTile(systemImage: "tray", hue: .gray)
            VStack(alignment: .leading, spacing: 1) {
              Text(inbox.count == 1 ? "1 scan in Inbox" : "\(inbox.count) scans in Inbox").lineLimit(1)
              Text(inbox.prefix(3).map { $0.displayName(kinds: vault.documentKinds) }.joined(separator: ", "))
                .kitFont(.caption).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("File…") { app.selection = .documents(DocumentScope.inbox) }.buttonStyle(.kit).controlSize(.small)
          }
          .padding(.horizontal, 8)
          .frame(minHeight: 40)
        }
      }
    }
  }
}

private struct EventRow: View {
  let event: DocumentEvent
  let document: VaultDocument
  @Environment(AppModel.self) private var app

  var body: some View {
    let vault = app.vault
    let kind = vault.documentKinds[document.kind]
    let holder = vault.holder(id: document.holder)
    let collection = vault.collection(id: document.collection)
    let days = DocumentDay.days(from: .now, to: event.date)
    let name = holder.map { "\($0.name.split(separator: " ").first ?? "")’s \(kind.name.lowercased())" } ?? document.displayName(kinds: vault.documentKinds)
    Button {
      app.selectedDocument = document.id
    } label: {
      HStack(spacing: 10) {
        RowTile(systemImage: DocumentSymbol.image(kind.symbol), hue: collection.map { Hue(colorName: $0.color) } ?? .gray)
        VStack(alignment: .leading, spacing: 1) {
          Text(document.title.isEmpty ? name : document.title).lineLimit(1)
          Text("\(event.label) \(DocumentDates.long(event.date))" + (event.kind == .notice ? " to switch or cancel" : ""))
            .kitFont(.caption).lineLimit(1)
        }
        Spacer(minLength: 8)
        Chip(days < 0 ? "passed" : DocumentDates.left(event.date), hue: days < 0 ? .red : days <= 30 ? .red : .orange)
          .controlSize(.small)
      }
      .padding(.horizontal, 8)
      .frame(minHeight: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - A collection's cards

private struct CollectionSection: View {
  let collection: VaultDocumentCollection
  let documents: [VaultDocument]
  /// Cards shown before Show All; nil for every one.
  let limit: Int?
  @Binding var pushed: String?
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let vault = app.vault
    let holders = Set(documents.map(\.holder)).compactMap(vault.holder(id:)).map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
    let shown = limit.map { Array(documents.prefix($0)) } ?? documents
    KitSection(
      collection.name, meta: [counted(documents.count, "document")] + (holders.isEmpty ? [] : [holders.sorted().joined(separator: ", ")]),
      systemImage: DocumentSymbol.image(collection.symbol), hue: Hue(colorName: collection.color)
    ) {
      KitDocumentGrid(minimumWidth: idiom == .phone ? 140 : 160) {
        ForEach(shown) { document in DocumentCard(document: document, pushed: $pushed) }
      }
      .padding(.horizontal, 2)
    } accessory: {
      if let limit, documents.count > limit {
        Button("Show all \(documents.count)") { app.selection = .documents(collection.id) }
          .buttonStyle(.kitPlain).controlSize(.small)
      }
    }
  }
}

/// A document's card: its first page, the next event's days in the corner, the holder and the date that matters.
struct DocumentCard: View {
  let document: VaultDocument
  @Binding var pushed: String?
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    let vault = app.vault
    let kind = vault.documentKinds[document.kind]
    let holder = vault.holder(id: document.holder)
    // A passed notice date is the inspector's to say; the card counts down to the date itself.
    let next = document.events(kind: kind).first { event in
      let days = DocumentDay.days(from: .now, to: event.date)
      return event.remindOn <= .now && (event.kind == .notice ? days >= 0 : days >= -30)
    }
    let line = subtitle(kind: kind, holder: holder)
    KitDocumentCard(
      document.displayName(kinds: vault.documentKinds), imageData: document.thumbnail, aspectRatio: kind.aspectRatio,
      pages: max(1, document.fileIDs.count), isSelected: app.selectedDocument == document.id,
      badge: next.map { DocumentDay.days(from: .now, to: $0.date) < 0 ? ($0.kind == .notice ? "notice passed" : "expired") : DocumentDates.left($0.date) },
      badgeHue: next.map { DocumentDay.days(from: .now, to: $0.date) <= 30 ? .red : .orange } ?? .orange
    ) {
      if let holder { Avatar(name: holder.name, hue: Hue(colorName: holder.color), size: 14) }
      Text(line)
    } action: {
      app.selectedDocument = document.id
      if idiom == .phone { pushed = document.id }
    } open: {
      if idiom == .phone { pushed = document.id } else { app.openDocument = document.id }
    }
  }

  /// "Aiko · until 2032", "Haus&Hof · both".
  private func subtitle(kind: DocumentKind, holder: VaultHolder?) -> String {
    var parts: [String] = []
    let issuer = ["insurer", "employer", "issuer", "bank", "provider", "landlord", "shop", "role"].lazy
      .compactMap { document.fields[$0] }.first { !$0.isEmpty }
    if let issuer, kind.collection != DocumentCollectionID.identity { parts.append(issuer) }
    if let holder { parts.append(holder.name.split(separator: " ").first.map(String.init) ?? holder.name) }
    if let field = kind.remindingField, let date = document.day(field.key) {
      parts.append("until \(DocumentDates.short(date))")
    } else if let created = document.created, parts.count < 2 {
      parts.append(created.formatted(.dateTime.month(.abbreviated).year()))
    }
    return parts.joined(separator: " · ")
  }
}

// MARK: - List and filing together (board 05)

private struct DocumentTable: View {
  let documents: [VaultDocument]
  @Binding var selection: Set<String>
  @Environment(AppModel.self) private var app

  var body: some View {
    let vault = app.vault
    let kinds = vault.documentKinds
    KitGrid(documents, columns: [
      KitGridColumn("Name", width: 220) { document in
        HStack(spacing: 8) {
          Image(systemName: DocumentSymbol.image(kinds[document.kind].symbol)).font(.system(size: 12))
            .foregroundStyle(Hue(colorName: vault.collection(id: document.collection)?.color ?? "gray").fill)
          Text(document.displayName(kinds: kinds)).lineLimit(1)
        }
      },
      KitGridColumn("Kind", width: 130) { kinds[$0.kind].name },
      KitGridColumn("Holder", width: 90) { vault.holder(id: $0.holder)?.name.split(separator: " ").first.map(String.init) ?? "—" },
      KitGridColumn("Collection", width: 120) { vault.collection(id: $0.collection)?.name ?? "Inbox" },
      KitGridColumn("Ends or renews", width: 120) { document in
        kinds[document.kind].remindingField.flatMap { document.day($0.key) }.map(DocumentDates.long) ?? "—"
      },
      KitGridColumn("Pages", width: 60, alignment: .trailing) { "\(max(1, $0.fileIDs.count))" },
    ], selection: $selection)
  }
}

/// Several documents selected in the list: file them, set whose they are and tag them at once.
private struct FileTogetherInspector: View {
  let ids: Set<String>
  @Environment(AppModel.self) private var app
  @State private var tag = ""

  var body: some View {
    let vault = app.vault
    let documents = vault.documents.filter { ids.contains($0.id) }
    InspectorHeader("\(documents.count) Documents", meta: ["File them together"], systemImage: "doc.on.doc", hue: .purple)
    KitSection("Collection", meta: "where they live", systemImage: "folder", hue: .purple) {
      ForEach(vault.documentCollections) { collection in
        let isOn = documents.allSatisfy { $0.collection == collection.id }
        Button {
          update(documents) { $0.collection = collection.id }
        } label: {
          HStack(spacing: 10) {
            RowTile(systemImage: DocumentSymbol.image(collection.symbol), hue: Hue(colorName: collection.color))
            Text(collection.name)
            Spacer()
            if isOn { Image(systemName: "checkmark").foregroundStyle(.kitAccent) }
          }
          .padding(.horizontal, 8).frame(minHeight: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    if !vault.holders.isEmpty {
      KitSection("Whose", meta: "holder", systemImage: "person", hue: .blue) {
        ForEach(vault.holders) { person in
          Button {
            update(documents) { $0.holder = person.id }
          } label: {
            HStack(spacing: 10) {
              Avatar(name: person.name, hue: Hue(colorName: person.color), size: 22)
              Text(person.name)
              Spacer()
              if documents.allSatisfy({ $0.holder == person.id }) { Image(systemName: "checkmark").foregroundStyle(.kitAccent) }
            }
            .padding(.horizontal, 8).frame(minHeight: 34).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    KitSection("Tags", meta: "added to each", systemImage: "tag", hue: .gray) {
      HStack {
        TextField("warranty, moving-in", text: $tag).kitField().onSubmit(addTag)
        Button("Add", action: addTag).buttonStyle(.kit).disabled(tag.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(6)
    }
  }

  private func addTag() {
    let words = tag.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    update(app.vault.documents.filter { ids.contains($0.id) }) { $0.tags.formUnion(words) }
    tag = ""
  }

  private func update(_ documents: [VaultDocument], _ change: (inout VaultDocument) -> Void) {
    app.vault.perform { store in
      for var document in documents {
        change(&document)
        try store.save(document)
      }
    }
  }
}
