# VaultHub

Hub as a backend for the vault: connects this device to the user's own Hubs, mirrors each Hub's devices into the
vault's SSH hosts, and syncs records through a Hub for devices without iCloud.

## Purpose

VaultHub is a library of its own so that VaultKit doesn't depend on Hub's SDK. Only the app that manages Hubs (the
Vault app) links it; every other app reads the hosts it mirrors through [VaultKit](VaultKit.md) alone
(`Vault.hubHosts`, `VaultHost.isViaHub`). Nothing connects until the user adds a Hub: the library never picks one, and
the Hubs turned on for a device connect only once the app calls `start()`.

It doesn't run a Hub, and it isn't how apps talk to services on a Hub: it's the vault's side (devices, approvals, record
sync). The design (device keys, certificates, pinning, the mirror, record sync) is in the README's
[How it works](../README.md#how-it-works) ("Hub", "Record sync over Hub"); the user's side is in [Hub](Hub.md).

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS 14, iOS/iPadOS 17**: everything. The keys live in the `dev.v57.device` keychain group, which only Vault and
  the Hub app list; a build not entitled to it keeps them in the shared group.
- **Linux**: builds, and the tests pass on Ubuntu 24.04. The keys go to the Secret Service, like every VaultKit
  keychain item there.
- **Windows**: builds; the tests build. The keys go to the Credential Manager.
- **Android**: not built or tested.

A plain `ws://` address beyond the local network is refused (`notEncrypted`): nothing is sent to it. Use `wss://`.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Vault.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "VaultHub", package: "Vault")]),
]
```

VaultHub depends on VaultKit and on Hub's Swift SDK (`HubService` and `ChannelSwift` from GitHub; with `V57_LOCAL=1`
Vault's `Package.swift` takes them from a Hub checkout two folders up instead).

```swift
import SwiftUI
import VaultHub
import VaultKit

@MainActor final class HubModel {
  let hubs = HubDirectory(vault: Vault.shared)

  // Call when the user opens a screen that shows the Hubs, not at launch.
  func show() { if !hubs.isStarted { hubs.start() } }

  func add(_ address: String) throws {
    let hub = try hubs.add(url: address, name: "Home")   // e.g. "wss://hub.example.com"
    hubs.setSyncs(hub, true)                             // records through the Hub's hub-vault service
  }

  func approveWaitingDevices(on hub: VaultHubServer) async {
    guard let connection = hubs.connection(for: hub.id), connection.isOwner else { return }
    for device in connection.pending where device.codeChecks { await connection.approve(device.id) }
  }
}
```

A real app shows each pending device's `safetyCode` and lets the user compare it with the code on that device before
approving. The code is computed on this device from the pinned Hub key, never taken from the Hub; `codeChecks` is false
when the Hub sent a different code or the device's id doesn't match its key.

## Main API

### The Hubs this device uses

| API | What it is |
|---|---|
| `HubDirectory(vault:)` | The Hubs this device connects to, kept in step with the vault's `VaultHubServer` records (`@Observable`, main actor). |
| `start()`, `stop()`, `refresh()`, `isStarted` | Connect the Hubs turned on for this device and follow the records; disconnect. |
| `add(url:name:sameHubAs:keys:)` | Adds a Hub at a WebSocket address and connects to it. A bare port means the local Hub; `http(s)` becomes `ws(s)`. |
| `setConnects(_:_:)`, `setSyncs(_:_:)` | Turn a Hub, or record sync through it, on or off for this device. |
| `remove(_:)`, `forgetKey(of:)` | Remove a Hub from every device with the hosts it added; forget a pinned key that changed on purpose. |
| `connections`, `connection(for:)`, `thisDevice`, `thisDevice(on:)`, `keyScope(of:)`, `error` | The live connections, this device as Hubs know it (`HubThisDevice`), which keys a Hub uses, and why it can't connect. |
| `HubDirectory.normalized(_:)` | An address as the SDK dials it, or nil. |
| `HubDirectoryError` | `badAddress` (not a `ws://`, `wss://` address or a port), `noVault`. |

### One Hub and its devices

| API | What it is |
|---|---|
| `HubConnection` | One Hub: `status` (`connecting`, `connected`, `needsApproval`, `wrongHub`, `revoked`, `notEncrypted`, `offline`), `devices`, `pending`, `isOwner`, `safetyCode` (this device's, while it waits for approval), `recordSync`, `isUnencrypted`, `error`. |
| `approve(_:)`, `deny(_:)`, `revoke(_:)`, `rename(_:to:)` | An owner's actions on a device, by id. |
| `HubPendingDevice` | A device waiting for approval: id, name, platform, `safetyCode`, `codeChecks`, `firstSeen`. |
| `HubConnection.RecordSync` | `off`, `syncing`, `synced(_:sent:received:)`, or `unavailable` (no `hub-vault` service, or this device isn't allowed yet). |

```swift
@MainActor func describe(_ connection: HubConnection) -> String {
  switch connection.status {
  case .needsApproval: "Waiting for approval, code \(connection.safetyCode ?? "…")"
  case .wrongHub: "This isn't the Hub that was added"
  case .notEncrypted: "Needs a wss:// address"
  default: "\(connection.devices.count) devices"
  }
}
```

### Keys

| API | What it is |
|---|---|
| `HubKey` | An Ed25519 key in Hub's encodings (`spki`, `sign`, `keyFile`, `HubKey.verify`, `HubKey.safetyCode`). |
| `HubKeyStore` | Where this device keeps its Hub keys: this-device-only keychain items, never synced. `deviceKey()` is shared with the Hub app (`shareDeviceKey(_:)`), so the Hub app and every v57 app are one device on a Hub. |
| `HubKeyScope` | Which keys a Hub record uses: the shared ones, or keys derived from the device key and the Hub's address (`keys(for:)`), so what one Hub sees means nothing on another. |

Record sync itself (`HubSync`, `HubMailbox`) lives in VaultKit; a `HubConnection` with record sync on runs `HubSync`
over its connection. The Hub carries only records sealed under a vault key, which it never has.

## Testing

```bash
swift test --filter VaultHubTests
```

The protocol and key tests (`HubProtocolTests`, `HubKeyPlacesTests`) run on their own. Two suites need a running Hub
and are skipped otherwise: `HubRecordSyncLiveTests` (record sync between two devices through hub-server and hub-vault;
`HUB_E2E_PORT` for a Hub on `127.0.0.1`, or `HUB_E2E_URL`) and `HubAuthLiveTests` (auth against a malicious Hub in
`Tests/VaultHubTests/Fixtures`; also `HUB_EVIL_RELAY_PORT` and `HUB_EVIL_CLAIM_PORT`). VaultKit's `HubSyncTests` cover
record sync with a fake mailbox.

## Related

- [VaultKit](VaultKit.md): `VaultHubServer` and `VaultHost` records, `HubSync`, and the keychain underneath.
- [VaultUI](VaultUI.md): Lost Device takes the app's Hub steps as actions.
- [Hub](Hub.md): Hubs in the Vault app, for users.
