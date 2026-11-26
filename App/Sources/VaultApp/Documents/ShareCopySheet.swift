import ComponentKit
import PlatformScan
import SwiftUI
import VaultKit

/// Board 04: Share a Copy. A PDF of the pages picked, with what it's for across every page and the numbers left out,
/// both drawn into the pictures, and a note under Copies Shared. A sent copy can't be taken back, and the sheet says so.
struct ShareCopySheet: View {
  let documentID: String
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.kitDismiss) private var dismiss
  @State private var purpose = ""
  @State private var watermark = true
  @State private var hidden: Set<String> = []
  @State private var chosen: Set<String> = []
  @State private var pages: [LoadedPage] = []
  @State private var lines: [String: [PageTextLine]] = [:]
  @State private var preview: String?
  @State private var making = false
  @State private var made: URL?
  @State private var error: String?

  private var document: VaultDocument? { app.vault.documents.first { $0.id == documentID } }

  var body: some View {
    let vault = app.vault
    if let document {
      let kind = vault.documentKinds[document.kind]
      let hideable = hideableFields(document, kind: kind)
      let current = pages.first { $0.id == preview } ?? pages.first { chosen.contains($0.id) } ?? pages.first
      KitSheet(
        title: "Share a Copy of “\(document.displayName(kinds: vault.documentKinds))”",
        meta: "A PDF with a watermark; the parts you hide are taken out of the pictures, not covered.",
        systemImage: "square.and.arrow.up", width: 820
      ) {
        FieldRow {
          VStack(spacing: 10) {
            ZStack {
              RoundedRectangle(cornerRadius: KitMetrics.radiusCard, style: .continuous).fill(.kitFillSoft)
              if let current {
                KitMarkedPage(
                  imageData: current.image, aspectRatio: current.aspectRatio, hidden: rects(on: current, document: document),
                  watermark: watermark ? watermarkText : nil
                )
                .padding(18)
              } else {
                ProgressView().controlSize(.small)
              }
            }
            .frame(height: 320)
            KitPageStrip(
              pages: pages.map { KitPage(id: $0.id, label: chosen.contains($0.id) ? $0.label : String(localized: "Left out"), imageData: $0.image, aspectRatio: $0.aspectRatio) },
              selection: Binding(get: { preview ?? pages.first?.id }, set: { preview = $0 }), height: 48)
          }
          VStack(alignment: .leading, spacing: 12) {
            LabeledField("For") {
              TextField("Wohnbau GmbH, rental application", text: $purpose).kitField()
            }
            FormCard {
              FormRow("Watermark", help: watermark ? "\(watermarkText)" : "No watermark", systemImage: "seal", hue: .red) {
                Toggle("Watermark", isOn: $watermark).toggleStyle(.kitSwitch).labelsHidden()
              }
              ForEach(hideable, id: \.key) { item in
                FormRow("Hide \(item.label.lowercased())", help: item.help, systemImage: "eye.slash", hue: .gray) {
                  Toggle(item.label, isOn: Binding(get: { hidden.contains(item.key) }, set: { if $0 { hidden.insert(item.key) } else { hidden.remove(item.key) } }))
                    .toggleStyle(.kitSwitch).labelsHidden()
                }
              }
              if let page = current {
                FormRow("Include this page", help: "\(page.label)", systemImage: "doc", hue: .blue) {
                  Toggle("Include", isOn: Binding(get: { chosen.contains(page.id) }, set: { if $0 { chosen.insert(page.id) } else { chosen.remove(page.id) } }))
                    .toggleStyle(.kitSwitch).labelsHidden()
                }
              }
            }
            if let missing = missingHidden(document, hideable: hideable) {
              Text(missing).kitFont(.caption).foregroundStyle(Hue.orange.text)
            }
            Text("Once it’s sent, a copy can’t be taken back. Vault keeps a note of who got which copy.")
              .kitFont(.caption)
          }
          .frame(maxWidth: idiom == .phone ? .infinity : 320)
        }
        if let error { Text(error).kitFont(.caption).foregroundStyle(Hue.red.text) }
        HStack(spacing: 8) {
          SheetStatus("\(chosen.count) of \(pages.count.pagesLabel) · PDF", systemImage: "doc.richtext", hue: .blue)
          Spacer()
          Button("Cancel") { dismiss() }.buttonStyle(.kit).keyboardShortcut(.cancelAction)
          if let made {
            ShareLink(item: made) { Label("Share…", systemImage: "square.and.arrow.up") }
              .buttonStyle(.kitPrimary)
          } else {
            Button(idiom == .mac ? "Save PDF…" : "Make PDF") { make(document) }
              .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
              .disabled(chosen.isEmpty || making || pages.isEmpty)
          }
        }
        .padding(6)
        .kitSurface(.card)
      }
      .task { await load(document, kind: kind, hideable: hideable) }
    }
  }

  private var watermarkText: String {
    let day = Date.now.formatted(.dateTime.day().month(.abbreviated).year())
    let who = purpose.trimmingCharacters(in: .whitespaces)
    return who.isEmpty ? String(localized: "Copy · \(day)") : String(localized: "For \(who) only · \(day)")
  }

  private struct Hideable {
    var key: String
    var label: String
    var help: LocalizedStringKey
  }

  /// The secret fields set on the document, and a passport's or ID's machine-readable zone.
  private func hideableFields(_ document: VaultDocument, kind: DocumentKind) -> [Hideable] {
    var items = kind.fields.filter { $0.format == .secret && document.secrets.contains($0.key) }
      .map { Hideable(key: $0.key, label: $0.label, help: "Blacked out wherever it’s printed") }
    if kind.collection == DocumentCollectionID.identity {
      items.append(Hideable(key: "mrz", label: String(localized: "Machine-readable zone"), help: "The two or three lines of <<< at the bottom"))
    }
    return items
  }

  private func load(_ document: VaultDocument, kind: DocumentKind, hideable: [Hideable]) async {
    guard let store = app.vault.store, pages.isEmpty else { return }
    let files = (try? store.files(of: document)) ?? []
    pages = await Task.detached(priority: .userInitiated) { DocumentPages.load(files, kind: kind) }.value
    chosen = Set(pages.prefix(kind.sides.isEmpty ? pages.count : 1).map(\.id))
    hidden = Set(hideable.map(\.key))
    for page in pages {
      lines[page.id] = (try? await PageScanner.lines(in: page.image)) ?? []
    }
  }

  /// Where the hidden parts are on a page: lines with a hidden number in them, and the zone's lines.
  private func rects(on page: LoadedPage, document: VaultDocument) -> [CGRect] {
    guard let read = lines[page.id] else { return [] }
    var boxes: [PageRect] = []
    for key in hidden where key != "mrz" {
      guard let value = document.secret(key).map(Self.squeezed), value.count >= 4 else { continue }
      boxes += read.filter { Self.squeezed($0.text).contains(value) }.map(\.box)
    }
    if hidden.contains("mrz") {
      boxes += read.filter(\.looksLikeZone).map(\.box)
    }
    return boxes.map { CGRect(x: $0.x - 0.006, y: $0.y - 0.006, width: $0.width + 0.012, height: $0.height + 0.012) }
  }

  /// Upper case without spaces, so "TR 102 9384" matches "TR1029384".
  private static func squeezed(_ text: String) -> String {
    text.uppercased().filter { !$0.isWhitespace }
  }

  /// Says so when a field to hide wasn't found on any chosen page.
  private func missingHidden(_ document: VaultDocument, hideable: [Hideable]) -> String? {
    let read = chosen.compactMap { lines[$0] }
    guard read.count == chosen.count, !chosen.isEmpty else { return nil }
    let missing = hideable.filter { item in
      guard hidden.contains(item.key), item.key != "mrz", let value = document.secret(item.key).map(Self.squeezed) else { return false }
      return !read.joined().contains { Self.squeezed($0.text).contains(value) }
    }
    guard !missing.isEmpty else { return nil }
    return String(localized: "\(missing.map(\.label).joined(separator: " and ")) wasn’t found on the pages, so nothing is blacked out for it. Check the preview.")
  }

  private func make(_ document: VaultDocument) {
    making = true
    error = nil
    let chosenPages = pages.filter { chosen.contains($0.id) }
    let copyPages = chosenPages.map { PageCopy.Page(image: $0.image, hidden: rects(on: $0, document: document).map { PageRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }) }
    let name = document.displayName(kinds: app.vault.documentKinds)
    let mark = watermark ? watermarkText : nil
    Task {
      do {
        let pdf = try await Task.detached(priority: .userInitiated) { try PageCopy.pdf(copyPages, watermark: mark, title: name) }.value
        #if os(macOS)
          guard let url = await KitDesktop.chooseSaveLocation(title: String(localized: "Save a Copy"), name: String(localized: "\(name) – copy") + ".pdf") else {
            making = false
            return
          }
          try pdf.write(to: url, options: .atomic)
          note(document, pages: chosenPages.count)
          dismiss()
        #else
          let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(localized: "\(name) – copy") + ".pdf")
          try pdf.write(to: url, options: [.atomic, .completeFileProtection])
          made = url
          note(document, pages: chosenPages.count)
        #endif
      } catch {
        self.error = error.localizedDescription
      }
      making = false
    }
  }

  private func note(_ document: VaultDocument, pages: Int) {
    let labels = hideableFields(document, kind: app.vault.documentKinds[document.kind])
      .filter { hidden.contains($0.key) }.map { $0.key == "mrz" ? "MRZ" : $0.label.lowercased() }
    let copy = VaultDocument.SharedCopy(
      purpose: purpose.trimmingCharacters(in: .whitespaces), pages: pages, hidden: labels, watermark: watermark)
    app.vault.perform { try $0.noteSharedCopy(copy, document: document.id) }
  }
}
