# Getting Started

## Before you start

Vault keeps its keys in iCloud Keychain. For your vault to reach all your devices, sign in to the same Apple Account on
each of them and turn on iCloud Keychain in the system settings. Vault works without iCloud too: everything then stays
on that device.

## First launch

The first time you open Vault, the app lock asks for Touch ID, Face ID or your password. See
[Privacy and Security](Privacy-and-Security.md#the-app-lock).

- On iPhone, a welcome screen opens first. Tap **Open Vault** to go to your vault. It shows only once.
- On iPad and the Mac, the welcome shows in the main area while nothing is selected.

The welcome lists what's **Already in your vault**: the SSH hosts, databases, projects and notes the other v57 apps
saved, with their counts. Tap one to open its list. From the welcome you can also start with **New Encrypted Folder…**
or, on iPad and the Mac, **New Login**.

### Waiting for Your Keys

On a new device, your records may show **Waiting for Your Keys**. The keys arrive through iCloud Keychain from your
other Apple devices, and your records open as soon as they do. If they don't arrive:

- **Recover with Key…** brings them back from your recovery key. See [Recovery Key and Backup](Recovery-Key-and-Backup.md).
- **Join from Another Device…** scans an invite on a device that has your keys.

## Find your way around

The sidebar has these sections:

- **Items:** **Logins**, **Cards**, **Notes**, **SSH Hosts**, **Databases** and **Projects**, each with a count. The
  section's **+** makes a new login.
- **Documents:** **All Documents**, the **Inbox** while it holds something, and your collections.
- **Folders:** your encrypted folders, each with a lock or the minutes it stays decrypted, and your
  [synced folders](Folder-Sync.md).
- **Locations:** this device and the remotes you added.
- **Keys:** **Devices & People**, **Hub** and **Recovery Key**.

The **+** in the sidebar's bar opens the New menu: **New Login…**, **New Card…**, **New SSH Host…**, **New Document…**,
**New Encrypted Folder…**, **Sync a Folder…** and **Add Remote…**.

The sidebar's status shows where your vault syncs: iCloud, or this device when iCloud is off.

With more than one account, an account picker shows at the top of the sidebar. See
[Sync and Accounts](Sync-and-Accounts.md#accounts).

### On iPhone

The sidebar is the first screen. Tap a list to open it, then tap an item to open its page. **Back** returns. The gear in
the bar opens Settings.

### On iPad

The sidebar and your lists sit side by side. Use the sidebar button to hide or show the sidebar. The gear in the
sidebar's bar opens Settings in the main area. With more than one account, you can open an account in a window of its
own (see [Sync and Accounts](Sync-and-Accounts.md#accounts)).

### On the Mac

Each window shows one account. Settings is a window of its own: choose **Vault ▸ Settings…** (⌘,). The File menu
makes new items, and the Vault menu has **Sync Now** and **Lock All Folders**. See
[Keyboard Shortcuts](Keyboard-Shortcuts.md).

## Make your first login

1. Click **+** in the Items section, or choose **New Login…**.
2. Type a **Title**, the **Website** and your **Username**. Vault fills in a strong generated **Password**.
3. Click **Save**.

Every v57 app on your devices can now use it, and AutoFill can fill it once you turn Vault on there. See
[Logins and AutoFill](Logins-and-AutoFill.md).

## Next steps

- Make a recovery key, so you can get your vault back if your keys are ever lost:
  [Recovery Key and Backup](Recovery-Key-and-Backup.md).
- Look at your devices and their keys: [Devices and People](Devices-and-People.md).
