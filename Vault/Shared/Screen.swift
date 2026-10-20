import ComponentKit
import SwiftUI
import VaultKit

/// A screen's two panes: the list on the window ground and the inspector beside it on the panel ground, split by a
/// divider that keeps its width per screen. Without an inspector the list takes the whole width.
struct ListAndInspector<Main: View, Inspector: View>: View {
  var name: String
  @ViewBuilder var main: Main
  @ViewBuilder var inspector: Inspector
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    if idiom == .phone {
      // No room beside the list: the screen pushes the inspector's cards instead (`PushedDetail`).
      main.kitPane(.content)
    } else {
      ResizableSplit(
        "vault.\(name).inspector", pane: .trailing, width: idiom.isTouch ? 380 : 400, range: 300...520,
        mainMinWidth: 420
      ) {
        main.kitPane(.content)
      } pane: {
        KitInspector(width: nil) { inspector }
      }
    }
  }
}

/// The toolbar's search capsule (a filled field at the bar's end).
struct ToolbarSearch: View {
  @Binding var text: String
  var prompt: String
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    KitSearchField(text: $text, prompt: prompt)
      .frame(width: idiom.isTouch ? 260 : 240)
  }
}

/// A list screen's scroll of section cards, 8pt in from the pane's edges.
struct CardScroll<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(spacing: KitMetrics.gutter) { content }
        .padding(.horizontal, KitMetrics.gutter)
        .padding(.vertical, KitMetrics.gutter)
        .padding(.bottom, 44)
    }
  }
}

/// A login's or person's two-letter tile in the name's stable colour: website icons are never fetched (that would
/// tell a server which sites are in the vault).
struct LetterTile: View {
  var name: String
  var size: CGFloat = 24

  var body: some View {
    Tile(letters: Self.letters(name), hue: StableHue.pick(name), size: size)
  }

  /// "At" for "Atlas admin", "Gh" for "GitHub", "Pg" for "pgAdmin (staging)".
  static func letters(_ name: String) -> String {
    let letters = Array(name.filter(\.isLetter))
    guard let first = letters.first else { return "?" }
    // A capital inside the name (GitHub → Gh), else the next letter.
    let inner = first.isUppercase ? letters.dropFirst().first(where: \.isUppercase) : nil
    let second = inner ?? letters.dropFirst().first
    return String(first).uppercased() + (second.map { String($0).lowercased() } ?? "")
  }

}

/// A key's short form, as the design shows it: "SHA256:q3Zt…8fKc".
enum ShortKey {
  static func fingerprint(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "—" }
    let parts = value.split(separator: ":", maxSplits: 1)
    if parts.count == 2, parts[1].count > 10 {
      return "\(parts[0]):\(parts[1].prefix(4))…\(parts[1].suffix(4))"
    }
    return value.count > 14 ? "\(value.prefix(6))…\(value.suffix(4))" : value
  }
}

/// A row in a section card that opens something else (a linked item): the glyph tile, the title, a line under it,
/// a chevron.
struct LinkRow: View {
  var title: String
  var subtitle: String
  var systemImage: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        RowTile(systemImage: systemImage)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).lineLimit(1)
          Text(subtitle).kitFont(.caption).lineLimit(1)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.kitTertiary)
      }
      .padding(.horizontal, 8)
      .frame(minHeight: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// This device as the screens name it: "This Mac", "this iPad", "This iPhone".
enum ThisDevice {
  @MainActor static var word: String { KitDevice.name }

  @MainActor static var system: String {
    switch KitDevice.name {
    case "iPhone": "iOS"
    case "iPad": "iPadOS"
    default: "macOS"
    }
  }

  @MainActor static var isTouch: Bool { KitDevice.name == "iPhone" || KitDevice.name == "iPad" }
}
