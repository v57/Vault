// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Vault",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "VaultKit", targets: ["VaultKit"]),
    .library(name: "VaultFiles", targets: ["VaultFiles"]),
  ],
  targets: [
    // The shared, encrypted store every v57 app reads and writes: items, keys, sync, notes.
    .target(name: "VaultKit"),
    .testTarget(name: "VaultKitTests", dependencies: ["VaultKit"]),
    // Encrypted folders: chunked file contents, encrypted names, folder keys, temporary decryption.
    .target(name: "VaultFiles", dependencies: ["VaultKit"]),
    .testTarget(name: "VaultFilesTests", dependencies: ["VaultFiles"]),
  ]
)

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
for target in package.targets where target.name == "VaultFiles" {
  target.dependencies.append(.product(name: "CryptoKit", package: "SwiftUI"))
}
#endif
