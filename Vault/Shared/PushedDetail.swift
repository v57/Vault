import ComponentKit
import SwiftUI
import VaultKit

extension EnvironmentValues {
  /// The inspector's cards are shown as a pushed screen (iPhone): its header and actions move into the bars.
  @Entry var pushedDetail = false
}

/// What a screen pushes on iPhone, where there's no room for the inspector beside the list: the inspector's cards
/// in a scroll, the kit's bar on top (Back, the live title, one trailing tool) and the bottom bar (search and the
/// actions).
struct PushedDetail<Icon: View, Content: View, Trailing: View, Actions: View>: View {
  var title: String
  var meta: [String]
  @ViewBuilder var icon: Icon
  @ViewBuilder var content: Content
  @ViewBuilder var trailing: Trailing
  @ViewBuilder var actions: Actions
  @State private var search = ""

  var body: some View {
    ScrollView {
      VStack(spacing: KitMetrics.gutter) { content }
        .padding(.horizontal, KitMetrics.gutter + 4)
        .padding(.top, 4)
        .padding(.bottom, 24)
    }
    .environment(\.pushedDetail, true)
    .background(.kitWindow)
    .kitPane(.content)
    .kitToolbar(title, title: {
      RichHeader(Text(title), size: .title) { icon } meta: { MetaLine(meta) } accessory: { EmptyView() }
    }) {
      ToolbarSlot { trailing }
    }
    .kitBottomBar(searchText: $search, prompt: "Search") { actions }
    .navigationBarBackButtonHidden(true)
  }
}

extension PushedDetail where Icon == SizedLiveIcon {
  init(
    title: String, meta: [String], systemImage: String, hue: Hue = .accent, status: WorkStatus = .idle,
    @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing, @ViewBuilder actions: () -> Actions
  ) {
    self.init(
      title: title, meta: meta, icon: { SizedLiveIcon(hue: hue, status: status, size: .title) { Image(systemName: systemImage) } },
      content: content, trailing: trailing, actions: actions)
  }
}

/// A bottom-bar button that opens a kit menu of `items` (Share, More).
struct BarMenu<Items: View>: View {
  var title: String
  var systemImage: String
  @ViewBuilder var items: Items
  @State private var isPresented = false

  init(_ title: String = "More", systemImage: String = "ellipsis", @ViewBuilder items: () -> Items) {
    self.title = title
    self.systemImage = systemImage
    self.items = items()
  }

  var body: some View {
    Button(title, systemImage: systemImage) { isPresented = true }
      .labelStyle(.iconOnly)
      .kitMenu(isPresented: $isPresented) { items }
  }
}

/// A list screen's own bottom bar on iPhone (search, then its actions), where the Mac has toolbar tools.
struct PhoneBars<Actions: View>: ViewModifier {
  var prompt: String
  @Binding var search: String
  @ViewBuilder var actions: Actions
  @Environment(\.kitIdiom) private var idiom

  func body(content: Content) -> some View {
    if idiom == .phone {
      content.kitBottomBar(searchText: $search, prompt: prompt) { actions }
    } else {
      content
    }
  }
}

extension View {
  /// The bottom bar of a list screen on iPhone; nothing elsewhere.
  func phoneBottomBar<Actions: View>(prompt: String, search: Binding<String>, @ViewBuilder actions: () -> Actions) -> some View {
    modifier(PhoneBars(prompt: prompt, search: search, actions: actions))
  }
}

/// A pane's status bar on the Mac and iPad; on iPhone the bottom bar holds the screen's tools and the bar's status
/// isn't shown.
struct PaneStatusBar<Status: View>: ViewModifier {
  var systemImage: String
  var hue: Hue
  var status: WorkStatus
  @ViewBuilder var line: Status
  @Environment(\.kitIdiom) private var idiom

  func body(content: Content) -> some View {
    if idiom == .phone {
      content
    } else {
      content.kitStatusBar(systemImage: systemImage, hue: hue, status: status) { line }
    }
  }
}

extension View {
  /// `kitStatusBar`, except on iPhone.
  func paneStatusBar<Status: View>(
    systemImage: String, hue: Hue = .accent, status: WorkStatus = .idle, @ViewBuilder content: () -> Status
  ) -> some View {
    modifier(PaneStatusBar(systemImage: systemImage, hue: hue, status: status, line: content))
  }
}
