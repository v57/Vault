import ComponentKit
import SwiftUI
import VaultKit

/// Settings ▸ Accounts, the same in every app: a card per account (Personal first) with its Apple developer teams,
/// and New Account…, Edit… and Delete…. Put it in a `SettingsPane`.
///
/// ```swift
/// SettingsPane("Accounts", systemImage: "person.2", hue: .indigo, section: "v57") { VaultAccountsSettings() }
/// ```
public struct VaultAccountsSettings: View {
  @State private var vaults = Vaults.shared
  @State private var creating = false
  @State private var editing: VaultAccount?
  @State private var deleting: VaultAccount?
  @State private var addingTeamTo: VaultAccount?
  /// The accounts' vaults, opened outside the body (opening one writes `Vaults` state).
  @State private var opened: [String: Vault] = [:]

  public init() {}

  public var body: some View {
    ForEach(vaults.allAccounts) { account in
      FormCard(
        account.isPersonal ? "Personal" : account.name,
        footer: account.isPersonal
          ? "Always here: the vault every app used before accounts. Each window shows one account; ⌃⌘1…⌃⌘9 switch."
          : nil
      ) {
        accountRow(account)
        if let vault = opened[account.id] {
          ForEach(vault.appleTeams) { team in
            FormRow(team.name.isEmpty ? team.teamID : team.name, help: "Apple team \(team.teamID)",
                    systemImage: "apple.logo", hue: .gray) {
              Button("Remove", role: .destructive) { vault.delete(team) }.buttonStyle(.kit)
            }
          }
        }
        FormRow("Apple Teams", help: "Projects with one of these DEVELOPMENT_TEAMs sign with this account's keys",
                systemImage: "person.badge.key", hue: .gray) {
          Button("Add…") { addingTeamTo = account }.buttonStyle(.kit)
        }
      }
    }
    HStack {
      Spacer()
      Button("New Account…", systemImage: "plus") { creating = true }.buttonStyle(.kit)
    }
    if let error = vaults.error {
      Text(error).font(.callout).foregroundStyle(Hue.red.text)
    }
    Color.clear
      .frame(height: 0)
      .onChange(of: vaults.allAccounts, initial: true) {
        opened = Dictionary(uniqueKeysWithValues: vaults.allAccounts.compactMap { account in
          vaults.vault(for: account).map { (account.id, $0) }
        })
      }
      .kitSheet(isPresented: $creating) { VaultAccountSheet(account: nil) }
      .kitSheet(item: $editing) { VaultAccountSheet(account: $0) }
      .kitSheet(item: $addingTeamTo) { account in
        VaultAppleTeamSheet(vault: opened[account.id])
      }
      .kitConfirmation(
        "Delete \(deleting?.name ?? "")?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
        message: "Its projects, hosts, keys and settings are deleted on every device. Personal keeps everything.",
        systemImage: "trash", confirm: "Delete"
      ) {
        guard let account = deleting else { return }
        Task {
          do { try await vaults.delete(account) } catch { vaults.error = error.localizedDescription }
        }
      }
  }

  private func accountRow(_ account: VaultAccount) -> some View {
    let vault = opened[account.id]
    let projects = vault?.projects.count ?? 0
    let hosts = vault?.hosts.count ?? 0
    return FormRow(
      account.name, help: "\(projects) project\(projects == 1 ? "" : "s") · \(hosts) host\(hosts == 1 ? "" : "s")",
      systemImage: account.isPersonal ? "person.crop.circle" : "building.2", hue: account.hue
    ) {
      if !account.isPersonal {
        HStack(spacing: 6) {
          Button("Edit…") { editing = account }.buttonStyle(.kit)
          Button("Delete…", role: .destructive) { deleting = account }.buttonStyle(.kit)
        }
      }
    }
  }
}

/// Adds an Apple developer team to an account: its ten-character id and a name.
struct VaultAppleTeamSheet: View {
  var vault: Vault?
  @Environment(\.kitDismiss) private var dismiss
  @State private var teamID = ""
  @State private var name = ""

  private var id: String { teamID.trimmingCharacters(in: .whitespaces).uppercased() }
  private var isValid: Bool { id.count == 10 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }

  var body: some View {
    KitSheet(
      title: "Add Apple Team", meta: "The DEVELOPMENT_TEAM of the projects this account signs and uploads.",
      systemImage: "apple.logo", hue: .gray
    ) {
      FormCard {
        FormRow("Team ID", help: "Ten letters and digits, in the developer account's Membership", systemImage: "number",
                error: !teamID.isEmpty && !isValid ? "Not a team id" : nil, field: TextField("ABCDE12345", text: $teamID))
        FormRow("Name", help: "As Apple shows it", systemImage: "character.cursor.ibeam",
                field: TextField("Acme Studio Ltd", text: $name))
      }
    } footer: {
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Add") {
        vault?.save(VaultAppleTeam(teamID: id, name: name.trimmingCharacters(in: .whitespaces)))
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(!isValid || vault == nil)
    }
  }
}
