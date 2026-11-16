# Encrypted Folders

An encrypted folder keeps files that only v57 apps can open, with their names and contents both encrypted.

When you need the files in another app (Files, Finder, Terminal, an editor), you decrypt the folder for a while: Vault
makes a plain copy, seals your edits back into the folder, and removes the copy when the time is up.

## Make a folder

1. Choose **New Encrypted Folder…** (⇧⌘N), or the **+** (**New Folder**) in the sidebar's Folders section.
2. Type a **Name**.
3. **Where** is Vault's folder on this device. On the Mac, **Choose…** puts it somewhere else.
4. Click **Create**. The folder opens.

Each folder has its own key, kept in the vault and encrypted with your vault key, which iCloud Keychain holds. If your
vault keys are lost, so are its files, unless you made a recovery key. While you haven't, the sheet links to
**Create a recovery key**. See [Recovery Key and Backup](Recovery-Key-and-Backup.md).

## Browse a folder

The sidebar's **Folders** section lists your folders with a lock, or the minutes left while one is decrypted.

- **On iPad and the Mac**, a folder opens with a path bar, **Back** and **Forward**, a table of names, sizes and dates,
  and a search field. The inspector shows how the folder is kept on each of your devices.
- **On iPhone**, a folder shows its files and subfolders as rows, with the folder's cards under them. Tap a subfolder
  to open it, and a file to preview it. The preview is read straight from the encrypted folder, with no plain copy.
  **Share ▸ Share a Plain Copy…** under the preview makes a temporary copy to share, deleted when you leave the page.

## Decrypt a folder for other apps

1. Open the folder and choose **Decrypt…**.
2. Under **Lock after**, pick **15 min**, **30 min**, **1 hour** or **4 hours**. The sheet starts on the time you set
   in **Settings ▸ General ▸ Lock decrypted folders after**.
3. **On the Mac**, choose whether to **Show in Finder** and **Open in Terminal** when the copy is ready.
4. Click **Decrypt**.

Where the plain copy goes:

- **On iPhone and iPad**, in the Files app under On My iPhone (or iPad) › Vault, where other apps open it in place. Tap
  **Open in Files** (iPhone) or **Files** (iPad) to go there. When it locks, it moves out of Files.
- **On the Mac**, in Vault's own folder. **Finder** and **Terminal** in the toolbar open it. The copy isn't indexed by
  Spotlight or backed up by Time Machine.

While a folder is decrypted, an orange banner and a countdown show in the folder and the sidebar. Vault seals your
edits back into the encrypted folder as apps save them; the status line counts the edits sealed back.

**Any app you run can read the plain copy while it's decrypted.** Lock it as soon as you're done. On the Mac, an SSD
can't reliably erase a deleted plain copy.

## Lock a folder

- **Lock Now** (**Lock** on iPhone) seals any changes and removes the plain copy at once.
- **+30 min** (or **Add 30 Minutes** in the iPhone's menu) keeps it open 30 minutes longer.
- At the end of its time the folder locks itself, sealing any changes first.
- **Lock All Folders** (⌃⌘L, in the Vault menu on the Mac or with a hardware keyboard on iPad) locks every decrypted
  folder, in every account.

If Vault quits or crashes while a folder is decrypted, it seals and removes the leftover copy the next time it opens.

## Export a plain copy

**Export Decrypted…** saves a plain copy of the whole folder outside the vault, where you choose. It doesn't lock
again: other apps can read it there until you delete it. On iPhone and iPad you pick the place in Files.

On iPad and the Mac, **Show Encrypted Folder** shows the encrypted folder itself.

## Sharing and syncing folders

An encrypted folder syncs through a remote like any other: in its inspector, **Sync…** on the **Remote** card picks
the remote, and **Share…** hands its key to the people you add. Each device chooses whether its copy is encrypted or
plain. See [Folder Sync](Folder-Sync.md).

The **Locations** section lists this device, whose home folder you can browse, and the remotes you added. Vault
connects only to S3 remotes so far: SFTP, SMB and iCloud remotes can be saved, and **Test** says they come in a later
version.

## How a folder is encrypted

- Each folder has its own random 256-bit key.
- File contents are encrypted with AES-256-GCM in 64 KB chunks, each file with its own key derived from the folder's.
  Reordered chunks, or a file cut short, don't open.
- File and folder names are encrypted too (AES-GCM), so the same name in the same folder always encrypts the same way
  and paths resolve without an index. A name moved into another folder doesn't open.
- Without the key, the folder shows only its shape: how many files and subfolders it has, their encrypted names and
  their sizes. A file swapped with another or moved into another folder fails to open.
