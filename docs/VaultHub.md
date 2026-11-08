# VaultHub

Hub as a backend for the vault: connects this device to the user's own Hubs, mirrors each Hub's devices into the
vault's SSH hosts, and syncs records through a Hub for devices without iCloud.

VaultHub is a library of its own so that VaultKit doesn't depend on Hub's SDK. Only the app that manages Hubs (the
Vault app) links it; every other app reads the hosts it mirrors through [VaultKit](VaultKit.md) alone
(`Vault.hubHosts`, `VaultHost.isViaHub`). Nothing connects until the user adds a Hub: the library never picks one.
The design (device keys, certificates, pinning, the mirror, record sync) is in the README's
[How it works](../README.md#how-it-works) ("Hub", "Record sync over Hub"); the user's side is in [Hub](Hub.md).

## Getting started

```swift
.package(url: "https://github.com/v57/Vault.git", branch: "main"),
// in the target:
.product(name: "VaultHub", package: "Vault"),
```

VaultHub depends on VaultKit and on Hub's Swift SDK (`HubService` and `ChannelSwift` from GitHub; with `V57_LOCAL=1`
Vault's `Package.swift` takes them from a Hub checkout two folders up instead).

```swift
import SwiftUI
import VaultHub
import VaultKit

@MainActor final class HubModel {
  let hubs = HubDirectory(vault: Vault.shared)

  init() { hubs.start() }   // connects the Hubs this device has turned on; none until the user adds one

  func add(_ address: String) throws {
    let hub = try hubs.add(url: address, name: "Home")   // e.g. "wss://hub.example.com"
    hubs.setSyncs(hub, true)                             // records through the Hub's hub-vault service
  }

  func approveWaitingDevices(on hub: VaultHubServer) async {
    guard let connection = hubs.connection(for: hub.id), connection.isOwner else { return }
    for device in connection.pending { await connection.approve(device.id) }
  }
}
```

A real app shows each pending device's `safetyCode` (computed here from the pinned Hub key; `codeChecks` is false when
the Hub sent a different one) and lets the user compare it before approving.

## Main API

| API | What it is |
|---|---|
| `HubDirectory(vault:)` | The Hubs this device connects to, kept in step with the vault's `VaultHubServer` records (`@Observable`, main actor). |
| `start()`, `stop()`, `refresh()` | Connect the Hubs turned on for this device and follow the records; disconnect. |
| `add(url:name:sameHubAs:keys:)` | Adds a Hub at a WebSocket address and connects to it. A bare port means the local Hub; `http(s)` becomes `ws(s)`. |
| `setConnects(_:_:)`, `setSyncs(_:_:)` | Turn a Hub, or record sync through it, on or off for this device. |
| `remove(_:)`, `forgetKey(of:)` | Remove a Hub from every device with the hosts it added; forget a pinned key that changed on purpose. |
| `connections`, `connection(for:)`, `thisDevice`, `thisDevice(on:)`, `error` | The live connections, this device as Hubs know it (`HubThisDevice`), and why it can't connect. |
| `HubDirectory.normalized(_:)` | An address as the SDK dials it, or nil. |
| `HubConnection` | One Hub: `status` (`connecting`, `connected`, `needsApproval`, `wrongHub`, `revoked`, `notEncrypted`, `offline`), `devices`, `pending`, `isOwner`, `safetyCode`, `recordSync`, `isUnencrypted`. |
| `approve(_:)`, `deny(_:)`, `revoke(_:)`, `rename(_:to:)` | An owner's actions on a device, by id. |
| `HubPendingDevice` | A device waiting for approval: id, name, platform, `safetyCode`, `codeChecks`, `firstSeen`. |
| `HubKey`, `HubKeyStore`, `HubKeyScope` | This device's Ed25519 keys in Hub's encodings, where they are kept (`VaultConfiguration.deviceGroup` in the keychain), and which keys a Hub record uses. |
| `HubDirectoryError` | `badAddress` (not a `ws://`, `wss://` address or a port), `noVault`. |

`HubSync` and `HubMailbox` live in VaultKit; a `HubConnection` with record sync on runs `HubSync` over its connection.

## Platform notes

| Platform | State |
|---|---|
| macOS 14, iOS/iPadOS 17 | Everything. The keys live in the `dev.v57.device` keychain group, which only Vault and the Hub app list. |
| Linux | Builds; the tests pass on Ubuntu 24.04. |
| Windows | Builds; the tests build. |
| Android | Not built or tested. |

A plain `ws://` address beyond the local network is refused (`notEncrypted`); use `wss://`.

## Testing

```bash
swift test --filter VaultHubTests
```

The protocol and key tests run on their own. Two suites need a running Hub and are skipped otherwise:
`HubRecordSyncLiveTests` (record sync between two devices through hub-server and hub-vault; `HUB_E2E_PORT` for a Hub
on `127.0.0.1`, or `HUB_E2E_URL`) and `HubAuthLiveTests` (auth against a malicious Hub in `Tests/VaultHubTests/Fixtures`;
also `HUB_EVIL_RELAY_PORT` and `HUB_EVIL_CLAIM_PORT`). VaultKit's `HubSyncTests` cover record sync with a fake mailbox.
