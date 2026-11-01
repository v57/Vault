import ComponentKit
import SwiftUI
import VaultKit

/// What a drop found that the vault doesn't have yet (`VaultImportOffer`), offered so nothing in a dropped folder
/// goes missing unseen: repositories and folders as projects, SQLite and DuckDB files as connections. Each row says
/// which v57 apps open it (notes → Markdown, an Xcode project → Dev and Code, a database → Database and Shell);
/// repositories, databases and folders that look like projects or hold notes start ticked. Add saves the ticked ones
/// in the vault: projects in the groups the drop made (`VaultStore.arrangeProjects` with the dropped folders),
/// databases as connections (`VaultStore.addDatabaseFile`).
///
/// ```swift
/// .kitSheet(item: $offer) { offer in VaultImportSheet(offer, vault: vault, app: "Git") }
/// ```
public struct VaultImportSheet: View {
  let offer: VaultImportOffer
  let vault: Vault
  let app: String?
  let onAdd: ([URL]) -> Void
  @Environment(\.kitDismiss) private var dismiss
  @State private var picked: Set<URL>

  /// `app` names the app showing it, for the explanation; `onAdd` gets what was added (after the vault has it).
  public init(
    _ offer: VaultImportOffer, vault: Vault = Vaults.shared.personal, app: String? = nil,
    onAdd: @escaping ([URL]) -> Void = { _ in }
  ) {
    self.offer = offer
    self.vault = vault
    self.app = app
    self.onAdd = onAdd
    let folders = offer.folders.filter { $0.looksLikeProject || $0.contents.contains(.notes) }.map(\.url)
    _picked = State(initialValue: Set(offer.repositories + folders + offer.databases.map(\.url)))
  }

  private var all: [URL] { offer.repositories + offer.folders.map(\.url) + offer.databases.map(\.url) }

  public var body: some View {
    KitSheet(title: title, meta: meta, systemImage: "square.and.arrow.down", hue: .blue) {
      if !offer.repositories.isEmpty || !offer.folders.isEmpty {
        FormCard("Projects") {
          ForEach(offer.repositories, id: \.self) { url in
            row(url, help: help(place: url, kinds: "Git repository"), systemImage: "arrow.triangle.branch",
                apps: [("Git", .orange), ("Code", .purple)])
          }
          ForEach(offer.folders) { item in
            let apps = Self.apps(for: item.contents)
            row(item.url, help: help(place: item.url, kinds: Self.describe(item.contents)), systemImage: "folder",
                apps: apps)
          }
        }
      }
      if !offer.databases.isEmpty {
        FormCard("Databases") {
          ForEach(offer.databases) { file in
            row(file.url, help: help(place: file.url, kinds: file.engine == VaultDatabase.Engine.duckdb ? "DuckDB" : "SQLite"),
                systemImage: "cylinder", apps: [("Database", .teal), ("Shell", .gray)])
          }
        }
      }
    } footer: {
      if all.count > 1 {
        Button(picked.count == all.count ? "Select None" : "Select All") {
          picked = picked.count == all.count ? [] : Set(all)
        }
        .buttonStyle(.kitPlain)
      }
      Spacer()
      Button("Not Now") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(picked.isEmpty || all.count == 1 ? "Add" : "Add \(picked.count)") { add() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(picked.isEmpty)
    }
  }

  private func row(_ url: URL, help: String, systemImage: String, apps: [(name: String, hue: Hue)]) -> some View {
    FormRow(url.lastPathComponent, help: help, systemImage: systemImage, hue: apps.isEmpty ? .gray : .blue) {
      HStack(spacing: 6) {
        ForEach(apps, id: \.name) { app in Chip(app.name, hue: app.hue).controlSize(.small) }
        Toggle(url.lastPathComponent, isOn: binding(for: url))
          .labelsHidden()
          .toggleStyle(.kitCheckbox)
      }
    }
  }

  private var title: String {
    let projects = offer.repositories.count + offer.folders.count
    let databases = offer.databases.count
    if databases == 0 {
      if offer.repositories.isEmpty { return projects == 1 ? "Add This Folder Too?" : "Add These Folders Too?" }
      return projects == 1 ? "Add This Project?" : "Add These Projects?"
    }
    if projects == 0 { return databases == 1 ? "Add This Database?" : "Add These Databases?" }
    return "Add What Was Found?"
  }

  private var meta: String {
    let added = "Added, they join your projects and connections for the apps that open them."
    if offer.databases.isEmpty, offer.repositories.isEmpty {
      return "They hold no Git repository, so \(app ?? "the drop") skipped them. " + added
    }
    let names = offer.roots.map(\.lastPathComponent).formatted()
    return "Found in \(names). " + added
  }

  /// What it is, and where when it isn't right inside a dropped folder: "Notes", "in Agentus · Notes".
  private func help(place url: URL, kinds: String) -> String {
    let parent = url.deletingLastPathComponent().standardizedFileURL.path
    let root = offer.roots.map(\.standardizedFileURL.path).filter { parent == $0 || parent.hasPrefix($0 + "/") }
      .max { $0.count < $1.count }
    // A dropped folder or file itself says where it is.
    let place: String? =
      if let root { parent == root ? nil : "in " + parent.dropFirst(root.count + 1) } else {
        (parent as NSString).abbreviatingWithTildeInPath
      }
    return [place, kinds].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private func add() {
    let projects = (offer.repositories + offer.folders.map(\.url)).filter(picked.contains)
    let databases = offer.databases.filter { picked.contains($0.url) }
    let roots = offer.roots.map(\.standardizedFileURL.path)
    vault.perform { store in
      let paths = projects.map(\.standardizedFileURL.path)
      for path in paths { try store.addProject(path: path) }
      try store.arrangeProjects(paths, roots: roots)
      for database in databases { try store.addDatabaseFile(database) }
    }
    onAdd(projects + databases.map(\.url))
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
