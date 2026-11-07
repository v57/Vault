import Foundation
import Testing

@testable import VaultKit

/// Folder grants outside the sandbox (as the tests run): every folder opens, and the panel's start folder is the one
/// around an app's projects.
@MainActor
struct FolderGrantsTests {
  let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

  @Test func withoutTheSandboxEveryFolderOpens() {
    #expect(!AppSandbox.isOn)
    let defaults = UserDefaults(suiteName: "FolderGrantsTests")!
    defaults.removePersistentDomain(forName: "FolderGrantsTests")
    let grants = FolderGrants(defaults: defaults)
    let project = home.appendingPathComponent("Developer/v57/Markdown")
    #expect(grants.access(to: project) == project)
    // A pick around the project opens the project; another pick comes back as it is.
    #expect(grants.grant(home.appendingPathComponent("Developer/v57"), for: project).path == project.path)
    let elsewhere = home.appendingPathComponent("Documents")
    #expect(grants.grant(elsewhere, for: project) == elsewhere)
  }

  @Test func panelStartsAroundTheProjects() {
    let v57 = home.appendingPathComponent("Developer/v57")
    let markdown = v57.appendingPathComponent("Markdown")
    #expect(FolderGrants.folder(around: markdown, among: [v57.appendingPathComponent("Code")]).path == v57.path)
    // Alone, or with projects whose only common folder is the home folder: the project itself.
    #expect(FolderGrants.folder(around: markdown, among: []).path == markdown.path)
    #expect(FolderGrants.folder(around: markdown, among: [home.appendingPathComponent("Music/x")]).path == markdown.path)
    #expect(FolderGrants.folder(around: markdown, among: [URL(fileURLWithPath: "/tmp/x")]).path == markdown.path)
  }

  @Test func supportDirectoryIsTheAppsOwnWithoutTheSandbox() {
    #if os(macOS)
      #expect(AppSandbox.supportDirectory.deletingLastPathComponent() == URL.applicationSupportDirectory)
      #expect(AppSandbox.documentsDirectory.deletingLastPathComponent() == AppSandbox.supportDirectory)
    #endif
  }
}
