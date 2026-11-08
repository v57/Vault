# Privacy and Security

## The app lock

Vault asks for Touch ID, Face ID or your device password:

- when it opens;
- when it comes back after five minutes or more away;
- before it shows or copies a password, a card number or security code, a document's hidden number, or a one-time
  code;
- before AutoFill fills a password or code.

One unlock lasts five minutes, for the app and AutoFill. While Vault is locked, its windows show **Vault Is Locked**
and nothing of your vault. Click **Unlock** to try again.

- **On iPhone and iPad**, Vault also covers its window whenever it isn't the app in front, so the app switcher never
  shows a revealed password or code.
- **On the Mac**, a Vault window that's only behind other windows doesn't count as away.

The lock is on by default. To turn it off, turn off **Settings ▸ General ▸ Ask for Touch ID or Face ID**; Vault asks
you to confirm with Touch ID, Face ID or your password first. The setting and the last unlock belong to this device and
don't sync.

## Copying secrets

A password or code you copy stays on this device. It doesn't reach your other devices' clipboards, and clipboard
managers skip it. A password is cleared from the clipboard after 90 seconds, and a code when it expires, unless you
copied something else since.

## How your vault is encrypted

- Every record is encrypted on your device before it's saved or synced. iCloud stores only the encrypted record with
  an id; the kind of item, its title and every field are inside the encryption.
- The keys are in iCloud Keychain, on your Apple devices only.
- Logins, one-time codes, cards, passkeys and your sharing identity are in a keychain place only Vault and its AutoFill
  extension can read. The other v57 apps read what they need: SSH hosts, database connections and their passwords,
  notes and projects.
- Each device's SSH key is made in its Secure Enclave and never leaves it. A backup can bring it back only on the same
  device. A key made since November 2026 signs only after you confirm it's you.
- Encrypted folders encrypt file names as well as contents. See [Encrypted Folders](Encrypted-Folders.md).
- Documents are read on the device and encrypted before they're saved: their pages, thumbnails and the text read from
  them.

## Things to know

- **A decrypted folder is readable by any app you run** until it locks. Lock it as soon as you're done. Export
  Decrypted… makes a plain copy that never locks.
- **A shared, redacted document copy can't be taken back** once it's sent.
- **Server keys:** the first connection to a server asks whether to trust its key. After that, every v57 app refuses
  a changed key without asking. See [SSH Hosts](SSH-Hosts.md#server-keys).
- **Without a recovery key or a backup**, losing iCloud Keychain's copy of your keys means losing your vault. See
  [Recovery Key and Backup](Recovery-Key-and-Backup.md).
- **A Hub** never gets your vault keys, but it sees your devices' names and keys, when they're online, which devices
  share a vault, and the ids, sizes and times of what they sync. See [Hub](Hub.md).
- **Settings ▸ Remote** on the Mac edits the Mac's `authorized_keys`. Every key listed there can sign in to the Mac as
  you.

## What Vault sends over the network

Vault contacts no server on its own. It connects only for these, and only when the condition holds:

| What | When |
|---|---|
| Your iCloud (CloudKit and iCloud Keychain) | While **Use iCloud** is on: at launch, each time Vault comes to the front, on **Sync Now**, and when another device changes something. Turn it off in **Settings ▸ Privacy**. |
| Your Hubs | Only after you add one, while a v57 app is open, and only from devices where **Connect from this device** is on. Your vault goes through a Hub only if you turn on **Sync vault through it**. |
| GitHub Releases (Mac) | When you choose **Check for Updates…** or **Check Now**, or once you turn on **Check for updates automatically**. |
| Your servers over SSH | When you click **Take Out** in Lost Device. Vault signs in with this device's key, to servers where you accepted the lost device's key. |
| Your browser | When you tap a login's website, or **Open…** in Lost Device (your Apple Account's device page). Your browser opens the page, not Vault. |

Nothing else: no analytics, no crash reports, no website icons. Documents, QR codes and setup keys are read on the
device. AutoFill reads your logins from the device and sends nothing. Remotes aren't connected to yet.
