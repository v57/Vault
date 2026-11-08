# Encrypted Folders

An encrypted folder keeps files that only v57 apps can open. File names and contents are both encrypted. When you need
the files in another app (Files, Finder, Terminal, an editor), you decrypt the folder for a while: Vault makes a plain
copy, seals your edits back into the folder, and removes the copy when the time is up.

## Make a folder

1. Choose **New Encrypted Folder…** (⇧⌘N), or **New Folder** in the sidebar's Folders section.
2. Type a **Name**.
3. **Where** is Vault's folder on this device. On the Mac, **Choose…** puts it somewhere else.
4. Click **Create**. The folder opens.

A folder's key is kept in iCloud Keychain with your other vault keys. If your keys are lost, so are its files, unless
you made a recovery key. While you haven't, the sheet links to **Create a recovery key**. See
[Recovery Key and Backup](Recovery-Key-and-Backup.md).

## Browse a folder

The sidebar's **Folders** section lists your folders with a lock, or the minutes left while one is decrypted.

- **On iPad and the Mac**, a folder opens with a path bar, **Back** and **Forward**, a table of names, sizes and dates,
  and a search field. The inspector shows how the folder is encrypted on each device.
- **On iPhone**, a folder shows its files and subfolders as rows. Tap a subfolder to open it, and a file to preview it.
  The preview is read straight from the encrypted folder, with no plain copy. **Share a Plain Copy…** in the preview's
  menu makes a temporary copy to share, deleted when you leave the page.

## Decrypt a folder for other apps

1. Open the folder and choose **Decrypt…**.
2. Under **Lock after**, pick **15 min**, **30 min**, **1 hour** or **4 hours**. The sheet starts on the time you set
   in **Settings ▸ General ▸ Lock decrypted folders after**.
3. **On the Mac**, choose whether to **Show in Finder** and **Open in Terminal** when the copy is ready.
4. Click **Decrypt**.

Where the plain copy goes:

- **On iPhone and iPad**, in the Files app under On My iPhone (or iPad) › Vault, where other apps open it in place. Tap
  **Open in Files** (iPhone) or **Files** (iPad) to go there.
- **On the Mac**, in Vault's own folder. **Finder** and **Terminal** in the toolbar open it. The copy isn't indexed by
  Spotlight or backed up by Time Machine.

While a folder is decrypted, an orange banner and a countdown show in the folder and the sidebar. Vault watches the
copy and seals your edits back as you save; the status line counts the edits sealed back.

**Any app you run can read the plain copy while it's decrypted.** Lock it as soon as you're done. On the Mac, an SSD
can't reliably erase a deleted plain copy.

## Lock a folder

- **Lock Now** (**Lock** on iPhone) seals any changes and removes the plain copy at once.
- **+30 min** (**Add 30 Minutes** on iPhone) keeps it open 30 minutes longer.
- At the end of its time the folder locks itself, sealing any changes first.
- **Lock All Folders** (⌃⌘L, in the Vault menu on the Mac or with a hardware keyboard on iPad) locks every decrypted
  folder.

If Vault quits or crashes while a folder is decrypted, it seals and removes the leftover copy the next time it opens.

## Export a plain copy

**Export Decrypted…** saves a plain copy of the whole folder outside the vault, where you choose. It doesn't lock
again: other apps can read it there until you delete it. On iPhone and iPad you pick the place in Files.

On iPad and the Mac, **Show Encrypted Folder** shows the encrypted folder itself.

## Sharing and syncing folders

These come in a later version of Vault:

- **Share…** on a folder shows your invite and lets you compare safety codes with someone, but sending them the
  folder's key isn't available yet.
- Folders don't sync between your devices yet. **Add Remote…** saves an S3, SFTP, SMB or iCloud location's details,
  but Vault doesn't connect to remotes yet: **Test** says so. The **Locations** section lists this device, which you can
  browse, and the remotes you added.
