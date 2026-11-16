# Settings

Every settings pane, in the order Vault lists them.

<!-- only: mac -->

On the Mac, choose **Vault ▸ Settings…** (⌘,). Settings is a window of its own.

<!-- /only -->

<!-- only: ios -->

On iPhone and iPad, tap the gear in the sidebar's bar. On iPhone each pane is a row with its current value.

<!-- /only -->

## General

- **Ask for Touch ID or Face ID:** the app lock, on by default. Turning it off asks for Touch ID, Face ID or your
  password first. See [Privacy and Security](Privacy-and-Security.md#the-app-lock).
- **Lock decrypted folders after:** the time the Decrypt sheet picks first: 15 min, 30 min (the default), 1 hour or
  4 hours.

## Documents

Your document collections and the people documents belong to. See
[Documents](Documents.md#collections-and-people).

## Sync

- **Use iCloud**, the same switch as in Privacy. See [Sync and Accounts](Sync-and-Accounts.md).
- **Other devices** shows only when a device on an older version wrote records, or while this device waits for its
  keys to finish updating the vault.
- **Replaced values** shows only once a password or code was replaced by a later change on another device.
  **Show…** lists the kept values, after Touch ID, Face ID or your password.
- **Remotes:**
  - **Check remotes:** how often Vault checks the remotes your [synced folders](Folder-Sync.md) use while it's open:
    every 1, 5 (the default) or 15 minutes, or every hour. It also checks when Vault opens.
  - **In the background:** on iPhone and iPad, the system's background refresh checks them now and then while Vault
    is closed, at most every 15 minutes. On the Mac nothing runs while Vault is closed: there's no helper or login
    item.
- **Hub:** **Vault records through** each of your Hubs that's on for this device. See
  [Hub](Hub.md#sync-your-vault-through-a-hub). **Live changes from your Hub** is off and can't be turned on yet:
  folder changes come with **Check remotes**.
- **Notify about conflicts:** the switch is there, but Vault doesn't send notifications yet. Conflicts show in the
  folder until you choose.

## Recovery Key

Create, check, replace or turn off your recovery key, or recover with one. The same screen opens from **Recovery Key**
in the sidebar. See [Recovery Key and Backup](Recovery-Key-and-Backup.md).

## Backup

**Export Encrypted Backup…** and **Restore from Backup…**. See
[Recovery Key and Backup](Recovery-Key-and-Backup.md#encrypted-backup).

## AutoFill

**AutoFill passwords and codes** says whether the system offers Vault in password fields, **On** or **Off**.
**Turn On…** (or **Settings…** once it's on) opens the system's AutoFill & Passwords settings, where you turn Vault on.
See [Logins and AutoFill](Logins-and-AutoFill.md#autofill).

## Hub

Your Hubs with their status, each with **Open Hub**; or **Add Hub…** when there's none. Opening this pane connects to
the Hubs that are on for this device. See [Hub](Hub.md).

## Privacy

**Use iCloud**: one switch for every v57 app on this device. See
[Sync and Accounts](Sync-and-Accounts.md#turn-icloud-off).

## SSH Agent (Mac)

How the [SSH agent](SSH-Agent.md) works. The row says **On** or **Off**.

- **Key the agent offers:** **Agent key** (on: a Secure Enclave key made for the agent; off: this Mac's own key), and
  **Replace Agent Key…**, which asks first. Servers that trusted the old key no longer let the agent in.
- **Asking:** **Touch ID** asks **For each signature** or **Once per turn-on**. **AI agents always ask** (on) asks for
  every request an AI coding agent started, whatever **Touch ID** says. **Offer to turn on when asked while off** (on)
  offers at most once an hour for each app.
- **Length:** **Stop when the Mac locks** (on) also stops the agent when the Mac sleeps or you switch users.
- **Terminal and other apps:** **Use from Terminal**, **Every host** (off: only the hosts on the SSH Agent screen) and
  **Show in menu bar** (on; the item shows once the agent has been on). Vault warns here when `~/.ssh/config` names
  another agent.

## Accounts

This device's name with **Rename…**, then a card for each account: its name, **Your Name** and **Apple Teams**, and
**New Account…**. See [Sync and Accounts](Sync-and-Accounts.md#accounts). Not shown in the demo vault.

## Devices (iPhone and iPad)

Your devices, with **Rename…**, **Lost Device…** and **Remove…**, and the devices you stopped trusting with
**Trust Again…**. See [Devices and People](Devices-and-People.md).

## Remote (Mac)

Let your other devices sign in to this Mac over SSH. See
[Devices and People](Devices-and-People.md#let-your-devices-sign-in-to-a-mac).

## Updates (Mac)

The Mac app updates from v57's GitHub Releases.

- **Check for updates automatically** is off until you turn it on. While it's off, Vault never checks by itself. The
  same switch is **Vault ▸ Check for Updates Automatically**.
- **Check Now**, or **Vault ▸ Check for Updates…**, checks once.

When an update is found, Vault shows it in a window. Installing it replaces the app in place and relaunches Vault.

## About (iPhone and iPad)

Vault's version. On iPhone and iPad, Vault updates through the App Store.
