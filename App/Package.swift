// swift-tools-version: 6.2
// The app, a package of its own beside the libraries (..), so the repositories it depends on can depend on this one's
// libraries without a cycle between packages.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode,
/// open Vault-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../../\(name)")
}

/// This repository's libraries, the package at "..": SwiftPM names a path dependency after its folder, which is Vault in
/// the main checkout and the worktree's own name in a worktree.
let kits = String(Context.packageDirectory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().last ?? "Vault")

let settings: [SwiftSetting] = [
  .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "VaultApp", platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "VaultApp", targets: ["VaultApp"]),
    .library(name: "VaultExtensions", targets: ["VaultExtensions"]),
  ],
  dependencies: [
    .package(path: ".."),
    // The shared design, in-app updates, SSH to the user's devices, and scanning and notifications.
    v57("Component"), v57("UpdateKit"), v57("SSH"), v57("Platform"),
  ],
  targets: [
    // The app, all of it but its entry point (Sources/Vault/VaultMain.swift): Vault.xcodeproj builds that file into
    // Vault.app with Resources (the icon, asset catalog, Info.plist, entitlements and privacy manifest); on Linux and
    // Windows the Vault target below does.
    .target(
      name: "VaultApp",
      dependencies: [
        "VaultExtensions",
        .product(name: "VaultKit", package: kits), .product(name: "VaultFiles", package: kits),
        .product(name: "VaultSync", package: kits), .product(name: "VaultHub", package: kits),
        .product(name: "VaultUI", package: kits), .product(name: "ComponentKit", package: "Component"),
        .product(name: "SSHKit", package: "SSH"), .product(name: "PlatformScan", package: "Platform"),
        .product(name: "PlatformNotifications", package: "Platform"),
        // Updates from GitHub Releases outside the App Store (the iPad app updates through the App Store).
        .product(name: "UpdateKit", package: "UpdateKit", condition: .when(platforms: [.macOS, .linux, .windows])),
      ],
      swiftSettings: settings),
    // What the AutoFill and Share extensions show (the login picker, the share sheet), which the app shows too as
    // previews: Vault.xcodeproj's VaultAutoFill and VaultShare link it.
    .target(
      name: "VaultExtensions",
      dependencies: [.product(name: "VaultKit", package: kits), .product(name: "ComponentKit", package: "Component")],
      swiftSettings: settings),
  ])

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI is v57/SwiftUI. Only here: on Apple platforms the app uses Apple's SwiftUI, and
// v57/SwiftUI (with its swift-syntax) stays out of the package graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
#if os(Windows)
// On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the file APIs
// SwiftUIPortability adds along: every file gets them here too.
let appModules = ["Combine", "FoundationNetworking", "SwiftUIPortability"]
#else
// … and `import SwiftUI` brings Observation.
let appModules = ["Combine", "FoundationNetworking", "Observation", "SwiftUIPortability"]
#endif
let appSettings = settings + [.unsafeFlags(appModules.flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] })]
for target in package.targets where ["VaultApp", "VaultExtensions"].contains(target.name) {
  target.dependencies += ["SwiftUI", "SwiftUIPortability"].map { .product(name: $0, package: "SwiftUI") }
  target.swiftSettings = appSettings
}
// The entry point, Sources/Vault/VaultMain.swift, which Vault.xcodeproj builds on Apple platforms.
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this App folder>
// -Product VaultWinUI).
package.targets.append(
  .target(
    name: "Vault", dependencies: ["VaultApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.library(name: "VaultWinUI", type: .dynamic, targets: ["Vault"]))
#elseif os(Linux)
// The app on SwiftUI's GTK backend (in App/: V57_LOCAL=1 swift build --product Vault; SwiftUI's
// Linux/scripts/build-app --package <this App folder> Vault stages it).
package.targets.append(
  .executableTarget(
    name: "Vault", dependencies: ["VaultApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.executable(name: "Vault", targets: ["Vault"]))
#endif
#else
// Dev's screenshot scenes, in debug builds on Apple platforms (Dev's Linux app depends on apps' libraries, so not
// there).
package.dependencies += [v57("Dev")]
for target in package.targets where target.name == "VaultApp" {
  target.dependencies.append(.product(name: "DevScreenshots", package: "Dev"))
}
#endif
