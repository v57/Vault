# Getting Started

The first launch, the welcome, the sidebar and your first login.

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
saved, with their counts. Tap one to open its list. From the welcome you can also start with **New Encrypted Folder…**,
**Sync a Folder…** (it opens **Add Remote** first) or, on iPad and the Mac, **New Login**.

### Waiting for Your Keys

On a new device, your records may show **Waiting for Your Keys**. The keys arrive through iCloud Keychain from your
other Apple devices, and your records open as soon as they do. If they don't arrive:

- **Recover with Key…** opens **Recovery Key**, where **Recover…** brings them back from your recovery key. See
  [Recovery Key and Backup](Recovery-Key-and-Backup.md#recover-on-a-device-that-lost-its-keys).
- **Join from Another Device…** scans an invite on a device that has your keys.

## Find your way around

The sidebar has these sections:

- **Items:** **Logins**, **Cards**, **Notes**, **SSH Hosts**, **Databases** and **Projects**, each with a count. The
  section's **+** makes a new login.
- **Documents:** **All Documents**, the **Inbox** while it holds something, and your collections. Its **+** adds a
  document.
- **Folders:** your encrypted folders, each with a lock or the minutes it stays decrypted, and your
  [synced folders](Folder-Sync.md). Its **+** makes a new encrypted folder.
- **Locations:** this device and the remotes you added. Its **+** adds a remote.
- **Keys:** **Devices & People**, **Hub**, **SSH Agent** (Mac) and **Recovery Key**.

The **+** in the sidebar's bar opens the New menu: **New Login…**, **New Card…**, **New SSH Host…**, **New Document…**,
**New Encrypted Folder…**, **Sync a Folder…** and **Add Remote…**.

The search button in the sidebar's bar opens **Search Vault**. While it has text, the sidebar lists what matches by
kind: logins (title, username or website), cards, notes (name or folder), SSH hosts (name, address or user),
databases, projects and documents (by name). Pick one to open its list with it selected; clear the search to get the
sections back.

The sidebar's status shows where your vault syncs: iCloud, or this device when iCloud is off.

With more than one account, an account picker shows at the top of the sidebar. See
[Sync and Accounts](Sync-and-Accounts.md#accounts).

## On the Mac

Each window shows one account. The sidebar's status also says how many devices share your vault, such as
**iCloud · 3 devices**.

Settings is a window of its own: choose **Vault ▸ Settings…** (⌘,). The File menu makes new items, and the Vault menu
has **Sync Now** and **Lock All Folders**. See [Keyboard Shortcuts](Keyboard-Shortcuts.md).

## On iPhone and iPad

The sidebar's bar has a gear for Settings beside the **+**.

### iPhone

The sidebar is the first screen. Tap a list to open it, then tap an item to open its page. **Back** returns. The gear
opens Settings.

### iPad

The sidebar and your lists sit side by side. Use the sidebar button to hide or show the sidebar. The gear opens
Settings in the main area. With more than one account, you can open an account in a window of its own (see
[Sync and Accounts](Sync-and-Accounts.md#switch-accounts)).

## Make your first login

1. Click **+** in the Items section, or choose **New Login…**.
2. Type a **Title**, the **Website** and your **Username**. Vault fills in a strong generated **Password**.
3. Click **Save**.

It syncs to your other devices, and AutoFill can fill it once you turn Vault on there. See
[Logins and AutoFill](Logins-and-AutoFill.md).

## Next steps

- Make a recovery key, so you can get your vault back if your keys are ever lost:
  [Recovery Key and Backup](Recovery-Key-and-Backup.md).
- Look at your devices and their keys: [Devices and People](Devices-and-People.md).
