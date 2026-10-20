// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Vault",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "VaultKit", targets: ["VaultKit"]),
    .library(name: "VaultFiles", targets: ["VaultFiles"]),
    .library(name: "VaultSync", targets: ["VaultSync"]),
    .library(name: "VaultHub", targets: ["VaultHub"]),
  ],
  dependencies: [
  ],
  targets: [
    // The shared, encrypted store every v57 app reads and writes: items, keys, sync, notes.
    .target(name: "VaultKit"),
    .testTarget(name: "VaultKitTests", dependencies: ["VaultKit"]),
    // Encrypted folders: chunked file contents, encrypted names, folder keys, temporary decryption.
    .target(name: "VaultFiles", dependencies: ["VaultKit"]),
    .testTarget(name: "VaultFilesTests", dependencies: ["VaultFiles"]),
    // Folder sync over plain storage: signed member lists, content-addressed chunks, per-device change logs.
    .target(name: "VaultSync", dependencies: ["VaultFiles", "VaultKit"]),
    .testTarget(name: "VaultSyncTests", dependencies: ["VaultSync"]),
    // Hub as a backend: this device on the user's own Hub, its device directory mirrored into the vault's hosts.
    // VaultKit itself doesn't depend on Hub; apps reach Hub only through this library.
    .target(
      name: "VaultHub",
      dependencies: [
        "VaultKit", .product(name: "HubService", package: "HubService"),
        .product(name: "Channel", package: "ChannelSwift"),
      ]),
    .testTarget(name: "VaultHubTests", dependencies: ["VaultHub"], resources: [.copy("Fixtures")]),
  ]
)

// Hub's Swift SDK (`~/Developer/Hub`): GitHub's main branch, or the checkouts at ../../Hub with `V57_LOCAL=1`.
package.dependencies += Context.environment["V57_LOCAL"] == nil
  ? [
    .package(url: "https://github.com/v57/HubService.git", branch: "main"),
    .package(url: "https://github.com/v57/ChannelSwift.git", branch: "main"),
  ]
  : [.package(path: "../../Hub/HubService/HubService"), .package(path: "../../Hub/Channel/ChannelSwift")]

#if os(Windows) || os(Linux)
// Off Apple platforms CryptoKit and SQLite3 come from v57/SwiftUI's stand-ins (GitHub's main branch, or the
// checkout next to this one with `V57_LOCAL=1`).
package.dependencies.append(
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/SwiftUI.git", branch: "main") : .package(path: "../SwiftUI"))
for target in package.targets where target.name == "VaultKit" {
  target.dependencies += [
    .product(name: "CryptoKit", package: "SwiftUI"), .product(name: "SQLite3", package: "SwiftUI"),
  ]
}
for target in package.targets where ["VaultFiles", "VaultSync", "VaultHub"].contains(target.name) {
  target.dependencies.append(.product(name: "CryptoKit", package: "SwiftUI"))
}
#endif
