import ComponentKit
import SwiftUI
import VaultKit

/// The folders an import skipped (`VaultProjectDiscovery.Result.skipped`: no Git repository in them, one beside them),
/// offered as projects so nothing in a dropped folder goes missing unseen. Each row says what is in the folder and
/// which v57 apps would open it (notes → Markdown, an Xcode project → Dev and Code); those that look like projects or
/// hold notes start ticked. Add puts the ticked ones in the vault's projects, in the groups the drop made
/// (`VaultStore.arrangeProjects` with the dropped `roots`).
///
/// ```swift
/// .kitSheet(isPresented: $offersFolders) {
///   VaultFolderSuggestionsSheet(skipped, roots: dropped, vault: vault, app: "Git")
/// }
/// ```
public struct VaultFolderSuggestionsSheet: View {
  let suggestions: [VaultProjectDiscovery.Skipped]
  let roots: [URL]
  let vault: Vault
  let app: String?
  let onAdd: ([URL]) -> Void
  @Environment(\.kitDismiss) private var dismiss
  @State private var picked: Set<URL>

  /// `app` names the app that skipped them, for the explanation; `onAdd` gets the folders added (after the vault
  /// has them).
  public init(
    _ suggestions: [VaultProjectDiscovery.Skipped], roots: [URL], vault: Vault = Vaults.shared.personal,
    app: String? = nil, onAdd: @escaping ([URL]) -> Void = { _ in }
  ) {
    self.suggestions = suggestions
    self.roots = roots
    self.vault = vault
    self.app = app
    self.onAdd = onAdd
    _picked = State(
      initialValue: Set(suggestions.filter { $0.looksLikeProject || $0.contents.contains(.notes) }.map(\.url)))
  }

  public var body: some View {
    KitSheet(
      title: suggestions.count == 1 ? "Add This Folder Too?" : "Add These Folders Too?",
      meta: meta, systemImage: "folder.badge.plus", hue: .blue
    ) {
      FormCard {
        ForEach(suggestions) { item in
          let apps = Self.apps(for: item.contents)
          FormRow(
            item.url.lastPathComponent, help: help(for: item), systemImage: "folder",
            hue: apps.isEmpty ? .gray : .blue
          ) {
            HStack(spacing: 6) {
              ForEach(apps, id: \.name) { app in Chip(app.name, hue: app.hue).controlSize(.small) }
              Toggle(item.url.lastPathComponent, isOn: binding(for: item.url))
                .labelsHidden()
                .toggleStyle(.kitCheckbox)
            }
          }
        }
      }
    } footer: {
      if suggestions.count > 1 {
        Button(picked.count == suggestions.count ? "Select None" : "Select All") {
          picked = picked.count == suggestions.count ? [] : Set(suggestions.map(\.url))
        }
        .buttonStyle(.kitPlain)
      }
      Spacer()
      Button("Not Now") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(picked.isEmpty || suggestions.count == 1 ? "Add" : "Add \(picked.count)") { add() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(picked.isEmpty)
    }
  }

  private var meta: String {
    let skipped = app.map { "\($0) skipped them" } ?? "The drop skipped them"
    return "They hold no Git repository. \(skipped); added, they join your projects for the apps that open them."
  }

  /// What is in it, and where when it isn't right inside a dropped folder: "Notes", "in Agentus · Notes".
  private func help(for item: VaultProjectDiscovery.Skipped) -> String {
    let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
    let root = roots.map(\.standardizedFileURL.path).filter { parent == $0 || parent.hasPrefix($0 + "/") }
      .max { $0.count < $1.count }
    // A dropped folder itself (it held no repository at all) says where it is.
    let place: String? =
      if let root { parent == root ? nil : "in " + parent.dropFirst(root.count + 1) } else {
        (parent as NSString).abbreviatingWithTildeInPath
      }
    return [place, Self.describe(item.contents)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private func add() {
    let urls = suggestions.map(\.url).filter(picked.contains)
    let roots = roots.map(\.standardizedFileURL.path)
    vault.perform { store in
      for url in urls { try store.addProject(path: url.standardizedFileURL.path) }
      try store.arrangeProjects(urls.map(\.standardizedFileURL.path), roots: roots)
    }
    onAdd(urls)
    dismiss()
  }

  private func binding(for url: URL) -> Binding<Bool> {
    Binding(
      get: { picked.contains(url) },
      set: { if $0 { picked.insert(url) } else { picked.remove(url) } })
  }

  /// The v57 apps that open a folder with these contents.
  static func apps(for contents: VaultProjectDiscovery.Contents) -> [(name: String, hue: Hue)] {
    var apps: [(name: String, hue: Hue)] = []
    if contents.contains(.notes) { apps.append(("Markdown", .blue)) }
    if contents.contains(.xcode) { apps.append(("Dev", .indigo)) }
    if !contents.isDisjoint(with: [.code, .xcode, .swiftPackage]) { apps.append(("Code", .purple)) }
    if contents.contains(.database) { apps.append(("Database", .teal)) }
    return apps
  }

  /// "Notes, Swift package".
  static func describe(_ contents: VaultProjectDiscovery.Contents) -> String {
    var words: [String] = []
    if contents.contains(.notes) { words.append("Notes") }
    if contents.contains(.xcode) { words.append("Xcode project") }
    if contents.contains(.swiftPackage) { words.append("Swift package") }
    if contents.contains(.code), contents.isDisjoint(with: [.xcode, .swiftPackage]) { words.append("Code") }
    if contents.contains(.database) { words.append("Databases") }
    return words.joined(separator: ", ")
  }
}
