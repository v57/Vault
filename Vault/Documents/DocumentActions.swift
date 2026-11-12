import ComponentKit
import SwiftUI
import VaultKit

/// A document's quick actions, as rows of a kit menu: the context menu of its card and its list row (V-047), and the
/// inspector's More. Delete asks first (`documentDeletion`); `open` is left out where the document is open already.
struct DocumentMenuItems: View {
  let document: VaultDocument
  var open: (() -> Void)?
  var delete: () -> Void
  @Environment(AppModel.self) private var app

  var body: some View {
    let vault = app.vault
    let kind = vault.documentKinds[document.kind]
    if let open { Button("Open", systemImage: "eye", action: open) }
    Button("Share a Copy…", systemImage: "square.and.arrow.up") { app.sheet = .shareCopy(document.id) }
      .disabled(document.fileIDs.isEmpty)
    // The number (and any other hidden field) copies after the app lock allows it, cleared from the clipboard later.
    ForEach(kind.fields.filter { $0.format == .secret && document.secrets.contains($0.key) }, id: \.key) { field in
      Button("Copy \(field.label)", systemImage: "doc.on.doc") {
        Task {
          guard await AppLock.shared.allow(field.label) else { return }
          if let value = document.secret(field.key) { KitPasteboard.copySecret(value) }
        }
      }
    }
    Divider()
    Button("Edit…", systemImage: "pencil") { app.sheet = .editDocument(document.id) }
    Button("Duplicate", systemImage: "plus.square.on.square") { duplicate() }
      .kitMenuDetail("The next resume, or next year's policy")
    KitSubmenu("Move to", value: vault.collection(id: document.collection)?.name ?? String(localized: "Inbox"), systemImage: "folder") {
      Button("Inbox", systemImage: "tray") { move(to: "") }
        .kitMenuHighlighted(document.collection.isEmpty || vault.collection(id: document.collection) == nil)
      ForEach(vault.documentCollections) { collection in
        Button(collection.name, systemImage: DocumentSymbol.image(collection.symbol)) { move(to: collection.id) }
          .kitMenuHighlighted(document.collection == collection.id)
      }
    }
    Divider()
    Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
  }

  private func duplicate() {
    var copy: VaultDocument?
    app.vault.perform { copy = try $0.duplicateDocument(id: document.id) }
    if let copy {
      app.selectedDocument = copy.id
      app.sheet = .editDocument(copy.id)
    }
  }

  private func move(to collection: String) {
    guard collection != document.collection else { return }
    var moved = document
    moved.collection = collection
    app.vault.save(moved)
  }
}

extension View {
  /// Asks before deleting documents, then deletes them with their pages and hidden fields on every device.
  func documentDeletion(_ ids: Binding<[String]>, app: AppModel) -> some View {
    let documents = app.vault.documents.filter { ids.wrappedValue.contains($0.id) }
    let title =
      documents.count == 1
      ? String(localized: "Delete “\(documents[0].displayName(kinds: app.vault.documentKinds))”?")
      : String(localized: "Delete \(documents.count) documents?")
    return kitConfirmation(
      title, isPresented: Binding(get: { !ids.wrappedValue.isEmpty }, set: { if !$0 { ids.wrappedValue = [] } }),
      message: documents.count == 1
        ? String(localized: "Its pages are deleted on all your devices. This can’t be undone.")
        : String(localized: "Their pages are deleted on all your devices. This can’t be undone."),
      systemImage: "trash", confirm: String(localized: "Delete")
    ) { [ids = ids.wrappedValue] in
      if let open = app.openDocument, ids.contains(open) { app.openDocument = nil }
      if let selected = app.selectedDocument, ids.contains(selected) { app.selectedDocument = nil }
      app.vault.perform { store in
        for id in ids { try store.deleteDocument(id: id) }
      }
    }
  }
}
