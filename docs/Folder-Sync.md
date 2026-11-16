# Folder Sync

A synced folder is a folder on your device that Vault keeps in step through a remote, so your other devices and the
people you share it with get a copy that follows yours.

Share a Minecraft `mods` folder with friends, or hand a video project to your editor, without a cloud drive in between.

The remote is plain storage you choose: today an **S3 bucket** (your Hub's storage, Cloudflare R2, Backblaze B2, MinIO or
AWS). Vault has no server of its own in between. See [What the remote sees](#what-the-remote-sees).

## Add a remote

1. Choose **Add Remote…** (in the File menu on the Mac, or the sidebar's New menu), or the **+** in the sidebar's
   Locations section.
2. Pick **S3** and fill in a **Name**, the **Bucket**, the **Endpoint** (for example
   `http://nas.local:9000`), an optional **Folder in the bucket**, the **Access key ID** and the **Secret
   access key**. The secret is kept in the keychain with your passwords (iCloud Keychain while **Use iCloud** is on).
3. **Test** reaches the bucket once and says how many items it holds.
4. Click **Add**.

The sheet's banner says what the remote sees: your files only encrypted, but each folder's member list (names, public
keys and roles) as it is, each device's random id, and the sizes and times of what changes. See
[What the remote sees](#what-the-remote-sees).

A remote you add is on: Vault reaches it only for folders that sync through it, or when you browse it under
**Locations**. Its inspector's **Vault may reach it** switch turns it off; nothing contacts it then. Picking a remote
that's off for a folder turns it on again.

SFTP, SMB and iCloud remotes can be saved, but Vault doesn't connect to them yet; **Test** says so. An SFTP remote
picks one of your [SSH hosts](SSH-Hosts.md) from a menu; without hosts, Add Remote says to add one first.

**On your Hub:** a Hub's storage speaks S3. Use its endpoint, its bucket (`hub` for hub-s3-local) and the keys it
gave you.

## Sync a folder

1. Choose **Sync a Folder…** (in the File menu on the Mac, the sidebar's New menu, or **Sync a Folder…** in Folders
   while you have none).
2. Type a **Name**. **Folder** is where the files are. On the Mac, **Choose…** picks an existing folder; its files
   stay where they are, as they are, and without one Vault makes a folder in its own place. On iPhone and iPad it's in
   Files under On My iPhone (or iPad) › Vault › Synced, where other apps open the files.
3. Under **Through**, pick the remote.
4. Click **Sync**. Vault writes the folder's member list to the remote, with you as its owner, and sends the files.

An encrypted folder can sync too: in its inspector, **Sync…** on the **Remote** card picks the remote.

### When it syncs

Vault checks a folder's remote when it opens, when it comes back to the front, on **Sync Now** (⌘R) and every few
minutes while it's open (**Settings ▸ Sync ▸ Check remotes**, 5 minutes unless you change it). On the Mac nothing runs
while Vault is closed. On iPhone and iPad, the system's background refresh checks now and then.

The folder's status line says when it last checked, or what went wrong. The **Remote** card in the inspector shows the
chunks and change logs on the remote, the last snapshot and how each device keeps the folder. On iPhone, the folder's
**Folder Settings** button shows the inspector.

### Your other devices

Each of your devices chooses for itself. On another Mac, iPhone or iPad the folder shows in Folders with
**“Name” Isn’t on This Mac** (or iPhone, iPad): **Set Up Sync…** picks where to keep it, and the files arrive.

In the folder's inspector, **Mode** is **Read-write** (edits here are sent) or **Read-only** (edits here aren't sent),
and **On disk** is **Plain** (every app opens the files) or **Encrypted** (only v57 apps). **Your other devices** lists
what each of them chose.

## Share a folder

Sharing hands someone the folder's key in the member list on the remote. They need their own access to the remote, with
the same endpoint, bucket and folder. On iPad and the Mac, **Copy Details** in the Share sheet copies those three
(never your keys).

1. Open the folder and choose **Share…**. The sheet shows your invite as a QR code, and **Copy Link** copies it as a
   link. Both name the folder.
2. They open the link you send in Vault. If they have a folder of their own, **Scan Theirs** in its Share sheet scans
   your QR code too. Your key arrives on their side and the folder shows in their Folders.
3. They send you their invite the same way (**Invite** in Devices & People, or the Share sheet of a folder of
   theirs), and you open their link or scan it with **Scan Theirs** in your Share sheet. Their key arrives on your
   side.
4. In the Share sheet, compare the safety code with theirs, on a call you trust or in person, and check **It matches**.
5. Under **Can**, pick **Read and write** or **Only read**, and click **Add**. Vault adds them to the member list on the
   remote, with the folder key sealed to their key, and signs it.

**Share…** works for a folder of your own that syncs through a remote; for one that doesn't yet, the sheet offers
**Sync Through a Remote…**. A folder someone shared with you can't be shared on: only its owner signs its member list.

Removing someone from **Devices & People** also takes them out of the member lists of your folders and gives each a new
key for what's written from then on. What they already downloaded stays theirs.

### Receive a shared folder

1. Open their link (or scan their code). The folder shows in Folders as **_Name_ Shared “Folder”**.
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

With **Settings ▸ Sync ▸ Notify about conflicts** on (the default), Vault also shows a notification for a new conflict
and for a file edited here in a read-only folder, once each. Opening it opens the folder.

Every change is signed by the person who made it, and devices ignore changes from members who may only read.

## Edits made at once

When two devices that may write change a file at the same time, every device settles it the same way: an edit beats a
delete, text merges line by line when the edits don't overlap, and otherwise the later edit wins and the other becomes a
copy next to it, named after the other device's id and the time of its edit in UTC
(`Notes (conflict from <device id> 2026-11-11 143005).txt`).

## What the remote sees

- Your files, their names and paths, each device's change log and the folder's snapshots are encrypted with the
  folder's key before they're sent. Files go up in encrypted chunks whose names don't reveal their contents.
- The folder's member list is signed by the owner but not encrypted: it names each member with their public key and
  role, and holds the folder key sealed to each of them.
- The remote also sees each device's random id (the name of its change log), how many chunks and logs there are, their
  sizes and when they change.

## Not yet

- SFTP, SMB, iCloud and FTP remotes.
- Remote access for the people you share with travels outside Vault: you tell them the endpoint, bucket and keys.
- On iPhone and iPad, a synced folder lives in Vault's own place in Files; you can't pick another folder there yet.
- **Live changes from your Hub** in **Settings ▸ Sync**: folder changes come only with **Check remotes**.
