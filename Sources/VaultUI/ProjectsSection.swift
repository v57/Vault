import ComponentKit
import SwiftUI
import VaultKit

/// Where a `VaultProjectsSection` shows the picked project's content. The header's context menu changes it; each app
/// keeps its own choice.
public enum VaultProjectsLayout: String, CaseIterable, Identifiable, Sendable {
  /// The list, then the project in a section of its own (Git's repository pages).
  case separate
  /// As `separate`, but the list folds away once a project is picked (and starts folded): the project's section
  /// opens it again. For content that needs the room (a file tree).
  case folding
  /// The content right under the picked project's row, in the list (a few rows per project).
  case inline

  public var id: Self { self }

  public var title: String {
    switch self {
    case .separate: "Project Below the List"
    case .folding: "Project Below, List Folded"
    case .inline: "Project Inside the List"
    }
  }
}

/// How a `VaultProjectsSection` orders the projects and groups beside one another.
public enum VaultProjectsSort: String, CaseIterable, Identifiable, Sendable {
  /// The vault's order: as the user arranged them (in Git or any other app).
  case arranged
  case name
  /// The most recently added first.
  case added
  /// The most recently opened first, by the app's own dates (`recent:`).
  case recent
  /// Those with something to commit, push or pull first, as their devices last said (`VaultProject.statuses`).
  case changes
  /// The newest commit on any device first (Git keeps it in `statuses`).
  case lastCommit
  /// The newest push from any device first (Git keeps it in `statuses`).
  case lastPush

  public var id: Self { self }

  public var title: String {
    switch self {
    case .arranged: "As Arranged"
    case .name: "Name"
    case .added: "Recently Added"
    case .recent: "Recently Opened"
    case .changes: "With Changes First"
    case .lastCommit: "Last Commit"
    case .lastPush: "Last Push"
    }
  }
}

/// How much a project row shows. The list header's context menu changes it; each list keeps its own choice.
public enum VaultProjectsDisplay: String, CaseIterable, Identifiable, Sendable {
  /// The name over a line of detail (a branch and its device, a group's project count).
  case detailed
  /// The name alone.
  case regular
  /// The name alone, with a small icon: on the Mac the kit's compact rows, on touch screens still 44pt.
  case compact

  public var id: Self { self }

  public var title: String {
    switch self {
    case .detailed: "Detailed"
    case .regular: "Regular"
    case .compact: "Compact"
    }
  }

  /// The kit's row density for it, `other` being the sidebar's own.
  public func density(else other: KitRowDensity = .regular) -> KitRowDensity { self == .compact ? .compact : other }

  /// A row's icon size in it.
  public func iconSize(_ idiom: KitIdiom) -> CGFloat {
    if self == .compact { idiom.isTouch ? 24 : 16 } else { idiom.isTouch ? 32 : 18 }
  }
}

/// The projects the v57 apps share, in the vault's groups, with the picked project's content: below the list, below
/// a list that folds away, or right under its row (`VaultProjectsLayout`). The header's context menu picks the
/// layout, the order and how much the rows show (`VaultProjectsDisplay`) and holds the app's own items; the app picks
/// the default layout, and the user's choice is kept under `key`.
///
/// ```swift
/// VaultProjectsSection(
///   tree, selection: $projectID, layout: .folding, collapsedGroups: $collapsed.ids
/// ) { project in
///   FileTree(project)                                   // the picked project's rows
/// } menu: {
///   Toggle("Only Xcode Projects", isOn: $onlyXcode)       // the app's own items in the header's menu
/// }
/// .trailing { project in Count(project.changes) }      // a project row's trailing views
/// .removable { ids in removed.formUnion(ids) }          // Remove from List, Remove All Projects from List
/// .accessory { Button("Add Project…", systemImage: "plus") { … } }   // the list header's buttons
/// ```
///
/// Pass a tree already narrowed to what the app lists (`tree.filter { … }`), and put it in a `KitSidebar`: the list
/// and the project's section stick at the top as they scroll by. Without `content:` it is the list alone, for an app
/// that opens the picked project elsewhere (Git on iPhone and iPad).
public struct VaultProjectsSection<Content: View, Menu: View>: View {
  let tree: VaultProjectTree
  @Binding var selection: String?
  @Binding var collapsedGroups: Set<String>
  @ViewBuilder let content: (VaultProject) -> Content
  @ViewBuilder let menu: () -> Menu
  var title = "Projects"
  var meta: [String] = []
  var recent: ((VaultProject) -> Date?)?
  var trailing: ((VaultProject) -> AnyView)?
  var rowSubtitle: ((VaultProject) -> String?)?
  var rowProgress: ((VaultProject) -> Double?)?
  var icon: ((VaultProject) -> Data?)?
  var groupTrailing: ((VaultProjectGroup, [VaultProject]) -> AnyView)?
  var accessory: (() -> AnyView)?
  var emptyState: AnyView?
  var projectMeta: ((VaultProject) -> [String])?
  var projectAccessory: ((VaultProject) -> AnyView)?
  var rowMenu: ((VaultProject) -> AnyView)?
  var contentSticky: KitStickyBottom = .title
  var remove: (([String]) -> Void)?
  var renameGroup: ((VaultProjectGroup, String) -> Void)?
  var asksBeforeRemovingAll = true
  @State private var renamingGroup: String?
  @State private var confirmsRemoveAll = false
  @AppStorage private var layout: VaultProjectsLayout
  @AppStorage private var sort: VaultProjectsSort
  @AppStorage private var display: VaultProjectsDisplay
  /// The folded list is open (`.folding`).
  @AppStorage private var isListOpen: Bool
  @Environment(\.kitIdiom) private var idiom
  @Environment(\.kitRowDensity) private var density

  private var rowIconSize: CGFloat { display.iconSize(idiom) }

  /// The section over `tree`, `selection` the picked project's id. `key` names where the user's layout, order and
  /// display are kept (`<key>Layout`, `<key>Sort`, `<key>Display`).
  public init(
    _ tree: VaultProjectTree, selection: Binding<String?>, layout: VaultProjectsLayout = .separate,
    sort: VaultProjectsSort = .arranged, key: String = "Projects", collapsedGroups: Binding<Set<String>>,
    @ViewBuilder content: @escaping (VaultProject) -> Content, @ViewBuilder menu: @escaping () -> Menu
  ) {
    self.tree = tree
    _selection = selection
    _collapsedGroups = collapsedGroups
    self.content = content
    self.menu = menu
    _layout = AppStorage(wrappedValue: layout, "\(key)Layout")
    _sort = AppStorage(wrappedValue: sort, "\(key)Sort")
    _display = AppStorage(wrappedValue: .detailed, "\(key)Display")
    _isListOpen = AppStorage(wrappedValue: false, "\(key)ListOpen")
  }

  // MARK: Options

  /// The list's title and what its header adds to the count ("Work", an account's name).
  public func title(_ title: String, meta: [String] = []) -> Self {
    var section = self
    section.title = title
    section.meta = meta
    return section
  }

  /// When the app last opened each project: adds Recently Opened to the orders.
  public func recent(_ date: @escaping (VaultProject) -> Date?) -> Self {
    var section = self
    section.recent = date
    return section
  }

  /// A project row's trailing views: counts, a state.
  public func trailing<V: View>(@ViewBuilder _ views: @escaping (VaultProject) -> V) -> Self {
    var section = self
    section.trailing = { AnyView(views($0)) }
    return section
  }

  /// A project row's line under its name (a job's step: "Building · 2 min left"); `nil` shows none.
  public func rowSubtitle(_ subtitle: @escaping (VaultProject) -> String?) -> Self {
    var section = self
    section.rowSubtitle = subtitle
    return section
  }

  /// A project row's progress bar, of work running on it (`nil`: none).
  public func rowProgress(_ progress: @escaping (VaultProject) -> Double?) -> Self {
    var section = self
    section.rowProgress = progress
    return section
  }

  /// The app's own icon for a project the vault keeps none for (one it found itself), as PNG or JPEG bytes: the row
  /// decodes them off the main thread.
  public func icon(_ data: @escaping (VaultProject) -> Data?) -> Self {
    var section = self
    section.icon = data
    return section
  }

  /// A closed group's trailing views, from the projects in it: the sum of their counts, standing in for the rows
  /// it hides.
  public func groupTrailing<V: View>(@ViewBuilder _ views: @escaping (VaultProjectGroup, [VaultProject]) -> V) -> Self {
    var section = self
    section.groupTrailing = { AnyView(views($0, $1)) }
    return section
  }

  /// The list header's trailing buttons: Add Project.
  public func accessory<V: View>(@ViewBuilder _ views: @escaping () -> V) -> Self {
    var section = self
    section.accessory = { AnyView(views()) }
    return section
  }

  /// What the list shows while it has no projects: where to add one, or that nothing matches a search.
  public func emptyState<V: View>(@ViewBuilder _ content: () -> V) -> Self {
    var section = self
    section.emptyState = AnyView(content())
    return section
  }

  /// A project row's context menu, after Show in Finder.
  public func rowMenu<V: View>(@ViewBuilder _ items: @escaping (VaultProject) -> V) -> Self {
    var section = self
    section.rowMenu = { AnyView(items($0)) }
    return section
  }

  /// The picked project's header, in its own section: its meta line and trailing buttons.
  public func projectHeader<V: View>(
    meta: @escaping (VaultProject) -> [String], @ViewBuilder accessory: @escaping (VaultProject) -> V
  ) -> Self {
    var section = self
    section.projectMeta = meta
    section.projectAccessory = { AnyView(accessory($0)) }
    return section
  }

  /// Lets the user take projects off this app's list (they stay in the vault): Remove from List on each row, Remove
  /// Group from List on each group, Remove All Projects from List in the header's menu, after a confirmation.
  /// `remove` gets the projects' ids. `confirmsRemoveAll: false` leaves asking to the app, for one that asks its own
  /// question on every removal (what to keep).
  public func removable(confirmsRemoveAll: Bool = true, _ remove: @escaping ([String]) -> Void) -> Self {
    var section = self
    section.remove = remove
    section.asksBeforeRemovingAll = confirmsRemoveAll
    return section
  }

  /// Lets the user rename a group in place: Rename… in its menu. `rename` gets the group and its new name.
  ///
  /// ```swift
  /// VaultProjectsSection(tree, selection: $id, collapsedGroups: $collapsed)
  ///   .renamableGroups { group, name in
  ///     var group = group
  ///     group.name = name
  ///     vault.save(group)
  ///   }
  /// ```
  public func renamableGroups(_ rename: @escaping (VaultProjectGroup, String) -> Void) -> Self {
    var section = self
    section.renameGroup = rename
    return section
  }

  /// What the picked project's own section keeps in the sidebar's bottom dock while below the visible area
  /// (`.title` by default; `.content` for a few rows, as Git's pages).
  public func contentSticky(_ bottom: KitStickyBottom) -> Self {
    var section = self
    section.contentSticky = bottom
    return section
  }

  // MARK: Body

  public var body: some View {
    let picked = selection.flatMap { tree.node(id: $0)?.project }
    if opensElsewhere {
      list(picked)
    } else {
      layoutBody(picked)
    }
  }

  /// Without content the app opens the picked project somewhere else (a pushed screen, the split view's detail):
  /// the list alone, and no layouts to pick from.
  private var opensElsewhere: Bool { Content.self == EmptyView.self }

  @ViewBuilder private func layoutBody(_ picked: VaultProject?) -> some View {
    switch layout {
    case .separate:
      list(picked)
      if let picked { projectSection(picked) }
    case .folding:
      if picked == nil || isListOpen { list(picked) }
      if let picked { projectSection(picked) }
    case .inline:
      list(picked)
    }
  }

  private func list(_ picked: VaultProject?) -> some View {
    let count = tree.projects().count
    let items = Item.items(
      sorted(tree.roots), picked: layout == .inline && !opensElsewhere ? picked?.id : nil, sort: sorted)
    var section = KitSection(
      title, meta: [count == 1 ? "1 project" : "\(count) projects"] + meta, systemImage: "square.stack.3d.up",
      hue: .indigo
    ) {
      KitOutline(items, children: \.children, collapsed: $collapsedGroups.animation(.kit)) { item in
        switch item {
        case .group(let group, let count, _): groupRow(group, count: count)
        case .project(let project, _): projectRow(project)
        case .content(let project): contentRows(project).kitRowDensity(density)
        }
      }
      .kitRowDensity(display.density(else: density))
    } accessory: {
      accessory?()
    }
    .headerMenu { headerMenu }
    if let emptyState { section = section.emptyState { emptyState } }
    return section
    .kitPreloadAvatars(tree.projects().compactMap { $0.icon ?? icon?($0) }, size: rowIconSize)
    .kitConfirmation(
      count == 1 ? "Remove 1 project from the list?" : "Remove all \(count) projects from the list?",
      isPresented: $confirmsRemoveAll,
      message: "They stay in the other apps, and on disk. Opening one brings it back.",
      systemImage: "minus.circle", confirm: "Remove All"
    ) {
      withAnimation(.kit) { remove?(tree.projects().map(\.id)) }
    }
    // A picked project folds the list away again (`.folding`).
    .onChange(of: selection) { _, new in
      if layout == .folding, !opensElsewhere, new != nil { withKitAnimation { isListOpen = false } }
    }
    .kitSticky()
  }

  private func projectSection(_ project: VaultProject) -> some View {
    KitSection(
      Text(project.name),
      content: { content(project) },
      icon: { projectIcon(project, size: 24) },
      meta: { MetaLine(projectMeta?(project) ?? project.localPath.map { [Self.place($0)] } ?? []) },
      accessory: {
        HStack(spacing: 2) {
          projectAccessory?(project)
          if layout == .folding {
            Button(isListOpen ? "Hide \(title)" : "Show \(title)", systemImage: "rectangle.stack") {
              withKitAnimation { isListOpen.toggle() }
            }
            .kitHelp(isListOpen ? "Hide \(title)" : "Show \(title)", meta: "Pick another project")
          }
        }
      }
    )
    .headerMenu { headerMenu }
    .kitSticky(top: .titleWhileVisible, bottom: contentSticky)
  }

  @ViewBuilder private var headerMenu: some View {
    if !opensElsewhere {
      KitMenuSection("Show the Project") {
        KitMenuOptions(
          selection: Binding(get: { layout }, set: { new in withKitAnimation { layout = new } }),
          options: VaultProjectsLayout.allCases.map { ($0.title, $0) })
      }
    }
    KitMenuSection("Sort By") {
      KitMenuOptions(
        selection: Binding(get: { sort }, set: { new in withKitAnimation { sort = new } }),
        options: availableSorts.map { ($0.title, $0) })
    }
    KitMenuSection("Display") {
      KitMenuOptions(
        selection: Binding(get: { display }, set: { new in withKitAnimation { display = new } }),
        options: VaultProjectsDisplay.allCases.map { ($0.title, $0) })
    }
    if Menu.self != EmptyView.self || remove != nil {
      Divider()
      menu()
      if remove != nil {
        Button("Remove All Projects from List", systemImage: "minus.circle") {
          if asksBeforeRemovingAll { confirmsRemoveAll = true } else { remove?(tree.projects().map(\.id)) }
        }
      }
    }
  }

  // MARK: Rows

  private func projectRow(_ project: VaultProject) -> some View {
    SidebarRow(project.name, subtitle: display == .detailed ? rowSubtitle?(project) : nil) {
      projectIcon(project, size: rowIconSize)
    } trailing: {
      trailing?(project)
    }
    .progress(rowProgress?(project), status: .working)
    .isCurrent(project.id == selection)
    .action { withKitAnimation { selection = project.id } }
    .kitHelp(project.name, meta: project.localPath.map(Self.place))
    // No menu without items: a held row on iPhone opened an empty one.
    .contextMenu(if: project.localURL != nil || rowMenu != nil || remove != nil) {
      if let folder = project.localURL {
        Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal([folder]) }
      }
      if rowMenu != nil || remove != nil { Divider() }
      rowMenu?(project)
      if let remove {
        Button("Remove from List", systemImage: "minus.circle") { withAnimation(.kit) { remove([project.id]) } }
      }
    }
  }

  /// A group: a folder tile in a hue of its own, the name over its note or project count; a click opens or closes it.
  /// Closed, it stands in for the picked project inside it as the current row.
  private func groupRow(_ group: VaultProjectGroup, count: Int) -> some View {
    let isCollapsed = collapsedGroups.contains(group.id)
    let projects = tree.projects(in: group.id)
    return SidebarRow(
      group.name,
      subtitle: display != .detailed
        ? nil : group.note.flatMap { $0.isEmpty ? nil : $0 } ?? (count == 1 ? "1 project" : "\(count) projects")
    ) {
      Avatar(
        name: group.name, kind: .thing, systemImage: isCollapsed ? "folder" : "folder.fill",
        hue: StableHue.pick(group.name), size: rowIconSize)
    } trailing: {
      if isCollapsed { groupTrailing?(group, projects) }
    }
    .isCurrent(isCollapsed && projects.contains { $0.id == selection })
    .kitHelp(group.name, meta: group.localPath.map(Self.place))
    .kitRename(isRenaming: Binding { renamingGroup == group.id } set: { if !$0 { renamingGroup = nil } }) { name in
      renameGroup?(group, name)
    }
    .contextMenu(if: idiom.isTouch || group.localURL != nil || renameGroup != nil || remove != nil) {
      // A tap opens and closes it; held, a touch screen's menu says so too, and is never empty.
      if idiom.isTouch {
        Button(isCollapsed ? "Expand" : "Collapse", systemImage: isCollapsed ? "chevron.down" : "chevron.up") {
          withAnimation(.kit) {
            if isCollapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
          }
        }
      }
      if renameGroup != nil {
        Button("Rename…", systemImage: "pencil") { renamingGroup = group.id }
      }
      if let folder = group.localURL {
        Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal([folder]) }
      }
      if let remove {
        if idiom.isTouch || group.localURL != nil || renameGroup != nil { Divider() }
        Button("Remove Group from List", systemImage: "minus.circle") {
          withAnimation(.kit) { remove(projects.map(\.id)) }
        }
      }
    }
  }

  /// The picked project's content under its row (`.inline`).
  private func contentRows(_ project: VaultProject) -> some View {
    VStack(alignment: .leading, spacing: 2) { content(project) }
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func projectIcon(_ project: VaultProject, size: CGFloat) -> some View {
    Group {
      // Decoded off the main thread; the drawn tile stands in until then.
      if let data = project.icon ?? icon?(project) {
        Avatar(name: project.name, imageData: data, kind: .thing, size: size)
      } else {
        Avatar(name: project.name, kind: .thing, size: size)
      }
    }
  }

  // MARK: Order

  /// The orders that can tell these projects apart: the app's dates when it gave them, what their devices keep when
  /// any of them has.
  private var availableSorts: [VaultProjectsSort] {
    let projects = tree.projects()
    return VaultProjectsSort.allCases.filter { sort in
      switch sort {
      case .arranged, .name, .added: true
      case .recent: recent != nil
      case .changes: projects.contains { !$0.statuses.isEmpty }
      case .lastCommit: projects.contains { Self.lastCommit($0) != nil }
      case .lastPush: projects.contains { Self.lastPush($0) != nil }
      }
    }
  }

  private func sorted(_ nodes: [VaultProjectTree.Node]) -> [VaultProjectTree.Node] {
    switch sort {
    case .arranged: return nodes
    case .name: return nodes.sorted(by: Self.byName)
    case .added: return Self.newestFirst(nodes) { $0.added }
    case .recent:
      guard let recent else { return nodes }
      return Self.newestFirst(nodes, recent)
    case .changes:
      return nodes.sorted { a, b in
        let (first, second) = (Self.needsAttention(a), Self.needsAttention(b))
        return first != second ? first : Self.byName(a, b)
      }
    case .lastCommit: return Self.newestFirst(nodes, Self.lastCommit)
    case .lastPush: return Self.newestFirst(nodes, Self.lastPush)
    }
  }

  private static func byName(_ a: VaultProjectTree.Node, _ b: VaultProjectTree.Node) -> Bool {
    a.name.localizedStandardCompare(b.name) == .orderedAscending
  }

  /// By `date`, those without one last, then by name. A group goes by its newest project.
  private static func newestFirst(
    _ nodes: [VaultProjectTree.Node], _ date: (VaultProject) -> Date?
  ) -> [VaultProjectTree.Node] {
    nodes.map { (node: $0, date: $0.projects.compactMap(date).max() ?? .distantPast) }
      .sorted { $0.date != $1.date ? $0.date > $1.date : byName($0.node, $1.node) }
      .map(\.node)
  }

  private static func needsAttention(_ node: VaultProjectTree.Node) -> Bool {
    node.projects.contains { $0.statuses.values.contains(where: \.needsAttention) }
  }

  private static func lastCommit(_ project: VaultProject) -> Date? { project.statuses.values.compactMap(\.lastCommit).max() }
  private static func lastPush(_ project: VaultProject) -> Date? { project.statuses.values.compactMap(\.lastPush).max() }

  /// "~/Developer/v57": a folder from home.
  static func place(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}

extension VaultProjectsSection where Content == EmptyView {
  /// The list alone, for an app that opens the picked project somewhere else: iPhone pushes it, iPad shows it beside
  /// the sidebar. Its header's menu has the order, not the layouts.
  public init(
    _ tree: VaultProjectTree, selection: Binding<String?>, sort: VaultProjectsSort = .arranged,
    key: String = "Projects", collapsedGroups: Binding<Set<String>>, @ViewBuilder menu: @escaping () -> Menu
  ) {
    self.init(
      tree, selection: selection, sort: sort, key: key, collapsedGroups: collapsedGroups, content: { _ in EmptyView() },
      menu: menu)
  }
}

extension VaultProjectsSection where Content == EmptyView, Menu == EmptyView {
  /// The list alone, with no items of the app's own in its header's menu.
  public init(
    _ tree: VaultProjectTree, selection: Binding<String?>, sort: VaultProjectsSort = .arranged,
    key: String = "Projects", collapsedGroups: Binding<Set<String>>
  ) {
    self.init(tree, selection: selection, sort: sort, key: key, collapsedGroups: collapsedGroups) { EmptyView() }
  }
}

/// A row of the list: a group, a project, or the picked project's content under it.
private enum Item: Identifiable {
  case group(VaultProjectGroup, count: Int, children: [Item])
  case project(VaultProject, content: Bool)
  case content(VaultProject)

  var id: String {
    switch self {
    case .group(let group, _, _): group.id
    case .project(let project, _): project.id
    case .content(let project): "content:" + project.id
    }
  }

  /// A group's rows, the content under the picked project, `nil` for a leaf.
  var children: [Item]? {
    switch self {
    case .group(_, _, let children): children
    case .project(let project, let content): content ? [.content(project)] : nil
    case .content: nil
    }
  }

  static func items(
    _ nodes: [VaultProjectTree.Node], picked: String?, sort: ([VaultProjectTree.Node]) -> [VaultProjectTree.Node]
  ) -> [Item] {
    nodes.map { node in
      switch node {
      case .group(let group, let children):
        .group(group, count: node.projects.count, children: items(sort(children), picked: picked, sort: sort))
      case .project(let project):
        .project(project, content: project.id == picked)
      }
    }
  }
}

extension View {
  /// The kit's context menu, while it has items to show.
  @ViewBuilder fileprivate func contextMenu<Menu: View>(
    if hasItems: Bool, @ViewBuilder content: @escaping () -> Menu
  ) -> some View {
    if hasItems { kitContextMenu(content: content) } else { self }
  }
}
