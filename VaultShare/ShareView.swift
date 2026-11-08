import ComponentKit
import SwiftUI
import VaultKit

/// What the share extension shows: the files coming in, and whether they can be saved.
@MainActor @Observable
final class ShareModel {
  var files: [SharedFile] = []
  var isLoading = true
  var isSaving = false
  /// Why the files can't be added: none could be read, or this device has no vault yet.
  var problem: String?
  var add: () -> Void = {}
  var cancel: () -> Void = {}
}

/// Share → Vault (from Mail, Safari, Files, Photos, Finder): the files land in the Inbox, encrypted on this device;
/// Vault reads their pages the next time it opens, on this device. A share sheet, not a form: nothing to fill in.
struct ShareView: View {
  @Bindable var model: ShareModel

  var body: some View {
    let pages = model.files.reduce(0) { $0 + $1.pageCount }
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Tile(systemImage: "doc.viewfinder", size: 34)
        VStack(alignment: .leading, spacing: 1) {
          Text("Add to Vault").kitFont(.title3)
          Text(model.isLoading ? "Reading what you shared…" : "\(model.files.count == 1 ? String(localized: "1 file") : String(localized: "\(model.files.count) files")) · \(pages == 1 ? String(localized: "1 page") : String(localized: "\(pages) pages")) · to the Inbox")
            .kitFont(.caption)
        }
        Spacer()
      }
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 10) {
          ForEach(Array(model.files.enumerated()), id: \.offset) { _, file in
            VStack(spacing: 6) {
              KitPagePreview(
                data: file.thumbnail, aspectRatio: file.width > 0 && file.height > 0 ? CGFloat(file.width) / CGFloat(file.height) : 0.707,
                pages: file.pageCount)
                .frame(height: 110)
              Text(file.name).kitFont(.caption).lineLimit(1).frame(maxWidth: 120)
            }
          }
          if model.isLoading {
            ProgressView().controlSize(.small).frame(width: 80, height: 110)
          }
        }
        .padding(.vertical, 2)
      }
      .scrollIndicators(.hidden)
      Text("Encrypted on this device before it’s saved, then synced like the rest of your vault. Vault reads the pages the next time it opens.")
        .kitFont(.caption)
        .fixedSize(horizontal: false, vertical: true)
      if let problem = model.problem {
        Text(problem).kitFont(.caption).foregroundStyle(Hue.orange.text)
      }
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel") { model.cancel() }.buttonStyle(.kit).keyboardShortcut(.cancelAction)
        Button(model.isSaving ? "Adding…" : "Add to Inbox") { model.add() }
          .buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
          .disabled(model.isLoading || model.isSaving || model.files.isEmpty || model.problem != nil)
      }
    }
    .padding(18)
    .frame(minWidth: 380, maxWidth: 520)
    .background(.kitPanel)
  }
}
