# Vault user guide

Vault is the encrypted vault every v57 app shares. It keeps your logins with one-time codes and passkeys, cards, notes,
SSH hosts, database connections, projects and documents, and it holds encrypted folders. Everything syncs through your
own iCloud, sealed before it leaves the device. Vault is also where you manage your devices, the people you share with
and your own Hubs.

## Platforms

- **Mac:** macOS 14.4 or later. Updates come from GitHub Releases, only when you ask (see
  [Settings](Settings.md#updates-mac)).
- **iPhone and iPad:** iOS and iPadOS 17.4 or later. Updates come through the App Store.

The Mac, iPhone and iPad apps have the same features, with a few differences noted on each page. On iPhone, lists push
a page when you tap an item. On iPad and the Mac, the selected item shows in an inspector beside the list.

There's no Vault app for Linux or Windows. The other v57 apps there keep their own vault and can sync it through a Hub.

## Pages

- [Getting Started](Getting-Started.md): the first launch, the sidebar, the app lock and sync.
- [Logins and AutoFill](Logins-and-AutoFill.md): passwords, the password generator, one-time codes, passkeys and
  AutoFill.
- [Cards, Notes, Databases and Projects](Cards-Notes-Databases-and-Projects.md): the other items in your vault.
- [SSH Hosts](SSH-Hosts.md): servers, each device's own key, fallback addresses and server keys.
- [Documents](Documents.md): passports, IDs and other papers, scanned or imported, with reminders and redacted copies.
- [Encrypted Folders](Encrypted-Folders.md): folders only v57 apps can open, and decrypting them for a while.
- [Devices and People](Devices-and-People.md): your devices, a lost device, invites and safety codes, and letting your
  devices sign in to a Mac.
- [Hub](Hub.md): connecting your devices through a Hub you run.
- [Sync and Accounts](Sync-and-Accounts.md): iCloud, the iCloud switch, replaced values and separate accounts.
- [Recovery Key and Backup](Recovery-Key-and-Backup.md): getting your vault back if your keys are lost.
- [Settings](Settings.md): every settings pane.
- [Privacy and Security](Privacy-and-Security.md): the app lock, what leaves your device and when.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md)

## Works with other v57 apps

Every v57 app on a device reads the same vault and sees the others' changes within a second:

- [Shell](https://github.com/v57/Shell/blob/main/Docs/README.md) uses your SSH hosts, database connections and
  notes.
- [Database](https://github.com/v57/Database/blob/main/docs/README.md) uses your database connections and SSH hosts.
- [Markdown](https://github.com/v57/Markdown/blob/main/docs/README.md) keeps your notes, encrypted ones included.
- [Git](https://github.com/v57/Git/blob/main/docs/README.md) and [Code](https://github.com/v57/Code/blob/main/docs/README.md)
  use your projects and SSH hosts, and work on your other devices' projects over SSH.
- [Get](https://github.com/v57/Get/blob/main/docs/README.md)'s Download on… and
  [Player](https://github.com/v57/Player/blob/main/docs/README.md)'s Open from Device reach your other devices. You
  allow them per Mac in **Settings ▸ Remote**.
- [Hub](https://github.com/v57/hub-app/blob/main/docs/README.md) runs the Hubs that Vault connects to.

The **Use iCloud** switch in **Settings ▸ Privacy** is shared: turning it off in Vault turns it off for every v57 app on
that device.

## Network

Vault syncs through your iCloud while **Use iCloud** is on, and connects to a Hub only after you add one. Everything
else is something you start. [Privacy and Security](Privacy-and-Security.md#what-vault-sends-over-the-network) lists
each connection.

## For developers

The Swift libraries behind the app, for developers of other apps:
[VaultKit](VaultKit.md), [VaultFiles](VaultFiles.md), [VaultSync](VaultSync.md), [VaultHub](VaultHub.md) and
[VaultUI](VaultUI.md). The design is in the repository's [README](../README.md).
