import ComponentKit
import Foundation
import SwiftUI
import VaultKit

/// One fallback address as the host editor edits it: a row of its own (`VaultHost.fallbacks`).
struct FallbackAddress: Identifiable, Hashable {
  let id = UUID()
  var address = ""
}

/// A host's fallback addresses as the host editor edits them.
enum FallbackAddresses {
  static func rows(_ addresses: [String]) -> [FallbackAddress] { addresses.map { FallbackAddress(address: $0) } }

  /// The addresses as typed, in order: trimmed, without blank rows, repeats and the host's own address.
  static func addresses(_ rows: [FallbackAddress], host: String) -> [String] {
    var seen: Set<String> = [host.trimmingCharacters(in: .whitespaces).lowercased()]
    return rows.map { $0.address.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }

  /// What's wrong with a row: a space inside the address, or one tried already (the host's address, a row above).
  static func issues(_ rows: [FallbackAddress], host: String) -> [UUID: String] {
    var issues: [UUID: String] = [:]
    var seen: Set<String> = [host.trimmingCharacters(in: .whitespaces).lowercased()]
    for row in rows {
      let value = row.address.trimmingCharacters(in: .whitespaces)
      guard !value.isEmpty else { continue }
      if value.contains(where: \.isWhitespace) {
        issues[row.id] = String(localized: "An address has no spaces")
      } else if !seen.insert(value.lowercased()).inserted {
        issues[row.id] = String(localized: "Tried already")
      }
    }
    return issues
  }
}

/// An address the vault tries on top of the ones the user typed, for a host that is one of the user's devices: the
/// name the Mac published (its Bonjour name) or its Hub Network address (`Vault.addresses(of:)`).
struct AutomaticAddress: Hashable {
  var address: String
  /// Which way it is, for the editor's read-only row.
  var source: String

  /// The ones for `host` as edited (its address and fallbacks as typed), from Personal's devices and Hubs.
  @MainActor static func list(for host: VaultHost, in vault: Vault) -> [AutomaticAddress] {
    let personal = vault.personalVault
    let typed = Set(([host.hostname] + host.fallbacks).map { $0.lowercased() })
    let automatic = personal.fallbackAddresses(of: host).filter { !typed.contains($0.lowercased()) }
    return automatic.map { address in
      let viaHub = personal.hubHosts.contains { $0.hostname.caseInsensitiveCompare(address) == .orderedSame }
      let source =
        viaHub
        ? String(localized: "Its Hub Network address, wherever the Hub reaches")
        : address.lowercased().hasSuffix(".local") ? String(localized: "Its Bonjour name, on the same network") : String(localized: "Another address it published")
      return AutomaticAddress(address: address, source: source)
    }
  }
}

/// The host editor's fallback addresses: a field per address the user adds (in the order they're tried) and Add
/// Address, then the ones tried for a device of the user's anyway, read-only.
struct FallbackAddressesField: View {
  @Binding var rows: [FallbackAddress]
  /// The host as edited.
  var host: VaultHost
  @Environment(AppModel.self) private var app
  /// The row just added, which takes the keyboard.
  @FocusState private var focused: UUID?

  var body: some View {
    let issues = FallbackAddresses.issues(rows, host: host.hostname)
    LabeledField("Fallback Addresses") {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(rows) { row in
          HStack(spacing: 6) {
            TextField("studio.local", text: address(of: row.id)).kitField(mono: true).focused($focused, equals: row.id)
            Button("Remove", systemImage: "minus.circle") {
              // The field gives up the keyboard first: ending its editing writes the text back to the row.
              if focused == row.id { focused = nil }
              withKitAnimation { rows.removeAll { $0.id == row.id } }
            }
              .buttonStyle(.kitIcon)
              .help("Remove this address")
          }
          if let issue = issues[row.id] {
            Text(issue).kitFont(.caption).foregroundStyle(Hue.red.text).padding(.leading, 4)
          }
        }
        HStack(spacing: 8) {
          Button("Add Address", systemImage: "plus") {
            let row = FallbackAddress()
            withKitAnimation { rows.append(row) }
            focused = row.id
          }
            .buttonStyle(.kit)
          Text("Tried in order when the address doesn't answer").kitFont(.caption)
        }
        ForEach(AutomaticAddress.list(for: host, in: app.vault), id: \.address) { address in
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(Hue.green.fill)
            Text(address.address).kitFont(.mono).lineLimit(1)
            Chip("Automatic", style: .quiet).controlSize(.small)
            Text(address.source).kitFont(.caption).lineLimit(1)
          }
          .padding(.leading, 4)
        }
      }
    }
  }

  /// A row's address by its id, not its index: a field that ends editing after its row was removed (the focused one,
  /// removed with its own button) writes to nothing instead of past the end of the rows.
  private func address(of id: UUID) -> Binding<String> {
    Binding(
      get: { rows.first { $0.id == id }?.address ?? "" },
      set: { value in
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].address = value
      })
  }
}
