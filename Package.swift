// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Vault",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "VaultKit", targets: ["VaultKit"])
  ],
  targets: [
    // The shared, encrypted store every v57 app reads and writes: items, keys, sync, notes.
    .target(name: "VaultKit"),
    .testTarget(name: "VaultKitTests", dependencies: ["VaultKit"]),
  ]
)
