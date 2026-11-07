import ComponentKit
import SwiftUI
import VaultKit

/// Settings › Documents: the collections documents are filed in and the people they belong to. Deleting either moves
/// nothing and loses nothing: a collection's documents go to the Inbox, a person's documents become no one's.
struct DocumentsSettingsPane: View {
  @Environment(AppModel.self) private var app
  @State private var editing: GroupEdit?
  @State private var deleting: GroupEdit?

  private var vault: Vault { app.vault }

  var body: some View {
    let collections = vault.documentCollections
    let suggestions = VaultDocumentCollection.suggestions.filter { suggestion in
      !collections.contains { $0.name.lowercased() == suggestion.name.lowercased() }
    }
    FormCard("Collections", footer: "Deleting a collection moves its documents to the Inbox. Identity stays: passports and IDs are filed there.") {
      ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
        let count = vault.documents.filter { $0.collection == collection.id }.count
        FormRow(
          collection.name, help: count == 1 ? "1 document" : "\(count) documents",
          systemImage: DocumentSymbol.image(collection.symbol), hue: Hue(colorName: collection.color)
        ) {
          RowActions(
            canMoveUp: index > 0, canMoveDown: index < collections.count - 1, canDelete: !collection.locked,
            edit: { editing = .collection(collection) }, move: { moveCollection(collection, by: $0) },
            delete: { deleting = .collection(collection) })
        }
      }
      FormRow("Add a Collection", help: suggestions.isEmpty ? nil : "Or one of these", systemImage: "plus", hue: .gray) {
        Button("New…") {
          editing = .collection(VaultDocumentCollection(name: "", symbol: "doc", color: "blue", order: collections.count))
        }
        .buttonStyle(.kit).controlSize(.small)
      }
      if !suggestions.isEmpty {
        KitFlowLayout(spacing: 6, lineSpacing: 6) {
          ForEach(suggestions, id: \.name) { suggestion in
            Button(suggestion.name, systemImage: DocumentSymbol.image(suggestion.symbol)) { add(suggestion) }
              .buttonStyle(.kit).controlSize(.small)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 58)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
      }
    }
    FormCard("People", footer: "Whose a document is. Not the people you share with: a child can have a passport here without a device or keys.") {
      ForEach(Array(vault.holders.enumerated()), id: \.element.id) { index, person in
        let count = vault.documents.filter { $0.holder == person.id }.count
        FormRow(person.name, help: count == 1 ? "1 document" : "\(count) documents", systemImage: "person.fill", hue: Hue(colorName: person.color)) {
          RowActions(
            canMoveUp: index > 0, canMoveDown: index < vault.holders.count - 1, canDelete: true,
            edit: { editing = .holder(person) }, move: { moveHolder(person, by: $0) }, delete: { deleting = .holder(person) })
        }
      }
      FormRow("Add Person", help: vault.holders.isEmpty ? "You, your partner, your children" : nil, systemImage: "plus", hue: .gray) {
        Button("Add…") {
          let colors = ["purple", "teal", "pink", "orange", "indigo", "green"]
          editing = .holder(VaultHolder(name: "", color: colors[vault.holders.count % colors.count], order: vault.holders.count))
        }
        .buttonStyle(.kit).controlSize(.small)
      }
    }
    .kitSheet(item: $editing) { edit in GroupEditSheet(edit: edit) }
    .kitConfirmation(
      deleting.map { "Delete “\($0.name)”?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      message: deleting.map(deleteMessage) ?? "", systemImage: "trash", confirm: "Delete"
    ) {
      if let deleting { delete(deleting) }
      deleting = nil
    }
  }

  private func deleteMessage(_ edit: GroupEdit) -> String {
    switch edit {
    case .collection(let collection):
      let count = vault.documents.filter { $0.collection == collection.id }.count
      return count == 0 ? "It has no documents." : "Its \(count == 1 ? "document goes" : "\(count) documents go") to the Inbox, on all your devices."
    case .holder(let person):
      let count = vault.documents.filter { $0.holder == person.id }.count
      return count == 0 ? "No documents are theirs." : "\(count == 1 ? "Their document stays" : "Their \(count) documents stay"), as no one’s."
    }
  }

  private func add(_ suggestion: VaultDocumentCollection) {
    var collection = VaultDocumentCollection(name: suggestion.name, symbol: suggestion.symbol, color: suggestion.color)
    collection.order = (vault.documentCollections.map(\.order).max() ?? -1) + 1
    vault.save(collection)
  }

  private func moveCollection(_ collection: VaultDocumentCollection, by offset: Int) {
    var list = vault.documentCollections
    guard let index = list.firstIndex(where: { $0.id == collection.id }), list.indices.contains(index + offset) else { return }
    list.swapAt(index, index + offset)
    vault.perform { store in
      for (order, item) in list.enumerated() where item.order != order {
        try store.save(id: item.id, kind: VaultDocumentCollection.kind, changes: ["order": .init(order)])
      }
    }
  }

  private func moveHolder(_ person: VaultHolder, by offset: Int) {
    var list = vault.holders
    guard let index = list.firstIndex(where: { $0.id == person.id }), list.indices.contains(index + offset) else { return }
    list.swapAt(index, index + offset)
    vault.perform { store in
      for (order, item) in list.enumerated() where item.order != order {
        try store.save(id: item.id, kind: VaultHolder.kind, changes: ["order": .init(order)])
      }
    }
  }

  private func delete(_ edit: GroupEdit) {
    vault.perform { store in
      switch edit {
      case .collection(let collection):
        for document in vault.documents where document.collection == collection.id {
          try store.save(id: document.id, kind: VaultDocument.kind, changes: ["collection": .string("")])
        }
        try store.delete(id: collection.id)
      case .holder(let person):
        for document in vault.documents where document.holder == person.id {
          try store.save(id: document.id, kind: VaultDocument.kind, changes: ["holder": .string("")])
        }
        try store.delete(id: person.id)
      }
    }
  }
}

/// A collection or a person being edited or added.
enum GroupEdit: Identifiable, Hashable {
  case collection(VaultDocumentCollection)
  case holder(VaultHolder)

  var id: String {
    switch self {
    case .collection(let collection): collection.id
    case .holder(let person): person.id
    }
  }

  var name: String {
    switch self {
    case .collection(let collection): collection.name
    case .holder(let person): person.name
    }
  }
}

/// Edit…, and More with Move Up, Move Down and Delete.
private struct RowActions: View {
  var canMoveUp: Bool
  var canMoveDown: Bool
  var canDelete: Bool
  var edit: () -> Void
  var move: (Int) -> Void
  var delete: () -> Void
  @State private var showsMore = false

  var body: some View {
    HStack(spacing: 6) {
      Button("Edit…", action: edit).buttonStyle(.kit).controlSize(.small)
      Button("More", systemImage: "ellipsis") { showsMore = true }
        .buttonStyle(.kitIcon).controlSize(.small)
        .kitMenu(isPresented: $showsMore) {
          Button("Move Up", systemImage: "arrow.up") { move(-1) }.disabled(!canMoveUp)
          Button("Move Down", systemImage: "arrow.down") { move(1) }.disabled(!canMoveDown)
          if canDelete {
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
          }
        }
    }
  }
}

/// A collection's name, symbol and colour, or a person's name and colour.
private struct GroupEditSheet: View {
  let edit: GroupEdit
  @Environment(AppModel.self) private var app
  @Environment(\.kitDismiss) private var dismiss
  @State private var name = ""
  @State private var symbol = "doc"
  @State private var hue: Hue = .blue
  @State private var loaded = false

  private static let symbols = ["id", "passport", "work", "umbrella", "card", "house", "car", "receipt", "heart", "tag", "doc"]
  private static let hues: [Hue] = [.blue, .indigo, .purple, .pink, .red, .orange, .yellow, .green, .teal, .brown, .gray]

  private var isNew: Bool {
    switch edit {
    case .collection(let collection): app.vault.collection(id: collection.id) == nil
    case .holder(let person): app.vault.holder(id: person.id) == nil
    }
  }

  var body: some View {
    let isCollection = if case .collection = edit { true } else { false }
    KitSheet(
      title: isNew ? (isCollection ? "New Collection" : "Add Person") : "Edit “\(edit.name)”",
      meta: isCollection ? "Where documents are filed" : "Only a name and a colour; no contact details",
      systemImage: isCollection ? DocumentSymbol.image(symbol) : "person", width: 460
    ) {
      LabeledField("Name") {
        TextField(isCollection ? "Health" : "Name", text: $name).kitField()
      }
      if isCollection {
        LabeledField("Symbol") {
          KitFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(Self.symbols, id: \.self) { item in
              Toggle(isOn: Binding(get: { symbol == item }, set: { if $0 { symbol = item } })) {
                Image(systemName: DocumentSymbol.image(item)).frame(width: 18)
              }
              .toggleStyle(.kitChip)
              .accessibilityLabel(item)
            }
          }
        }
      }
      LabeledField("Colour") {
        KitHuePicker(selection: $hue, hues: Self.hues)
      }
      SheetFooterButtons(
        saveTitle: isNew ? "Add" : "Save", canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
        status: "Encrypted, synced to your \(app.devices.count) devices", onSave: save)
    }
    .onAppear {
      guard !loaded else { return }
      loaded = true
      switch edit {
      case .collection(let collection):
        name = collection.name
        symbol = collection.symbol
        hue = Hue(colorName: collection.color)
      case .holder(let person):
        name = person.name
        hue = Hue(colorName: person.color)
      }
    }
  }

  private func save() {
    let name = name.trimmingCharacters(in: .whitespaces)
    switch edit {
    case .collection(var collection):
      collection.name = name
      collection.symbol = symbol
      collection.color = hue.rawValue
      app.vault.save(collection)
    case .holder(var person):
      person.name = name
      person.color = hue.rawValue
      app.vault.save(person)
    }
    dismiss()
  }
}
