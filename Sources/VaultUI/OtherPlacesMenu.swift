import ComponentKit
import Foundation
import SwiftUI
import VaultKit

/// A folder's "On Other Devices" submenu: when the folder is a vault project, its folders on the user's other devices
/// that one of their Hubs reaches (the Vault app keeps those devices as hosts via Hub), each with an SSH command for a
/// terminal in the folder there. Draws nothing for a folder that isn't a project or has no other places. Reads the
/// window's vault (`VaultAccountScope`), else the shared one.
///
/// ```swift
/// .kitContextMenu {
///   Button("Show in Finder") { KitDesktop.reveal([url]) }
///   VaultOtherPlacesMenu(root: url)
/// }
/// ```
public struct VaultOtherPlacesMenu: View {
  let root: URL
  @Environment(\.vault) private var windowVault

  public init(root: URL) {
    self.root = root
  }

  public var body: some View {
    let vault = windowVault ?? .shared
    let places = vault.project(atPath: root.path).map { vault.otherPlaces(of: $0) }?.filter { $0.sshCommand != nil } ?? []
    if !places.isEmpty {
      KitSubmenu("On Other Devices", systemImage: "point.3.connected.trianglepath.dotted") {
        ForEach(places) { place in
          Button("Copy SSH Command for \(place.deviceName)") { KitPasteboard.copy(place.sshCommand ?? "") }
            .help(place.path)
        }
      }
    }
  }
}
