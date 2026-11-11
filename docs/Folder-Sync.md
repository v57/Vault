# Folder Sync

A synced folder is a folder on your device that Vault keeps in step through a remote: your other devices, and the people
you share it with, get a copy that follows yours. Share a Minecraft `mods` folder with friends, or hand a video project
to your editor, without a cloud drive in between.

The remote is plain storage you choose: today an **S3 bucket** (your Hub's storage, Cloudflare R2, Backblaze B2, MinIO or
AWS). It only ever holds ciphertext: encrypted chunks of your files, each device's signed change log, and the folder's
member list signed by you. Vault has no server of its own in between.

## Add a remote

1. Choose **Add Remote…** (in the File menu on the Mac, or the sidebar's New menu).
2. Pick **S3** and fill in a **Name**, the **Bucket**, the **Endpoint** (for example `http://nas.local:9000`), an
   optional **Folder in the bucket**, the **Access key ID** and the **Secret access key**. The secret is kept in iCloud
   Keychain.
3. **Test** reaches the bucket once and says how many items it holds.
4. Click **Add**.

A remote you add is on: Vault reaches it only for folders that sync through it, or when you browse it under
**Locations**. Its inspector's **Vault may reach it** switch turns it off; nothing contacts it then.

SFTP, SMB, iCloud and FTP remotes can be saved, but Vault doesn't connect to them yet.

**On your Hub:** a Hub's storage speaks S3. Use its endpoint, its bucket (`hub` for hub-s3-local) and the keys it
gave you.

## Sync a folder

1. Choose **Sync a Folder…** (in the File menu on the Mac, the sidebar's New menu, or **Sync a Folder…** in Folders
   while you have none).
2. Type a **Name**. **Folder** is where the files are: on the Mac, **Choose…** picks an existing folder (its files
   stay where they are, as they are). Without one, Vault makes a folder in its own place. On iPhone and iPad it's in
   Files under On My iPhone (or iPad) › Vault › Synced.
3. Under **Through**, pick the remote.
4. Click **Sync**. Vault writes the folder's member list to the remote, with you as its owner, and sends the files.

An encrypted folder can sync too: in its inspector, **Remote ▸ Sync…** picks the remote.

### When it syncs

Vault checks a folder's remote when it opens, when it comes back to the front, on **Sync Now** (⌘R) and every few
minutes while it's open (**Settings ▸ Sync ▸ Check remotes**). Nothing runs while Vault is closed; on iPhone and iPad
the system's background refresh checks now and then.

The folder's status line says when it last checked, or what went wrong. **Remote** in the inspector shows the chunks and
change logs on the remote, the last snapshot and how this device keeps the folder.

### Your other devices

Each of your devices chooses for itself. On another Mac, iPhone or iPad the folder shows in Folders with
**“Name” Isn’t on This Mac**: **Set Up Sync…** picks where to keep it, and the files arrive.

In the folder's inspector, **Mode** is **Read-write** (edits here are sent) or **Read-only** (edits here stay here), and
**On disk** is **Plain** (every app opens the files) or **Encrypted** (only v57 apps).

## Share a folder

Sharing hands someone the folder's key in the member list on the remote. They need their own access to the remote, with
the same endpoint, bucket and folder: **Copy Details** in the Share sheet copies those three (never your keys).

1. Open the folder and choose **Share…**. The sheet shows your invite as a QR code and a link that name the folder.
2. They scan the code in Vault (**Scan an Invite**), or open the link you send with **Copy Link**. Your key arrives on
   their side and the folder shows in their Folders.
3. They send you their invite the same way (**Invite Someone** in Devices & People, or **Scan Theirs** in your Share
   sheet). Their key arrives on your side.
4. In the Share sheet, compare the safety code with theirs, on a call you trust or in person, and check **It matches**.
5. Under **Can**, pick **Read and write** or **Only read**, and click **Add**. Vault adds them to the signed member list
   on the remote.

**Share…** works for a folder of your own that syncs through a remote. A folder someone shared with you can't be shared
on: only its owner signs its member list.

Removing someone from **Devices & People** also takes them out of the member lists of your folders and gives each a new
key. What they already downloaded stays theirs.

### Receive a shared folder

1. Scan their invite, or open their link. The folder shows in Folders as **Someone Shared “Name”**.
2. Add the remote it's on (**Add Remote…**) with the endpoint, bucket and folder they send you, and keys that can read
   it.
3. Send them your invite and compare the safety code.
4. Open the folder and choose **Set Up Sync…**: pick the remote and click **Sync**. **Only receive** is on unless you
   turn it off.

Until the owner adds you, the folder says **Waiting for _Name_ to add you**. Once they have, the files arrive the next
time Vault checks, and so does every change they make after.

## Edits on a read-only device

A device that only receives, or a person the owner lets only read, never sends its edits. They show under **Changed
here**:

- **Revert** puts the remote's version back, and **Revert All** does it for every file.
- **Keep Mine** keeps your edit; it stays here.

When the remote changes a file you edited here, it shows as a conflict with both versions side by side (text shows its
lines). Your edit is kept until you choose **Keep Mine** or **Revert to Remote**.

## Edits made at once

When two devices that may write change a file at the same time, every device settles it the same way: an edit beats a
delete, text merges line by line when the edits don't overlap, and otherwise the later edit wins and the other becomes a
copy next to it, named after the device and time (`Notes (conflict from MacBook 2026-11-11 143005).txt`).

## Not yet

- SFTP, SMB, iCloud and FTP remotes.
- Remote access for the people you share with travels outside Vault: you tell them the endpoint, bucket and keys.
- On iPhone and iPad, a synced folder lives in Vault's own place in Files; you can't pick another folder there yet.
