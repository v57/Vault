# Sync and Accounts

## How your vault syncs

Every v57 app on a device reads the same vault and sees the others' changes within a second. Between devices, the vault
syncs through your iCloud:

- Records are encrypted on the device first, then go to iCloud. iCloud only sees ciphertext.
- Passwords and keys go through iCloud Keychain.
- Vault syncs when it opens and each time it comes to the front. **Sync Now** (⌘R) syncs at once.
- There's no helper process or login item: the app that makes a change sends it, or the next v57 app that opens.

When two devices change the same item, each field keeps the later change. Edits to different fields both survive.

The sidebar's status shows where your vault syncs. **Items** says when it last got your other devices' changes.

To sync with devices that have no iCloud (Linux, Windows, Android), connect them through your own [Hub](Hub.md).

## Turn iCloud off

**Settings ▸ Privacy ▸ Use iCloud** (also in **Settings ▸ Sync**) is one switch for every v57 app on this device.

1. Turn off **Use iCloud**.
2. Vault asks **Turn Off iCloud?**. Click **Turn Off**.

While it's off:

- Nothing goes to iCloud from this device. Changes stay here, and go up when you turn it on again.
- What's already in iCloud stays there, and your other devices keep it.
- New passwords are saved in this device's keychain. The sidebar and the New sheets say so.
- A Hub's sync isn't iCloud, and carries on.

Turn **Use iCloud** on again to send what waited and fetch what you missed. Each device decides for itself.

## Replaced values

If a password or code changed on two devices at once, the later value is used and the other is kept. **Settings ▸
Sync ▸ Replaced values ▸ Show…** lists the kept values. They're never deleted.

## Other sync settings

- **Check remotes** in **Settings ▸ Sync** sets how often Vault checks the remotes your folders sync through while it's
  open. See [Folder Sync](Folder-Sync.md#when-it-syncs). **Notify about conflicts** comes in a later version.
- **Live changes from your Hub** says "Not yet".

## Accounts

An account is a vault of its own beside **Personal**, for a client, an employer or a team. Its projects, hosts,
passwords and settings stay apart from Personal's, and it shows in every v57 app's account picker. Personal is always
there.

### Make an account

1. Open **Settings ▸ Accounts** and click **New Account…**.
2. Type a **Name** and pick a **Colour** for its tile.
3. Click **Create**.

With more than one account, an account picker shows at the top of the sidebar.

### Switch accounts

- Pick an account in the sidebar's picker. Every list then shows only that account's records.
- Press ⌃⌘1 to ⌃⌘9 to switch to the first nine accounts.
- On iPad and the Mac, **Open in a New Window** in the picker opens an account in a window of its own. Each window keeps
  its account.
- The picker also has **New Account…**. On iPad and the Mac it has **Manage Accounts…**, which opens Settings ▸
  Accounts.

### Edit or delete an account

In **Settings ▸ Accounts**, an account's **Edit…** renames it or changes its colour. **Delete…** deletes its
projects, hosts, passwords and settings on every device. Personal keeps everything. Windows showing the account go back
to Personal.

### Your name and Apple Teams

Each account card also has:

- **Your Name:** **Set…** or **Edit…** your name and email, used for git commits. GitHub matches the email to your
  account.
- **Apple Teams:** **Add…** a 10-character Team ID and a name. Projects with that development team sign with this
  account's keys. **Remove** takes one out.

The **This Mac** (or iPhone, iPad) card at the top has **Rename…** for this device.
