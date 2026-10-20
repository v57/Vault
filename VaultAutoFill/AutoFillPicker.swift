import ComponentKit
import SwiftUI
import VaultKit

/// What the picker shows: the logins that fit the site first, then every login (searchable).
@MainActor
@Observable
final class AutoFillModel {
  var suggested: [VaultLogin] = []
  var all: [VaultLogin] = []
  var wantsCode = false
  var host: String?
  @ObservationIgnored var complete: ((VaultLogin) -> Void)?
  @ObservationIgnored var completeCode: ((String) -> Void)?
  @ObservationIgnored var cancel: (() -> Void)?

  /// Every login in the shared store, by title.
  static func logins() -> [VaultLogin] {
    ((try? VaultStore.shared?.records(VaultLogin.self)) ?? []).sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }

  static func login(id: String) -> VaultLogin? {
    try? VaultStore.shared?.record(VaultLogin.self, id: id)
  }

  func load(identifiers: [String], wantsCode: Bool) {
    self.wantsCode = wantsCode
    all = Self.logins().filter { !wantsCode || $0.hasOneTimeCode }
    suggested = VaultAutoFill.logins(for: identifiers, in: all)
    host = identifiers.lazy.compactMap(VaultAutoFill.host(of:)).first
  }

  func pick(_ login: VaultLogin) {
    if wantsCode {
      if let code = login.oneTimeCode?.code() { completeCode?(code) }
    } else {
      complete?(login)
    }
  }
}

/// The AutoFill sheet: the logins for this site, then the rest, each with its letter tile; a tap fills it in.
struct AutoFillPicker: View {
  @Bindable var model: AutoFillModel
  @State private var search = ""
  @State private var selection: String?

  var body: some View {
    let query = search.lowercased()
    let rest = model.all.filter { login in
      !model.suggested.contains(login)
        && (query.isEmpty || login.displayName.lowercased().contains(query) || login.username.lowercased().contains(query))
    }
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Tile(systemImage: model.wantsCode ? "clock" : "key.horizontal", size: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text(model.wantsCode ? "Fill a One-Time Code" : "Fill a Login").kitFont(.title3)
          Text(model.host.map { "for \($0)" } ?? "from Vault").kitFont(.caption)
        }
        Spacer()
        Button("Cancel") { model.cancel?() }.buttonStyle(.kit)
      }
      .padding(12)
      KitSearchField(text: $search, prompt: "Search logins").padding(.horizontal, 12)
      KitList(selection: $selection) {
        if !model.suggested.isEmpty {
          KitSection("For This Site", meta: "\(model.suggested.count) logins", systemImage: "star", hue: .yellow) {
            ForEach(model.suggested) { row($0) }
          }
        }
        KitSection(model.suggested.isEmpty ? "Logins" : "Other Logins", meta: "\(rest.count) logins", systemImage: "key.horizontal") {
          ForEach(rest) { row($0) }
        }
      }
      .onChange(of: selection) { _, id in
        if let id, let login = model.all.first(where: { $0.id == id }) { model.pick(login) }
      }
    }
    .frame(minWidth: 380, minHeight: 420)
    .background(.kitPanel)
  }

  private func row(_ login: VaultLogin) -> some View {
    SidebarRow(value: login.id, login.displayName, subtitle: [login.username, login.domain ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")) {
      Tile(letters: String(login.displayName.prefix(2)), hue: StableHue.pick(login.displayName), size: 24)
    } trailing: {
      if login.hasOneTimeCode { Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.kitTertiary) }
    }
  }
}
