# Recovery Key and Backup

Your vault keys live in iCloud Keychain. If iCloud Keychain ever loses them and you have no recovery key, your
encrypted folders, notes and passwords can't be opened. There's no other way in, by design. Vault gives you two ways to
guard against that: a recovery key and an encrypted backup file.

## Recovery key

A recovery key is 24 words (with a QR code) that bring back your vault keys on a device that lost them. It's off until
you make one, and Vault never nags you about it.

Open **Recovery Key** in the sidebar's Keys section, or **Settings ▸ Recovery Key**.

### Make a recovery key

1. Click **Create Recovery Key…**.
2. Vault shows 24 words and a QR code. They aren't shown again. Write the words down or print them, and keep them away
   from this device.

The status turns **On** on all your devices once they sync.

What it brings back: the vault keys, your identity, every folder key, and your passwords and passkeys (logins,
one-time codes, cards, passkeys, saved server and database passwords) and imported SSH keys.

What it doesn't: device SSH keys, which never leave their Secure Enclave (a recovered device makes a new one), Hub keys
and your GitHub sign-in. You sign in again, and approve the device on your Hubs again.

### Check it

**Check…** asks for the 24 words, typed or pasted, or the kit's QR code. Vault tells you whether this is the current
recovery key, an older one, or not a recovery key at all.

### Replace it

If the kit is lost or someone else saw it, click **Replace…**, then **Replace**. Vault makes a new vault key, seals
everything to a new kit and deletes the old copies. Your other devices get the new key through iCloud Keychain. Write
down the new words. A leaked kit still opens the copies someone already took, so change your passwords too.

### Turn it off

**Turn Off…**, then **Turn Off**, deletes every sealed copy, here and in iCloud. iCloud Keychain then holds the only
copy of your keys.

### Recover on a device that lost its keys

On a device showing **Waiting for Your Keys**, click **Recover with Key…** (or **Settings ▸ Recovery Key ▸
Recover…**). Type the 24 words or scan the kit's QR code, then click **Recover**. Vault says what it brought back, and
your records open.

## Encrypted backup

**Settings ▸ Backup** saves everything in one encrypted file: the records in Personal and every account, the vault keys
(current and older), every saved password and secret, your identity, and this device's keys.

### Export a backup

1. Click **Export…** next to **Export Encrypted Backup…**.
2. Type a **Passphrase** of at least 12 characters, and the same again.
3. Click **Export…** and choose where to save the file.

The file goes where you choose, never to iCloud by itself. Keep it off iCloud, and write the passphrase down apart from
the file. There's no way to open the backup without it.

### Restore a backup

1. Click **Restore…** next to **Restore from Backup…** and pick the file.
2. Type the backup's passphrase and click **Open**.
3. Vault shows what the file holds: when and on which device it was made, how many records and vaults, and how many
   passwords, secrets and keys.
4. **This is the device the backup was made on** brings back that device's own keys too. Vault turns it on when it
   recognises the device. On another device it starts off; leave it off.
5. Click **Restore**.

Restoring merges: it brings back what the backup holds, and what changed here since stays as it is. A summary shows
what came back and what was already here. A device SSH key opens only in its own device's Secure Enclave, so it
never moves to another device.
