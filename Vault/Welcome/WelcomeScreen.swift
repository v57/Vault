import ComponentKit
import SwiftUI
import VaultKit

/// Board 13: the kit's welcome as the main screen while nothing is selected (on iPhone the first screen, until Open
/// Vault). A new device first waits for its keys (they arrive through iCloud Keychain, or through a recovery key or
/// an invite where there's no iCloud Keychain); once they're here it lists what the other v57 apps already saved,
/// since Vault opens the same store. The recovery key is mentioned once, under the first encrypt action.
struct WelcomeScreen: View {
  /// Closes the iPhone's first screen; on the Mac and iPad picking anything in the sidebar replaces the welcome.
  var onOpen: (() -> Void)?
  @Environment(AppModel.self) private var app
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if idiom == .phone {
      // iPhone board 05: the first screen, full height, until the keys are here and "Open Vault".
      VStack(spacing: 0) {
        welcome
        if !app.isWaitingForKeys {
          Button { onOpen?() } label: {
            Text("Open Vault").frame(maxWidth: .infinity)
          }
          .buttonStyle(.kitPrimary)
          .controlSize(.large)
          .padding(.horizontal, 20)
          .padding(.bottom, 12)
          .background(.kitPanel)
        }
      }
      .background(.kitPanel)
    } else {
      // Named by the kit's toolbar, so there's no system title bar (or iPad large title) over the welcome.
      welcome
        .kitPane(.content)
        .kitToolbar("Vault") {
          Text("Vault").kitFont(.headline)
        } tools: {
        }
    }
  }

  private var welcome: some View {
    let waiting = app.isWaitingForKeys
    return KitWelcome(
      appName: "Vault", version: "Passwords, encrypted folders and sync",
      emptyTitle: waiting ? "Waiting for Your Keys" : "Nothing Here Yet",
      emptyMessage: waiting
        ? "They arrive through iCloud Keychain from your other Apple devices. Your records open as soon as they do."
        : "What Shell, Database, Git, Code and Markdown save appears here."
    ) {
      if waiting {
        WelcomeAction("Recover with Key…", detail: "Type your 24 words or scan the recovery kit’s QR code", systemImage: "key") {
          open(.recoveryKey)
        }
        .disabled(!app.recovery.isAvailable)
        WelcomeAction("Join from Another Device…", detail: "Scan an invite on a device that has your keys", systemImage: "qrcode") {
          app.sheet = .scanInvite
        }
      } else {
        WelcomeAction("New Encrypted Folder…", detail: firstEncryptLine, systemImage: "lock.rectangle.stack") {
          app.sheet = .newItem(.folder)
        }
        WelcomeAction("Sync a Folder…", detail: "Through iCloud, S3, SFTP or SMB", systemImage: "arrow.triangle.2.circlepath") {
          app.sheet = .addRemote
        }
        if idiom != .phone {
          WelcomeAction("New Login", detail: "Passwords and one-time codes, filled by AutoFill", systemImage: "key.horizontal") {
            app.sheet = .newItem(.login)
          }
        }
      }
    } recents: {
      if !waiting {
        recent("SSH Hosts", "From Shell and Database", count: app.vault.hosts.count, date: "Today", item: .hosts)
        recent("Databases", "From Database", count: app.vault.databases.count, date: "Today", item: .databases)
        recent("Projects", "From Git, Code and Dev", count: app.vault.projects.count, date: "Today", item: .projects)
        recent("Notes", "From Markdown and Shell · \(app.notes.filter(\.encrypted).count) encrypted", count: app.notes.count, date: "Yesterday", item: .notes)
      }
    }
    .listTitle(waiting ? ("This \(ThisDevice.word)") : "Already in your vault")
    .emptyState(systemImage: "key", status: waiting ? .working : .idle)
  }

  private var firstEncryptLine: String {
    app.recovery.isOn
      ? "Only v57 apps can open it."
      : "Only v57 apps can open it. If your keys are lost, so are its files: create a recovery key"
  }

  /// Opens a screen: the selection on the Mac and iPad, and on iPhone past the first screen too.
  private func open(_ item: SidebarItem) {
    app.selection = item
    onOpen?()
  }

  @ViewBuilder
  private func recent(_ title: String, _ subtitle: String, count: Int, date: String, item: SidebarItem) -> some View {
    if count > 0 {
      RecentItem(title, subtitle: subtitle, date: date, status: "\(count)") { open(item) }
    }
  }
}

extension AppModel {
  /// A new device whose vault keys haven't arrived yet (`--waiting-for-keys` shows it in demo runs).
  var isWaitingForKeys: Bool {
    LaunchOptions.flag("--waiting-for-keys") || (vault.error?.contains("key") == true && itemCount == 0)
  }

  /// The user's name on member lists: "You" outside the demo (Vault keeps no account).
  var ownerName: String { isDemo ? "Aiko Tanaka" : "You" }
}
