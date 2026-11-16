# Devices and People

**Devices & People** in the sidebar's Keys section lists your devices and their keys, the people you share with, and
your identity for sharing.

## This device

The first card is this device:

- **Name:** **Rename…** changes the name your other devices, your Hub and the servers that let it in show. Leave it
  empty to use the system's name.
- **SSH key:** each device has its own SSH key, an ECDSA P-256 key made in its Secure Enclave. The private key never
  leaves the device. **Copy** copies its public key.
- **Signs:** a key made since 4 November 2026 signs only after you confirm it's you with Touch ID, Face ID or your
  password, and a yes lasts 15 minutes in each app. An older key signs with nothing asked; the card says so.

## Your other devices

**Your other devices** lists each of your devices that runs a v57 app, with its system (macOS, iOS or iPadOS, as the
device says itself), its key's fingerprint and when it was last seen. On iPhone the row shows only when it was last
seen. **Seen** is when the device last ran a v57 app with sync on; each device notes it at launch and after syncing, at
most every four hours. Touch and hold (or right-click) a device for **Rename…** and **Lost Device…**.

**Settings ▸ Devices** on iPhone and iPad (and **Settings ▸ Remote** on the Mac) lists the same devices with how many
projects each has. Touch and hold (or right-click) one for **Rename…**, **Lost Device…** and **Remove…**, for a device
you no longer use. Removing takes it out of every v57 app, and it can't sign in to your Macs any more; projects that
were only on it go too. It only tidies the list: the device keeps the keys and passwords it has, and comes back if it
runs a v57 app again. To cut a device off, use Lost Device.

### Devices without iCloud Keychain

Linux, Windows and Android devices don't have iCloud Keychain. Click **Add Device…** (on iPhone, **Add Device** in the
bottom bar), or the **A device without iCloud Keychain** row. The **Add a Device** sheet shows your invite as a QR code
and a link, with **Copy Link**, for the v57 app on that device to scan or open.

### Devices on your Hub

With a Hub connected, a row shows how many devices are on it and how many wait to join. Tap it to open the
[Hub](Hub.md) screen.

## A lost or stolen device

Touch and hold (or right-click) the device and choose **Lost Device…**. The sheet walks you through five steps. Each
runs only when you click it, and you can skip any step, undo a skip or run a step again. **Done** closes the sheet.

1. **Remove It from Your Apple Account:** **Open…** opens your Apple Account's device page in your browser. Remove the
   device there, then click **I Removed It**. Until then it keeps getting your vault keys and passwords through iCloud
   Keychain, whatever the other steps do.
2. **Stop Trusting It:** **Stop Trusting** takes it out of Personal and every account, in every v57 app, and it doesn't
   come back by itself: what it publishes is ignored and your Macs don't let it in. For each of your Hubs, **Revoke**
   stops the Hub letting it in at once. That works only on a Hub you own that this device is connected to.
3. **Take It Off Your Servers:** for each of your SSH hosts, **Take Out** signs in with this device's key, or the
   host's saved password, and removes the lost device's lines from the server's `~/.ssh/authorized_keys`. Other lines
   stay. Vault signs in only to a server whose key you already accepted; it doesn't stop to ask about a new one.
   **Take Out of All** does them one after another. On the Mac, **This Mac** removes its lines from the Mac's own
   file.
4. **Make a New Vault Key:** **Make New Key** seals every record again with a new key, and records written under the
   old key are refused from then on. The lost device keeps what it copied before but can't write to your vault. Your
   other devices get the new key through iCloud Keychain, so iCloud has to be on. Do step 1 first, or the lost device
   would get the new key too.
5. **Change These by Hand:** lists the logins, passkeys, cards, servers with a password and databases the device could
   read, so you can change them where they belong. A new vault key doesn't change them.

A device you stopped trusting shows as **Not trusted**. **Trust Again** (in the device's menu, or **Trust Again…** in
Settings) lets it back in the next time a v57 app runs on it.

## People

To share with someone, each of you needs an identity for sharing: a key pair of its own (X25519 to receive keys,
Ed25519 to sign), kept in iCloud Keychain apart from your devices' SSH keys.

### Set up your identity

Under **Your identity**, click **Set Up Sharing**. Vault makes your identity once and shows its **Signing** and
**Key wrapping** fingerprints. It's the same on all your Apple devices that share iCloud Keychain. On iPad and the Mac,
**Show QR Code** shows your invite. Making an invite also makes your identity, if you have none yet.

### Invite someone

Click **Invite…** in People (on iPhone, **Invite**). The sheet shows a QR code and a link. Let the other person scan
the code, or send them the link with **Copy Link**.

### Add someone from their invite

- Scan their QR code in the **Scan an Invite** sheet: open it with **Scan Theirs** in a folder's **Share…** sheet, or
  **Join from Another Device…** on the welcome while your records wait for your keys. On iPhone the camera fills the
  screen. Nothing is sent while it scans.
- Or, with their invite link copied, click **Paste Link** in the same sheet. Vault refuses a link that isn't an invite
  or was changed after it was made.
- Or tap their invite link in Messages or Notes: Vault opens and adds them.

The person shows under **People** as **Waiting** until you compare codes.

### Compare safety codes

Select the person. Their **Safety code** shows as 12 groups of five digits. The same code shows on their devices.
Compare them in person or on a call you trust. If they match, click **It Matches**: the person shows as **Verified**.
A different code would mean someone swapped a key.

### Remove someone

Select the person and click **Remove…** (on iPhone, **Remove** with their name), then **Remove**. They go from your
People list. Folders you own and share with them through a remote get new keys, so they can't read anything new; what
they already downloaded stays theirs.

To give someone a folder, open it and choose **Share…**: see [Folder Sync](Folder-Sync.md#share-a-folder). Sending
logins to someone comes in a later version of Vault.

## Let your devices sign in to a Mac

**On the Mac**, **Settings ▸ Remote** lets your other devices work on this Mac over SSH, without a Hub: Git, Code,
Shell, Database, Player and Get on your iPhone, iPad or other computers. Each device signs in with its own key, only
once you allow it.

1. Turn on Remote Login in System Settings ▸ General ▸ Sharing. While it's off, the pane says **Remote Login Is Off**,
   and **Open Sharing…** takes you there. The pane notices when it's on.
2. Turn on **Let Your Devices In**. This Mac then shows as a host on your other devices.
3. Under **Your Devices**, turn on the switch of each device that may sign in. Vault adds its key to the Mac's
   `~/.ssh/authorized_keys`.
4. Under **Apps on Your Devices**, turn on Get or Player on a device, if you want them to reach this Mac. These apps
   don't hold your device's key: each signs in with its own, only to run a command or read files, with no terminal and
   no tunnels.

Turning **Let Your Devices In** off again takes this Mac's host away and removes every device key Vault added to
`authorized_keys`.

More on the pane:

- **Sign In with a Password** controls whether anyone who knows the Mac's password can sign in from the network. Off is
  the safest choice: your devices have their own keys and keep working. macOS asks for an administrator's password to
  change it. Turning it off writes `/etc/ssh/sshd_config.d/050-v57-keys-only.conf`; turning it on removes that file.
- **Other Keys** lists the other lines in the Mac's `~/.ssh/authorized_keys`, added by hand or by another app. Each can
  sign in as you. **Remove…** takes one out, and **Add Key…** adds a public key line.

In Devices & People on the Mac, **SSH from your devices** links to this pane.
