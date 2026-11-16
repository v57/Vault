# Privacy and Security

The app lock, how your vault is encrypted, and every connection Vault makes.

## The app lock

Vault asks for Touch ID, Face ID or your device password:

- when it opens;
- when it comes back after five minutes or more away;
- before it shows or copies a password, a card number or security code, a document's hidden number, a one-time code
  or the replaced values in **Settings ▸ Sync**;
- before AutoFill fills a password or code.

One unlock lasts five minutes, for the app and AutoFill. While Vault is locked, its windows show **Vault Is Locked**
and nothing of your vault. Click **Unlock** to try again. If you cancel the question, the lock screen stays with its
**Unlock** button.

<!-- only: ios -->

On iPhone and iPad, Vault also covers its window whenever it isn't the app in front, so the app switcher never shows a
revealed password or code.

<!-- /only -->

The lock is on by default. To turn it off, turn off **Settings ▸ General ▸ Ask for Touch ID or Face ID**; Vault asks
you to confirm with Touch ID, Face ID or your password first, even within the five minutes. The setting and the last
unlock belong to this device, don't sync, and sit in the keychain place only Vault and its AutoFill extension can
read. On a device with no password at all, there's nothing to ask for and everything opens.

## Copying secrets

A password, card number, code or document number you copy is cleared from the clipboard after 90 seconds, unless you
copied something else since. A one-time code copied from its row is cleared when it expires.

<!-- only: ios -->

On iPhone and iPad the copy is marked local, so it doesn't reach your other devices' clipboards.

<!-- /only -->

<!-- only: mac -->

On the Mac the copy is marked concealed and transient, so clipboard managers that follow those markers skip it.

<!-- /only -->

## How your vault is encrypted

- Every record is encrypted on your device with AES-256-GCM under a vault key before it's saved or synced. iCloud
  stores only the encrypted record with an id; the kind of item, its title and every field are inside the encryption.
- The vault keys are in iCloud Keychain, on your Apple devices only. While **Use iCloud** is off, a device keeps them
  in its own keychain.
- Logins' passwords, one-time codes, cards, passkeys, documents' hidden fields and your sharing identity are in a
  keychain place only Vault and its AutoFill extension can read. The other v57 apps hold the vault keys, so they open
  your records (a login's title, website and username, say) and the passwords they connect with (SSH hosts, databases,
  remotes), but not those secrets. Get and Player hold only a copy of the vault keys and no passwords at all.
- Each device's SSH key is made in its Secure Enclave and never leaves it. A backup can bring it back only on the same
  device. A key made since 4 November 2026 signs only after you confirm it's you, where the device has a password.
- Encrypted folders encrypt file names as well as contents. See [Encrypted Folders](Encrypted-Folders.md).
- Documents are read on the device. Their pages, thumbnails and the text read from them are encrypted again with a key
  made from your sharing identity, so the other v57 apps can't open them. Something you share to Vault from another app is sealed
  to Vault before it's saved; the share extension holds no keys.
- The recovery kit is a 256-bit secret, written as 24 words. Your keys and passwords are sealed to it, and those
  sealed copies sync like any record. See [Recovery Key and Backup](Recovery-Key-and-Backup.md).
- An encrypted backup is sealed with AES-256-GCM under a key made from your passphrase (PBKDF2-HMAC-SHA256,
  600,000 rounds).

## Things to know

- **A decrypted folder is readable by any app you run** until it locks. Lock it as soon as you're done. Export
  Decrypted… makes a plain copy that never locks.
- **A shared, redacted document copy can't be taken back** once it's sent.
- **Server keys:** the first connection to a server asks whether to trust its key. After that, every v57 app refuses
  a changed key without asking. See [SSH Hosts](SSH-Hosts.md#server-keys).
- **Without a recovery key or a backup**, losing iCloud Keychain's copy of your keys means losing your vault. See
  [Recovery Key and Backup](Recovery-Key-and-Backup.md).
- **A Hub** never gets your vault keys, but it sees your devices' names, systems and keys, when they're online, which
  devices share a vault, and the ids, sizes and times of what they sync. See [Hub](Hub.md#what-a-hub-sees).
- **An S3 remote** gets your synced folders' files encrypted, but it sees the folder's member list (names, public keys
  and roles), each device's random id, and the sizes and times of what changes. See
  [Folder Sync](Folder-Sync.md#what-the-remote-sees).
- **Settings ▸ Remote** on the Mac edits the Mac's `authorized_keys`. Every key listed there can sign in to the Mac as
  you.

<!-- only: mac -->

- **The SSH agent** answers only programs running as you on this Mac, and offers no key while it's off. See
  [SSH Agent](SSH-Agent.md).

<!-- /only -->

## What Vault sends over the network

Vault contacts no server on its own. It connects only for these, and only when the condition holds:

| What | When |
|---|---|
| Your iCloud (CloudKit and iCloud Keychain) | While **Use iCloud** is on: at launch, each time Vault comes to the front, on **Sync Now**, on the Mac when another device changes something and, on iPhone and iPad, when the system runs Vault's background refresh (asked for only while a synced folder uses a remote). At most every four hours this device's record also notes its model and when it last ran a v57 app, sealed like every record. Turn it off in **Settings ▸ Privacy**. |
| Your Hubs | Only after you add one, and only from devices where **Connect from this device** is on. Never at launch: Vault connects once you open **Hub**, **Devices & People** or **Settings ▸ Hub** or **Sync**, or change a Hub, and stays connected until you quit. Nothing of this device goes out before the server proves the Hub's key. Your vault goes through a Hub only if you turn on **Sync vault through it**. |
| GitHub Releases (Mac) | When you choose **Check for Updates…** or **Check Now**, or once you turn on **Check for updates automatically**. |
| Your servers over SSH | When you click **Take Out** in Lost Device. Vault connects to your SSH hosts, signs in with this device's key or the host's saved password where it already accepted the server's key, and removes the lost device's key from `~/.ssh/authorized_keys`. A server whose key it doesn't know is refused, not signed in to. |
| Your remotes (S3) | For a [synced folder](Folder-Sync.md): when Vault opens or comes to the front, on **Sync Now**, every few minutes while it's open (**Settings ▸ Sync ▸ Check remotes**) and, on iPhone and iPad, when the system runs Vault's background refresh. Also **Test** in Add Remote and browsing a remote under **Locations**. Only remotes that are on and that a folder uses. Vault connects only to S3 remotes; the other kinds can be saved but aren't contacted. |
| Your browser | When you tap a login's website, or **Open…** in Lost Device (your Apple Account's device page). Your browser opens the page, not Vault. |

On the Mac, **Settings ▸ Remote** checks every two seconds while it's open whether Remote Login answers on the Mac
itself; nothing leaves the Mac. The SSH agent makes no connections.

Nothing else: no analytics, no crash reports, no website icons. Documents, QR codes and setup keys are read on the
device. AutoFill reads your logins from the device and sends nothing; the system learns only each login's website and
username, so it can suggest it.
