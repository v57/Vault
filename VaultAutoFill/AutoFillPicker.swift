import ComponentKit
import SwiftUI
import VaultKit

/// What the picker shows: the site's passkeys and the logins that fit it first, then every login (searchable); or,
/// when a site saves a passkey, what it's for.
@MainActor
@Observable
final class AutoFillModel {
  var suggested: [VaultLogin] = []
  var all: [VaultLogin] = []
  /// The site's passkeys, when it asked for one.
  var passkeys: [VaultPasskey] = []
  var wantsCode = false
  var host: String?
  /// A site saving a new passkey: its relying party and the account.
  var registration: (relyingParty: String, userName: String)?
  /// The passkey being signed in with, while the system checks it's the device's owner.
  var signingIn: VaultPasskey?
  @ObservationIgnored var complete: ((VaultLogin) -> Void)?
  @ObservationIgnored var completeCode: ((String) -> Void)?
  @ObservationIgnored var completePasskey: ((VaultPasskey) -> Void)?
  @ObservationIgnored var confirmRegistration: (() -> Void)?
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

  func pick(passkey id: String) {
    if let passkey = passkeys.first(where: { $0.id == id }) {
      signingIn = passkey
      completePasskey?(passkey)
    }
  }

  func pick(_ login: VaultLogin) {
    if wantsCode {
      if let code = login.oneTimeCode?.code() { completeCode?(code) }
    } else {
      complete?(login)
    }
  }
}

/// The AutoFill sheet (iPhone board 05): the site's passkeys and logins first, with the one-time code where there is
/// one, then every other login (searchable). A tap fills it in; the system asks for Face ID before the sheet opens,
/// and Vault asks again before a passkey signs in. A site saving a passkey gets the Save Passkey sheet instead.
struct AutoFillPicker: View {
  @Bindable var model: AutoFillModel
  @State private var search = ""
  @State private var selection: String?

  var body: some View {
    if let registration = model.registration {
      SavePasskeySheet(relyingParty: registration.relyingParty, userName: registration.userName, model: model)
    } else if let passkey = model.signingIn {
      VStack(spacing: 14) {
        Spacer()
        Tile(systemImage: "person.badge.key", size: 44)
        Text("Signing in to \(passkey.relyingParty)").kitFont(.title3)
        Text(passkey.userName).kitFont(.caption)
        Spacer()
        Button("Cancel") { model.cancel?() }.buttonStyle(.kit)
      }
      .padding(KitMetrics.gutter)
      .frame(minWidth: 380, minHeight: 300)
      .background(.kitPanel)
    } else {
      list
    }
  }

  @ViewBuilder
  private var list: some View {
    let query = search.lowercased()
    let rest = model.all.filter { login in
      !model.suggested.contains(login)
        && (query.isEmpty || login.displayName.lowercased().contains(query) || login.username.lowercased().contains(query))
    }
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Tile(systemImage: "key.horizontal", size: 34)
        VStack(alignment: .leading, spacing: 1) {
          Text("Vault").kitFont(.title3)
          Text(model.host.map { model.wantsCode ? "One-time code for \($0)" : model.passkeys.isEmpty ? "AutoFill for \($0)" : "Sign in to \($0)" } ?? "AutoFill").kitFont(.caption)
        }
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .padding(.bottom, 8)
      KitSearchField(text: $search, prompt: "Search logins").padding(.horizontal, 12)
      KitList(selection: $selection) {
        if !model.passkeys.isEmpty {
          KitSection("Passkeys", meta: "\(model.passkeys.count) for \(model.passkeys[0].relyingParty)", systemImage: "person.badge.key") {
            ForEach(model.passkeys) { passkey in
              SidebarRow(value: "passkey:" + passkey.id, passkey.userName, subtitle: "Passkey · \(passkey.relyingParty)") {
                Tile(systemImage: "person.badge.key", hue: StableHue.pick(passkey.relyingParty), size: 24)
              } trailing: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.kitTertiary)
              }
            }
          }
        }
        if let host = model.host, !model.suggested.isEmpty {
          KitSection(
            host, meta: ["\(model.suggested.count) login\(model.suggested.count == 1 ? "" : "s")", model.suggested.contains(where: \.hasOneTimeCode) ? "with a code" : ""],
            systemImage: "globe"
          ) {
            ForEach(model.suggested) { login in
              row(login)
              if login.hasOneTimeCode, let code = login.oneTimeCode {
                InspectorRow("Code") {
                  KitOneTimeCode(period: TimeInterval(code.period), showsSeconds: false) { code.code(at: $0) }
                }
              }
            }
          }
        }
        KitSection(model.suggested.isEmpty ? "Logins" : "Other logins", meta: "\(rest.count) logins", systemImage: "key.horizontal") {
          ForEach(rest) { row($0) }
        }
      }
      .onChange(of: selection) { _, id in
        if let id, id.hasPrefix("passkey:") {
          model.pick(passkey: String(id.dropFirst(8)))
        } else if let id, let login = model.all.first(where: { $0.id == id }) {
          model.pick(login)
        }
      }
      HStack(spacing: 10) {
        Tile(systemImage: "faceid", hue: .gray, size: 26)
        Text("Face ID first, by the system").kitFont(.caption)
        Spacer()
        Button("Cancel") { model.cancel?() }.buttonStyle(.kit)
      }
      .padding(8)
      .kitSurface(.card)
      .padding(KitMetrics.gutter)
    }
    .frame(minWidth: 380, minHeight: 420)
    .background(.kitPanel)
  }

  private func row(_ login: VaultLogin) -> some View {
    SidebarRow(value: login.id, login.displayName, subtitle: [login.username, login.domain ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")) {
      Tile(letters: String(login.displayName.prefix(2)), hue: StableHue.pick(login.displayName), size: 24)
    } trailing: {
      Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.kitTertiary)
    }
  }
}

/// A site saving a new passkey in Vault: the site and account, and Save (Touch ID or Face ID next).
struct SavePasskeySheet: View {
  let relyingParty: String
  let userName: String
  let model: AutoFillModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Tile(systemImage: "person.badge.key", size: 34)
        VStack(alignment: .leading, spacing: 1) {
          Text("Save a Passkey").kitFont(.title3)
          Text("in Vault, synced through iCloud Keychain").kitFont(.caption)
        }
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .padding(.bottom, 8)
      KitSection("Passkey", meta: "signs in without a password", systemImage: "person.badge.key") {
        InspectorRow("Website", value: relyingParty, copyable: false)
        InspectorRow("Account", value: userName, copyable: false)
      }
      .padding(.horizontal, KitMetrics.gutter)
      Spacer()
      HStack(spacing: 10) {
        Tile(systemImage: "faceid", hue: .gray, size: 26)
        Text("Touch ID or Face ID next").kitFont(.caption)
        Spacer()
        Button("Cancel") { model.cancel?() }.buttonStyle(.kit)
        Button("Save") { model.confirmRegistration?() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
      }
      .padding(8)
      .kitSurface(.card)
      .padding(KitMetrics.gutter)
    }
    .frame(minWidth: 380, minHeight: 300)
    .background(.kitPanel)
  }
}
