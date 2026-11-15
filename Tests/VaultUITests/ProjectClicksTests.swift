import SwiftUI
import Testing

@testable import VaultUI

/// `ProjectClicks`: ⌘- and ⇧-clicks pick several projects in the Projects section, as in Finder.
struct ProjectClicksTests {
  let order = ["code", "shell", "swiftui", "vault", "database", "markdown", "git"]

  @Test func aPlainClickPicksTheProjectAloneAndShowsIt() {
    let click = ProjectClicks(picked: ["code", "vault"], anchor: "vault", shown: "code", order: order)
      .click("git", modifiers: [])
    #expect(click.picked == ["git"])
    #expect(click.anchor == "git")
    #expect(click.shows)
  }

  @Test func commandAddsAndTakesOutWithoutShowing() {
    var clicks = ProjectClicks(picked: [], anchor: nil, shown: "code", order: order)
    let added = clicks.click("vault", modifiers: .command)
    #expect(added.picked == ["code", "vault"])
    #expect(!added.shows)
    clicks.picked = added.picked
    #expect(clicks.click("code", modifiers: .command).picked == ["vault"])
    // The last one stays.
    clicks.picked = ["vault"]
    #expect(clicks.click("vault", modifiers: .command).picked == ["vault"])
  }

  @Test func shiftPicksTheRangeFromTheLastClick() {
    let clicks = ProjectClicks(picked: ["code", "vault"], anchor: "vault", shown: "code", order: order)
    let range = clicks.click("markdown", modifiers: .shift)
    #expect(range.picked == ["vault", "database", "markdown"])
    #expect(range.anchor == "vault")
    #expect(!range.shows)
    #expect(clicks.click("shell", modifiers: .shift).picked == ["shell", "swiftui", "vault"])
    #expect(clicks.click("git", modifiers: [.command, .shift]).picked == ["code", "vault", "database", "markdown", "git"])
  }

  /// Before any click the range starts at the project shown.
  @Test func shiftStartsAtTheShownProject() {
    let click = ProjectClicks(picked: [], anchor: nil, shown: "shell", order: order).click("vault", modifiers: .shift)
    #expect(click.picked == ["shell", "swiftui", "vault"])
  }
}
