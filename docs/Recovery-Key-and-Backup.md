# Recovery Key and Backup

Two ways to get your vault back if your keys are ever lost: a recovery key and an encrypted backup file.

Your vault keys live in iCloud Keychain. If iCloud Keychain ever loses them and you have no recovery key, your
encrypted folders, notes and passwords can't be opened. There's no other way in, by design.

## Recovery key

A recovery key is 24 words (with a QR code) that bring back your vault keys on a device that lost them. It's off until
you make one, and Vault never nags you about it.

The words stand for a 256-bit secret that only you keep. Your devices keep only its public half: they seal your keys
and passwords to it, and those sealed copies sync through iCloud like any record. Only the words open them.

Open **Recovery Key** in the sidebar's Keys section, or **Settings ▸ Recovery Key**.

### Make a recovery key

1. Click **Create Recovery Key…**.
2. Vault shows 24 words and a QR code. They aren't shown again. Write the words down and keep them away from this
   device.

The status turns **On** on all your devices once they sync.

What it brings back: the vault keys, and with them your records and encrypted folders' keys; your identity, so shared
folders and the people you share with still know you; your passwords and passkeys (logins, one-time codes, cards,
passkeys, saved server and database passwords); and imported SSH keys.

What it doesn't: device SSH keys, which never leave their Secure Enclave (a recovered device makes a new one), Hub keys,
your GitHub sign-in, and what Shell keeps in its own keychain. You sign in again, and approve the device on your Hubs
again.

### Check it

While the recovery key is on, **Check…** asks for the 24 words, typed or pasted. Click **Check**. Vault tells you
whether this is the current recovery key, a recovery key that isn't the current one, or not a recovery key at all.

### Replace it

If the kit is lost or someone else saw it, click **Replace…**, then **Replace**. Vault makes a new vault key, encrypts
your records again under it, seals everything to a new kit and deletes the old copies. Your other devices get the
new key through iCloud Keychain. Write down the new words. A leaked kit still opens the copies someone already took, so change your passwords too.

### Turn it off

**Turn Off…**, then **Turn Off**, deletes every sealed copy, here and in iCloud. iCloud Keychain then holds the only
copy of your keys.

### Recover on a device that lost its keys

1. On a device showing **Waiting for Your Keys**, click **Recover with Key…**. It opens **Recovery Key** (also in
   **Settings ▸ Recovery Key**).
2. Click **Recover…** next to **Recover with Key…**.
3. Type or paste the 24 words, then click **Recover**.

Vault says what it brought back, and your records open.

## Encrypted backup

**Settings ▸ Backup** saves everything in one encrypted file: the records in Personal and every account, the vault keys
(current and older), every saved password and secret, your identity, and this device's keys. The file is sealed with
AES-256-GCM under a key made from your passphrase (PBKDF2-HMAC-SHA256, 600,000 rounds), and a changed byte makes it
fail to open.

Backup isn't available in the demo vault.

### Export a backup

1. Click **Export…** next to **Export Encrypted Backup…**.
2. Type a **Passphrase** of at least 12 characters, and the same again.
3. Click **Export…** and choose where to save the file. From macOS 15 and iOS 18, the save dialog starts in Downloads
   on the Mac, and in Vault's own folder in Files on iPhone and iPad, both off iCloud.

The file goes where you choose, never to iCloud by itself. Keep it off iCloud, and write the passphrase down apart from
the file. There's no way to open the backup without it.

### Restore a backup

1. Click **Restore…** next to **Restore from Backup…** and pick the file.
2. Type the backup's passphrase and click **Open**.
3. Vault shows what the file holds: when and on which device it was made, how many records and vaults, and how many
   passwords, secrets and keys. It also says how many records the device that made it couldn't open, if any.
4. **This is the device the backup was made on** brings back that device's own keys too. Vault turns it on when it
   recognises the device. On another device it starts off; leave it off.
5. Click **Restore**.

Restoring merges: it brings back what the backup holds, and what changed here since stays as it is. A summary shows
what came back and what was already here. A device SSH key opens only in its own device's Secure Enclave, so it
never moves to another device.
