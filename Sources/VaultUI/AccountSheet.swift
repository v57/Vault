import ComponentKit
import SwiftUI
import VaultKit

/// New Account, or editing one: its name, its tile's colour and, for an account, the Apple developer teams it holds
/// (the projects whose `DEVELOPMENT_TEAM` its keys sign). Present it with `.kitSheet`.
///
/// ```swift
/// .kitSheet(isPresented: $creating) { VaultAccountSheet(account: nil) { selection = $0.id } }
/// ```
public struct VaultAccountSheet: View {
  var account: VaultAccount?
  var done: (VaultAccount) -> Void
  @Environment(\.kitDismiss) private var dismiss
  @State private var name: String
  @State private var hue: Hue
  @State private var error: String?

  /// `account` nil makes a new one; `done` gets the account made or saved.
  public init(account: VaultAccount?, done: @escaping (VaultAccount) -> Void = { _ in }) {
    self.account = account
    self.done = done
    _name = State(initialValue: account?.name ?? "")
    _hue = State(initialValue: account?.hue ?? .orange)
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  public var body: some View {
    KitSheet(
      title: account == nil ? "New Account" : account!.name,
      meta: account == nil
        ? "A vault of its own for a client, an employer or a team: its projects, hosts, keys and settings stay apart from Personal's."
        : "Its tile in the account picker."
    ) {
      Avatar(name: trimmed.isEmpty ? "?" : trimmed, letters: trimmed.first.map { String($0).uppercased() } ?? "?",
             kind: .thing, hue: hue, size: 32)
    } content: {
      FormCard {
        FormRow(
          "Name", help: "Shown in every app's account picker", systemImage: "character.cursor.ibeam", hue: hue,
          error: error, field: TextField("Acme Studio", text: $name))
        FormRow("Colour", help: "The account's tile; the windows keep the app's accent", systemImage: "paintpalette",
                hue: hue) {
          VaultHuePicker(selection: $hue)
        }
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button(account == nil ? "Create" : "Save") { save() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(trimmed.isEmpty)
    }
  }

  private func save() {
    let vaults = Vaults.shared
    if var account {
      account.name = trimmed
      account.color = hue.rawValue
      vaults.save(account)
      done(account)
      dismiss()
      return
    }
    do {
      let account = try vaults.createAccount(name: trimmed, color: hue.rawValue)
      done(account)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// The account colours: a row of round swatches, the chosen one ringed.
struct VaultHuePicker: View {
  @Binding var selection: Hue
  static let hues: [Hue] = [.blue, .indigo, .purple, .pink, .red, .orange, .yellow, .green, .teal, .brown, .gray]

  var body: some View {
    HStack(spacing: 4) {
      ForEach(Self.hues, id: \.self) { hue in
        Button {
          selection = hue
        } label: {
          Circle()
            .fill(hue.fill)
            .frame(width: 14, height: 14)
            .padding(3)
            .overlay {
              Circle().strokeBorder(selection == hue ? AnyShapeStyle(hue.fill) : AnyShapeStyle(.clear), lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hue.rawValue.capitalized)
        .accessibilityAddTraits(selection == hue ? .isSelected : [])
      }
    }
  }
}
