# Vault

The data the v57 apps share, as a small Swift package: projects (Git, Code, Dev, Markdown, Shell), SSH hosts and
the device's SSH key (Shell, Database), database connections (Database, Shell), known hosts, and encrypted
notes (Markdown, Shell). Every app on a device reads the same store, sees the others'
changes within a second, and syncs through the user's iCloud. Nothing in it is readable by other apps or other
users.

```swift
import VaultKit

@main struct MyApp: App {
  init() { Vault.shared.startSync() }  // iCloud sync, when the user is signed in

  var body: some Scene {
    WindowGroup { ProjectList() }
  }
}

struct ProjectList: View {
  @State private var vault = Vault.shared

  var body: some View {
    List(vault.localProjects) { Text($0.name) }   // live: changes from any app or device appear
  }
}

// Writing
try Vault.shared.store?.addProject(path: url.path, remoteURL: origin)
Vault.shared.save(VaultHost(name: "prod", hostname: "prod.example.com", user: "deploy"))
try VaultSecrets.setPassword(password, for: database.id)
```

## What each app declares

| Entitlement | Value |
|---|---|
| `com.apple.security.application-groups` | `$(TeamIdentifierPrefix)dev.v57` (macOS), `group.dev.v57` (iOS) |
| `keychain-access-groups` | `$(AppIdentifierPrefix)dev.v57.shared`; Vault and its AutoFill extension also `$(AppIdentifierPrefix)dev.v57.secrets` |
| `com.apple.developer.icloud-container-identifiers` | `iCloud.dev.v57` |
| `com.apple.developer.icloud-services` | `CloudKit` |
| `com.apple.developer.icloud-container-environment` | `Production`, in debug builds too |
| `com.apple.developer.aps-environment` (`aps-environment` on iOS) | `development` / `production`, for sync pushes |

Every app on a device shares one store, and an item one app sends is sent for all of them, so they all sync in
CloudKit's Production environment: a debug build left in Development would send the others' writes where none of them
looks. On the Mac, sync stays off in a build without it.

A build signed by another team, without these, still runs: the store falls back to the app's own Application Support
and keychain items, and sync stays off. A build with no application identifier at all (ad-hoc signed) can only reach the
old file keychain: a Debug build uses it, so it runs while being worked on, and a **Release build refuses**
(`VaultKeychain.isAvailable`; every keychain call throws), so a signing mistake is an error and not secrets quietly kept
somewhere weaker. It opens with no vault keys, device key or passwords. To run from source, use Debug or sign with your
own team.

**Off Apple platforms** nothing syncs through iCloud, and no group separates one app from another. Items of the secrets
group are kept under a service of their own, so they don't collide with anything, but any program of the user reads them:

| Platform | Where items go | Who can read them | When it isn't there |
|---|---|---|---|
| Windows | Credential Manager, per machine (`CRED_PERSIST_LOCAL_MACHINE`), encrypted for the user | Any program of the user | Calls throw (over SSH with a key it has no logon session) |
| Linux | Secret Service, the login collection (GNOME Keyring, KWallet, KeePassXC) | Any program of the user while it's unlocked; a locked one asks | Calls throw (no D-Bus session or keyring daemon) |
| Anything else (Android today) | No backend yet. Debug: a 0600 JSON file of base64 items. Release: nothing | The user, in Debug | Release calls throw `errSecNotAvailable` |

Neither Windows nor Linux falls back to a file. Hub's `HUB_DEVICE_KEY` and `~/.hub/device.key` are separate: see Hub below.

## How it works

**One store per device.** `VaultStore` is a SQLite file in the app group container (`Vault.v2.sqlite`, and
`<account id>.v2.sqlite` for each account). Each item is one row: an id, its kind, and its fields sealed with AES-GCM.
The table never changes shape. Fields live inside the payload, so an app that knows fewer fields than another (Shell's
view of a Database connection) keeps the ones it doesn't know. The one format change so far took a new file, because an
old build can't be asked to leave a row it can't read alone: see Payload format.

**Encryption.** The AES-256 keys are iCloud Keychain items in the shared access group `dev.v57.shared`, which only
the team's apps that list it can read. Other apps, other users and CloudKit see ciphertext. Each item names its key,
so a device can hold several: if two devices make the first key at once, both keys reach both devices and the one
with the smaller id becomes everyone's key for new writes. Passwords are separate iCloud Keychain items
(`VaultSecrets`; a demo run or a test keeps them in memory instead with `VaultSecrets.useInMemoryStore()`). Each
device's SSH key is a Secure Enclave key (`VaultIdentity`) shared by the apps on that device.

**Your Apple account is the root of trust**, as with Apple Passwords. Whoever gets into it, with a device the account
trusts, gets the iCloud Keychain, so the vault keys and every synced secret. Nothing here defends against that.

**A device key made since 2026-11-04 needs you.** It's made with `.userPresence`: the Secure Enclave won't sign with it
for a process that hasn't had Touch ID, Face ID or the password, on a device that has one set. `key()` and `signature` never ask, so
work in the background fails with `presenceNeeded`. A login the user started asks once it's settled the host key
(`presencePrompt`, run by SSHKit's `prepare`), Git's auto-fetch (`quietly`), Shell's redial and any app that isn't in front
don't. What each part gives:

| | Enforced by |
|---|---|
| With no yes, no process can sign with a key made this way, not even a bug in a v57 app, without showing the system's dialog | The Secure Enclave |
| A yes lasts 15 minutes, in the app that asked, and ends when the screen locks | This code, by dropping the system's `LAContext`. A bug inside that app, during its window, can sign, and a build that kept the context could sign for longer |
| Asking only when the user started something, and never from an app in the background | This code. A bug in a team app can show the system's dialog at any time; the user still has to say yes |

Each app has its own window. A key made before that date **keeps working with nothing asked**, and nothing here ever
replaces it: servers trust it through `authorized_keys`, so a new key would lock the user out of them. On those devices
any team app, or a bug in one, can still sign silently.

**Two keychain groups.** Logins' passwords, one-time codes, cards, passkeys, the personal identity and the digests' key
live in `dev.v57.secrets`, which only Vault and its AutoFill extension list (`VaultSecretTiers`). Connection passwords,
the vault keys, the device key, the GitHub token and the Hub keys stay in `dev.v57.shared`, because the apps that connect
use them. So another app's bug can't read a login's password through the keychain. It can still read the login's
record (title, website, username, notes), since those are sealed under the vault key every app holds, and an app can't
list these secrets, write them or delete them: it's told they aren't there.

`VaultSecretMove` moves what an older build left in the shared group. Vault runs it each time it comes to the front,
because a device on an old build keeps writing there and iCloud Keychain brings that in at any time. Each secret's old
copy goes only after the new one reads back. A login's password is `login.<id>` in the new group, and a `password.<id>`
whose record hasn't arrived stays where it is until it has, since connection passwords share that name. Two different
values under one name keep the later-modified one, by the source's date for a copy (`moved-date.<name>`, as the keychain
dates a copy when it's written), and every other value as `superseded.<name>`, then `#2` and on, up to 16 per name, past
which the old copy stays where it is. None is ever deleted, and the Vault app's Sync settings show them. The identity
already in the group always stays; a new build won't make one while there's a sign one exists (a mark the move leaves, a
kept value, a sealed copy in the recovery kit), because another device's move syncs item by item. Deleting an iCloud
Keychain item deletes it on every device, so an old build stops seeing what moved. Until Vault has run, what hasn't moved
is still in the shared group for every app to read.

An app outside the group that removes an account can't reach its logins' secrets, so Vault deletes them. No record can ask
for that, as every app can write any record: Vault keeps its own list per live account in the group
(`account-secrets.<account>`), and goes by it once Personal holds the account's tombstone, Personal and every live account
are settled (`VaultStore.isSettled`), and no other store holds the login.

**Merging.** Every field carries a hybrid logical clock (wall time, a counter, the device id). Merging two copies
of an item keeps each field's later write, so edits made on an iPhone and a Mac at once both survive unless they
changed the same field, and then every device keeps the same one. A delete is a write too, and loses to an edit made
after it.

A clock can be wrong, or stamped decades ahead on purpose by a device that still has a key. Refusing such a field on the
devices that notice would split them, so merging never looks at the wall clock: every device keeps the same field. What
the wall clock limits is this device's own clock: it follows clocks up to an hour ahead of it
(`VaultStore.clockSkewBound`) and ignores the rest, so one bad field doesn't push all later writes into the future. A
write always beats what it replaces: a field whose clock is ahead of this device's gets the next clock after its own, so
a device with a slow clock keeps its edits, a value stamped far ahead lasts until someone next edits that field, and a
store that remembered a far-future clock drops it at its next write. Someone with a current key can still win a field
against edits that hadn't seen their write, as they could by simply writing it, until `rotateKeys` refuses them; their
clocks stay on the fields they touched.

**No duplicates.** Ids come from content where there is one: a project is a keyed hash of its remote URL and
folder name, so the same checkout added on two Macs is one record. If two ids for the same thing appear anyway
(made before the keys synced), every device folds them into the one with the smaller id.

**Sync without a helper.** Every app runs its own `CKSyncEngine` against the `Vault` zone of the private database.
A write puts the item in the outbox and leases it to the app that wrote it, which sends it. If that app quits
first, the lease runs out and any other app sends it. Every app fetches, and the store skips records it already
has, so a change is sent once and applied once. A conflict merges the server's copy and sends the merge on top.

**Accounts.** One person can work for several organizations, each with its own teams, hosts and keys. Each account
(`VaultAccount`: name, color, role) keeps its records apart, never as a tag on them: passwords, projects, hosts, configs
and settings live in its own store file (`<account id>.sqlite` beside `Vault.sqlite`), CloudKit zone
(`Vault-<account id>`) and Hub mailbox (`hub-vault:<account id>`, derived like Personal's `hub-vault`). Every account
seals with the same vault keys as Personal, and the device's SSH identity is shared too. The account records live in
Personal, which is today's vault unchanged, so `Vault.shared` is still Personal. `Vaults.shared` lists the accounts and
opens a `Vault` per account on first use; an account's store opens before its record has arrived. CloudKit allows one sync engine per database, so each app's engine carries
every zone, and `SyncZones` routes each zone to its store. `Vaults.account(forTeam:)` and `account(forGitHubOwner:)`
find the account that holds a project's `DEVELOPMENT_TEAM` (`VaultAppleTeam`) or GitHub owner (its projects' remotes),
trying the organizations before Personal. Deleting an account removes its zone, Hub mailboxes, its records' passwords
and other secrets, its store and its record, and nothing of Personal; other devices drop their copy when the record's tombstone or the zone's deletion arrives.

**Profiles.** Who the user is in each account (`VaultProfile`: name and email) goes on their commits, their keys'
`authorized_keys` comments and their Hub. Profiles live in Personal beside the accounts (id `profile.<account id>`,
since a store's ids are unique across kinds), so every app sees every account's. `Vaults.profile(for:)` gives an
organization's account Personal's name when it has none, never its email: a client's commits go out with the client's
address. `suggestedProfile(for:gitHub:)` prefills the Your Name sheet from Personal's, git's global configuration
(`GitGlobalIdentity`, read from the files, no git process), the GitHub sign-in the caller passes, and the Mac user's
full name. VaultUI's `VaultProfileSheet` (Your Name) asks for them, shown by the first app that needs them, and Settings
▸ Accounts (`VaultAccountsSettings`) has a Your Name row per account. Apps hand the profile to the tools they run,
never to the user's files: the terminal and agents keep their own setup. An app that can also write them somewhere
asks first: `VaultProfileOption` adds a switch (off) to the sheet, or a confirmation when the profile is already saved
(`VaultProfileRequest.answer(for:option:)`; Git's "Use in Terminal too").

**Device names.** `VaultDevice.name` is how every app names this device: on the Hub (each connection's certificate;
`HubDirectory` connects again after a rename), on its SSH key's comment, on the `authorized_keys` lines Vault writes
(`removeStale` renames them) and on the host other devices see. It is the name the user gave it
(`VaultDeviceKey.customName`, set with `Vault.renameDevice`, from any device; `VaultDeviceNameSheet` in Settings ▸
Accounts and the Vault app's Devices), else the system's. The Personal vault hands the device its name when it loads
and republishes its key with it.

**Project tree.** Projects sit in groups that nest (`VaultProjectGroup`), so every app's sidebar can show the same
arrangement on every device. A project's place is its `groupID` and `order`, a group's its `parentID` and `order`;
groups and projects share one order. `VaultProjectTree` builds the tree from the records alone, the same way
everywhere: an item whose group is gone sits at the top level, and a loop (two devices moving two groups into each
other at once) breaks at the group with the smallest id. Change it through the store (`moveProjects`,
`addProjectGroup`, `groupProjects`, `ungroupProjects`), which renumbers the items it touches and deletes the groups a
move leaves empty. `filter` gives what one device shows (`Vault.localProjectTree`). Collapsing a group is each app's
own state.

**Project kinds.** A project notes what its folder holds (`VaultProject.Kind`: `xcode` for an `.xcodeproj` at the top
or one folder down, `swiftPackage`), one `kind.<name>` field each, so an app can pick the projects it works on (Dev
lists only Xcode projects). `addProject` detects them, and `refreshProjectKinds` looks again at this device's
folders and saves only what changed. A project's `icon` is a small PNG of its app icon (at most 64 KB) that every app can show, even
where the folder isn't: an app that can find icons (Code's `ProjectIcon`) passes its finder and thumbnailer to
`refreshProjectIcons`, which makes it again only when the source file's hash (`iconSource`) changes.

**Live updates.** Every write posts a Darwin notification, and `Vault` reloads in every app on the device.

**Notes.** A note is a record (`VaultNote`: folder, name, text, and whether its local file is encrypted). It syncs like
everything else, encrypted titles included, with no need for iCloud Drive. Text that two devices edited at once merges
line by line (`TextMerge`) against the server copy both started from (the store keeps the last server copy of each
item), the same way on every device; lines both changed stay twice, between conflict markers.

On each device Markdown keeps the notes as files in a local folder: `NotesMirror` reconciles the folder and the
records both ways, so Finder, Files, other editors and git work on them. Each file carries its note's id in an
extended attribute (recovered from the last known path when an editor's atomic save drops it), and an index of the
last pass tells which side changed; edits on both sides merge against the last synced text. An encrypted note is
`Name.mdenc` on disk (`EncryptedNote`, only the v57 apps read it), a plain one `Name.md`. Other files, like images a
note links to, sync as `VaultNoteFile`. Shell edits the records directly. `NoteConflicts` still merges iCloud Drive
conflict versions of notes in folders the user adds to Markdown.

**Encrypted folders.** The `VaultFiles` library keeps whole folders encrypted, names included, so a folder can
sit on any disk or remote and show only ciphertext there. Each folder has its own key (`FolderKey`), which the vault
keeps wrapped by the vault key in the folder's record. A file is sealed in 64 KB chunks (`EncryptedFile`, like age
or Tink's streaming AEAD): it streams in and out, any range reads without decrypting the rest, and changed,
reordered or truncated chunks fail to open. Each file's chunks are bound to its place (its folder's id and its name),
and so is each folder's sealed id, so someone who can write to the disk but has no key can't swap files or folders or
move one elsewhere: it fails to open, and `move` re-seals for the new place (format 2; format 1 never shipped and is
refused). Names are encrypted deterministically under their parent folder's
random id, so paths resolve without an index and renaming a folder rewrites one name (`NameCipher`).
`EncryptedFolder` lists, reads, writes, moves and removes by plaintext path. For tools that can't read it (git,
Xcode, other apps), `DecryptSession` decrypts a working copy, hidden from Spotlight and backups, seals changes back
when the app asks (or as they happen, with `FolderWatcher` on macOS), and deletes the copy when it locks; copies a
crash left behind are sealed and deleted at the next launch.

**Folder sync.** `VaultSync` keeps a folder in sync across devices and people through a remote that is only plain
storage (S3, SFTP, a disk: any `RemoteFileSystem`), with no server, locks or change notifications. The remote copy is
always encrypted, whether a device keeps its copy as plain files (`PlainSyncFolder`) or encrypted
(`EncryptedSyncFolder`). At the folder's place on the remote: `members`, the owner-signed member list (each member's
keys and role, and the folder key wrapped to each, in epochs that rotate when someone is removed: `FolderMembers`);
`chunks/<id>`, content-addressed encrypted chunks written once (the id is a keyed hash, so they dedupe and say
nothing); `log/<device>/<n>`, each device's own change log, which only it appends to; and `snapshots/`, compacted
state for new devices. Each change names the file, its chunks, a hybrid clock and the versions it replaces, and is
signed by its author: changes from people without write access are ignored. Every device resolves a file's
concurrent edits the same way: an edit beats a delete, text merges line by line against the common ancestor when
it merges cleanly, and otherwise the later write wins and the other becomes a conflict copy; a read-write device
then writes the resolution back, so the file has one version again. A read-only device receives only: its edits
stay "changed here", and when the remote changes one of them the user picks Keep Mine or Revert to Remote. The app
drives `FolderSync.sync()` (on open and on a timer); local changes are found by scanning against the last index.
Chunks nothing references are deleted after a grace period, and log files once a snapshot covers them.

**Recovery key.** Optional and off until the user makes one (`VaultRecovery.create`); nothing in VaultKit
prompts or reminds, `isOn` is the only state. The user keeps a random 256-bit secret, shown once as 24 BIP-39 words
or 14 groups of base32, both with a checksum, and as a QR code on a printable kit (`RecoveryKit`, `V57R1:…`).
Devices keep only the X25519 public key derived from it (HKDF), so any device seals a new vault key, identity or
folder key to it (HPKE) without the secret: one `VaultRecoveryBlob` record per key, synced like everything else but
sealed with a key derived from the recovery public key instead of the vault key, so a device that lost the vault
keys can still read them. A synced folder's remote keeps its folder keys' blobs too, in `<folder>/recovery/` next to
`members`, so the folder comes back with only the remote and the kit. `recover` opens every blob with the typed or
scanned kit, and `restore` writes back what it can vouch for: a vault key only if it opens a record here (or a record's
history names it), and never as the current key, because a blob is sealed with the public key alone and says nothing
about who sealed it. A new key is made and rotated to instead, which retires every restored key. Identity and secrets are written
only where this device has none. `replace` makes a new kit, deletes the old blobs and rotates the vault key, so an old kit
gets nothing newer than what it already held; `turnOff` deletes them everywhere.

The kit also covers the keychain's secrets: logins, one-time codes, cards, passkeys, saved connection passwords and
imported SSH keys (`VaultSecrets`). Each is sealed to the recovery public key, never to the vault key, because every
app reads the vault key and these are for the kit alone. They follow every change, and a deleted secret's box is
emptied before its tombstone syncs. Only Vault and its AutoFill extension see every secret, so only they check the boxes
against the keychain (`seesEverySecret`); another app seals what it changes itself, without a digest, and Vault adds that
later. `superseded.` copies aren't covered, though a recovery that opens several identities takes the oldest and keeps the rest as those. Not covered: device SSH keys (they never leave their Secure Enclave), Hub keys,
the GitHub sign-in, and what Shell keeps in its own keychain service.

**Payload format.** A record's payload is `"V57I" 0x02`, its key's id, then its kind and its fields in two AES-GCM
boxes, both bound to the store (`accountID`, or `personal`) and the record's id, and the fields to the kind too
(`VaultItemSeal`). So a payload copied to another record, kind or store fails to open. The version lives in the payload
because the schema never changes.

Format 2 has its own file, and the old file (`Vault.sqlite`, `<account id>.sqlite`) is never written. Old builds keep
opening it and never meet a format 2 row, so an old app on an updated device can't store one over its own copy, send
one up with a key id, or see an empty store and trash note files. It's also the backup: removing the new file migrates
again from it. It stays until the store is removed (ciphertext under the old keys, at the size it was).

A store builds the new file on open, in whichever app opens first (`VaultStore+Format`). A temporary file with a unique
name gets every row with its clocks and fields exact, each format 1 row sealed again and read back. It's forced to disk
(`wal_checkpoint(TRUNCATE)`, `F_FULLFSYNC`) and moved into place without overwriting, so a kill or a power cut leaves the
old state or the new one, and two processes get one winner. The file being there means migrated. A row whose key hasn't
arrived, or that won't rewrite, comes over as it is on a sealed list, is counted, and never stops the rest; `catchUp`
moves it when it can, and it never goes up in format 1. Until the keychain can be read and has a key, the store reads
the old file and doesn't sync. A save on a keychain with no keys at all makes a key, as it always did, because a save
that failed would lose what the user typed, and ids wait until the vault's id key is here.

An old app on an updated device can't reach the new file, so for 30 days from the store's migration each open merges in
what it wrote: the old file's rows with outbox entries, which are local edits it couldn't send, and fields stamped by
this device since the migration, as it can send some of them. `catchUp` does too, and so does a local write when the old
file has changed, so an old edit stamped ahead by a fast peer merges before a later edit gets its clock. What it fetched
from CloudKit stays behind, and what it wrote under a retired key is refused. With the keychain out of reach, so that this
process's device id is made up, it waits for the next launch. After the 30 days the old file is ignored, so update every
v57 app on a device within that time.

A store reads format 1 from CloudKit and Hubs during its own first complete fetch after migrating, so a v1 edit waiting
on the server merges by clock rather than being overwritten, and only within 30 days of a vault-wide mark. The mark is a
synced keychain item holding the date the first device migrated, out of CloudKit's reach; if two devices set one, every
device counts from the earliest. A store finishes when that fetch completes, by its own zone's completion event, not on a
timer: an offline one stays unfinished rather than refusing what it hasn't seen, and an engine starts from nothing until
then. A format 1 copy waiting for its key beside a row holds it up too, as it would be refused when the key came. Past the
30 days it finishes as soon as it opens. A device with no CloudKit counts a Hub pull as that fetch. An Apple ID switch
starts this again on the new account, within the 30 days.

After that, format 1 from elsewhere is refused. The record stays on the server with its tag untouched, since it's its
writer's copy and comes back when that device migrates; a local edit may still go up over it as a normal conflict. Each
refusal is counted once per id across restarts and apps, and goes when a record the store can read arrives there, and
the Vault app's Sync settings say so (`VaultFormatStatus.note`). A device that never updates leaves its later edits on
the server and on itself.

Only an authentication or format failure refuses. A keychain out of reach or a busy database leaves the row and its tag
untouched: reads throw, and a fetched record waits in the store (`engines`, `retry:<id>`) for `catchUp`, because the sync
engine's position has already moved past it. A store doesn't finish with one waiting. A record whose asset couldn't be read
waits there too, for a month at most, and asks for a full fetch, which is what can bring it back. An old tombstone is purged
only by a finished store, and not while the server's record at that id is one it refused, as the delete would take that too.

Format 2 CloudKit records carry no `keyID` field, so an old build on another device skips them rather than storing them
over its copy (given a key id it would blank the row). A device that migrates later re-sends every row, which converges
through the field merge, and asks Hub members to send theirs again.

**CloudKit deletions.** They can't be authenticated, so they get less trust than the records. A row dropped by one leaves
the highest clock it held (`meta`, `hw.<id>`), and a payload at or below it is refused until something later arrives, so a
delete followed by a replay can't roll back a host pin. A device that has never held the record has no such clock.
Revocations are marks in the synced keychain (`revoked.<store>.<device id>`), with the record staying for display, so a
deleted record un-revokes nothing; a revocation an old build makes after a store's migration has only the record. A
record deleted elsewhere can come back from a device that was offline for about 30 days, when its tombstone is purged.
That's left as it is, because deleting data on a misread `.unknownItem` is worse. On a device that dropped it, it's
refused if nothing in it is newer, and a resurrected device key still doesn't trust a revoked device.

**Key epochs.** The current key is an explicit claim in the synced keychain next to the keys: `keyepoch.<n>.<id>`
names the key and the keys it retires (`VaultKeyRing`). It's there and not in CloudKit because whoever can write
CloudKit records must not be able to choose the key. The highest epoch wins, then the id, so concurrent rotations
converge. A vault that never rotated has no claim, and its smallest id is current with nothing rewritten. `derivedID`
hashes with a synced id key (`idkey`), made once from the same key as before, so ids don't change now or at a rotation.

`rotateKeys` adds a key, seals every row and folder key under it in every store, and from then on anything under a
retired key is refused; a device that hears of a rotation does the same (`catchUp`). Retired keys stay in the keychain
for the notes and backups under them. A rotation doesn't reach `.mdenc` files until their next write, or Linux, Windows
and Hub-only devices, which have no iCloud Keychain. **iCloud Keychain gives a new key to every device in the Apple
account, so a rotation keeps out only a device that has left it.**

**Lost Device.** `VaultLostDeviceSheet`, in the order that works: (1) remove it from the Apple account, which only the
user can do; (2) `revokeDevice` plus each Hub; (3) take its lines out of `authorized_keys`, here and over SSH on each
server the user clicks; (4) `rotateKeys`; (5) a list of secrets to change by hand. Each step runs at its click and can
be skipped or tried again. A `VaultRevokedDevice` record keeps it out: what it publishes is ignored and it shows as not
trusted until the user trusts it again. Plain Remove only tidies up, and a device running a v57 app comes back.

**Hub.** `VaultHub` (a library of its own, so VaultKit doesn't depend on Hub) connects this device to the user's own
Hub (`~/Developer/Hub`, wire contract `Docs/Devices/protocol.md`). Nothing connects until the user adds one: a
`VaultHubServer` record (address, pinned Hub key) that each device turns on for itself (`connects.<device>`); the apps
never pick a Hub, the v57.dev playground included, and the UI calls that one a playground. The device key never leaves
the device: a this-device-only item in the v57 keychain group, where the Hub app puts its own key, so the Hub app and
the v57 apps are one device with the Hub app's approvals and Hub Network address. On the Mac, until the Hub app has,
the apps use `~/.hub/device.key`, the file Hub's launcher and services use. Each connection signs a 7-day certificate for the
key the apps connect with, pins the Hub's key from `hub/info` and uses v1 auth from then on. `HubDirectory` follows
`hub/devices` and mirrors every approved device that offers SSH and has a Hub Network address into a `VaultHost` with
a `hub` route (`HubRoute`: device id, name, platform, the host key the device signed, last seen to the hour). The
host key is trusted for every app (`VaultKnownHost`) only when the device's own key signed it (`ssh1:<hostKey>`).
A pin belongs to a route as well as an address (`VaultHost.pinRoute`: Hub and device, this device's device record, or
the host's id for a `.local` name), so two Hubs' overlay addresses and repeated `.local` names keep their own pins, and
a Hub's trust reaches only its own routes. Pins from before routes stay readable until the route has its own.
A revoked or removed device's host and its trust go on the next update. The mirror's updates keep what the user
set on a host, such as `buildSigning`: how builds that Code starts there over SSH sign, since the login keychain stays locked
in an SSH session. Other apps read these hosts through VaultKit
alone (`Vault.hubHosts`, `VaultHost.isViaHub`), so they never link Hub. Owners also see `hub/devices/pending` and
approve with the safety code, which Vault computes from the key rather than trusting the Hub's.

**Macs without a Hub.** A Mac can let the user's devices in over plain SSH (the Vault app's Devices ▸ SSH from your
devices, off until turned on): it publishes itself as a `VaultHost` with a `device` route (`DeviceRoute`: its vault
device id, its Bonjour address, the host key from its own `/etc/ssh`, trusted for every app, and the devices it
allows), so `Vault.otherPlaces` finds its projects' folders there when no Hub reaches it. Each device is allowed by
hand: its `VaultDeviceKey` goes into `~/.ssh/authorized_keys` with a `v57-device=<id>` comment (`VaultAuthorizedKeys`),
which only Vault's own lines carry. A device that's gone or has a new key loses its line whenever a Mac app reloads
the keys, and a new key is never allowed by following the vault. The hostname follows the Mac's address until the
user sets another (a Tailscale name, say). These hosts, like the Hubs, are Personal's: an account's vault finds them
through `personalVault`.

**Record sync over Hub.** `HubSync` (VaultKit, next to `CloudSync`) syncs the records through the Hub's `hub-vault`
service (`~/Developer/Hub/Services/hub-vault`), for devices without iCloud, when a device turns it on for a Hub
(`syncs.<device>`, off by default). Each sealed item goes up as an envelope when its version changed since it last
went up; the Hub keeps envelopes until every other member device acknowledged them and never has a key. Envelopes
from other devices merge field by field (`VaultStore.applyFromPeer`), without touching CloudKit's bookkeeping, and a
change goes into the outbox so a device with both carries it to iCloud. HubSync keeps its own account of what it sent
(engine state `hub-sync:<device>`), so CloudKit's outbox stays CloudKit's. A new member, or a device that missed
envelopes, makes every device send everything again. The vault's mailbox id is derived from the vault keys. Tested
with a fake mailbox (`HubSyncTests`) and live against hub-pro and hub-vault (`HubRecordSyncLiveTests`, `HUB_E2E_PORT`).

## With and without the sandbox

The apps share code between sandboxed builds (iPhone and iPad, the App Store) and ones without the sandbox (a Mac
direct download). `AppSandbox` says which at run time and where the app keeps its data: the container's Application
Support and Documents in the sandbox, `Application Support/<bundle id>` (and `Documents` in it) on a Mac without it,
since the user's own folders are every app's. `AppSandbox.carryOverContainer()`, first thing at launch, copies a
sandboxed build's settings, Application Support and Documents from its container once. `FolderGrants` keeps the
folders the user let a sandboxed Mac app open (security-scoped bookmarks, a folder inside a granted one too), and
VaultUI's `VaultFolderAccess.request` opens a folder: as it is without the sandbox, else with a grant, else after the
open panel, which starts on the folder around the app's projects so one pick opens them all.

## Turning iCloud off

Settings ▸ Privacy in every app that syncs has one switch (`VaultICloudCard`, in VaultUI), for every v57 app on the
device: they share one store, so an app still syncing would send what the others wrote. `VaultICloud` keeps it as a file
beside the store, never in a record, so each device decides for itself. A run with secrets in memory has its own.

While it's off:

- `CloudSync` runs no engine and asks CloudKit nothing, not even for the account's status, and registers for no pushes.
  It follows the switch live, in every running app. Writes wait in the outbox, and the engine's state stays in the store,
  so turning it on again sends what waited and fetches what it missed. A Hub's sync isn't iCloud and carries on.
- `VaultKeychain` keeps synced items in a twin service on this device only (`<service>.icloud-off`), and reads the twin,
  then the synced item. The first call for a service with iCloud on again moves the twin back, unless the synced item
  changed later on another device. `KeychainTokenStore` does the same for the GitHub sign-in. Deleting deletes both.
- What's already in iCloud stays there. Deleting it would take it from the user's other devices as well, so the switch
  doesn't. The system still brings in what other devices change in iCloud Keychain, and a key made here while it's off
  (a first key, a rotation) doesn't reach them until it's on again.

## The Vault app

`Vault/` is a Mac and iPad app on VaultKit and VaultFiles (`Vault.xcodeproj`, bundle `dev.v57.vault`; build it against
the checkouts next to this one with `Vault-Local.xcworkspace`). It imports only SwiftUI, ComponentKit, VaultKit,
VaultFiles, VaultHub and VaultUI, plus UpdateKit on the Mac. Each window shows one account (`VaultAccountScope`, the
picker first in the sidebar, Settings ▸ Accounts to make, rename and delete them); `--demo` has none. It shows the
records every v57 app already shares (logins, cards, notes, SSH hosts, databases, projects, devices) and the newer
pieces: encrypted folders with timed decryption for other apps, people and safety codes, remotes, and the user's own
Hubs (`VaultHub`: connect per device, the devices with presence and SSH, approvals with the safety code, revoke). What VaultKit doesn't do yet is drawn against protocols in `Vault/Engine/`
(`FolderSyncEngine`, `RemoteService` backends, `RecoveryService`; `HubEngine` is live, with a demo), each saying plainly what isn't there yet.

`--demo` opens a demo vault in a temporary folder: in-memory keys, secrets and identity, real encrypted folders, and
sample data only for folder sync and remote listings. It never touches the user's vault. Other launch arguments
(`--select logins|hosts|hub|folder:<name>|…`, `--login`, `--host`, `--person`, `--hub-device`, `--sheet decrypt|share|new-login|add-remote|add-hub`,
`--welcome`, `--waiting-for-keys`, `--settings`, `--settings-pane`, `--dark`, `--light`) open any screen;
`.dev/screenshots.json` lists the screenshot scenes.

## Layout

| Folder | What |
|---|---|
| `Core/` | `JSONValue`, `HybridClock`, `ItemFields` (the merge), `VaultConfiguration` (identifiers) |
| `Keys/` | `VaultKeychain` (shared group), `VaultKeys` (AES keys, sealing), `VaultIdentity` (SSH key, `PresenceGate`), `VaultSecrets`, `VaultSecretMove`, `VaultDevice`, the recovery key (`VaultRecovery`, `RecoverySecret` and `RecoveryWordList`, `RecoveryKit`, the `VaultRecoveryKey` and `VaultRecoveryBlob` records) |
| `Store/` | `VaultStore` (SQLite, outbox, merging records in), change notifications, `VaultFieldChange` (each field's last write: when, which device) |
| `Records/` | Typed records: `VaultProject`, `VaultProjectGroup` (with `VaultProjectTree`), `VaultHost` (with its `HubRoute` and `DeviceRoute`, and `VaultDeviceHost`'s publishing), `VaultKnownHost`, `VaultDeviceKey`, `VaultHubServer` (with `VaultHubDevice` and the mirror), `VaultDatabase`, `VaultNote`, `VaultNoteFile`, `VaultLogin`, `VaultCard`, `VaultFolder`, `VaultRemote` |
| `Sandbox/` | `AppSandbox` (sandboxed or not, the app's data folders, carrying a container's data over), `FolderGrants` (remembered folder access) |
| `Remote/` | `RemoteFileSystem` (list, stat, read range, write, rename, delete), `MemoryRemoteFileSystem`, `LocalRemoteFileSystem`, `S3FileSystem` (AWS S3, R2, B2, MinIO; `AWSSignatureV4`, an injectable `S3Transport`), `RemoteConnections` (the file system for a `VaultRemote`) |
| `Sharing/` | `PersonalIdentity` (X25519 + Ed25519, one per person, `VaultPersonalIdentity`), `PublicIdentity` (`v57id:`), `SafetyCode`, `KeyWrap` (a key sealed to a person), `VaultPerson`, `VaultInvite` (`v57vault://invite`) |
| `Sync/` | `SyncCoordinator` (the sync rules, testable), `CloudSync` (the `CKSyncEngine` adapter) |
| `Passwords/` | `OneTimeCode` (TOTP/HOTP, `otpauth://` URLs), `Base32`, `PasswordGenerator`, `PasswordStrength` |
| `Passkeys/` | `VaultPasskey` (a site's P-256 key in `VaultSecrets`, joined to the login for the same account), `WebAuthn` (authenticator data, "none" attestation, ES256 signatures) |
| `AutoFill/` | `VaultAutoFill`: which logins fit a site, and publishing logins and passkeys to the system's list for the `VaultAutoFill` extension (passwords, one-time codes, passkeys) |
| `Notes/` | `NotesMirror`, `EncryptedNote`, `NoteConflicts`, `NoteBaseCache`, `TextMerge` |
| `VaultFiles/Format/` | `EncryptedFile` (chunked file format, `EncryptedFileReader` for ranges), `NameCipher` and `DiskName` (encrypted names, long-name sidecars), `FolderSubkeys` |
| `VaultFiles/Folder/` | `FolderKey` (wrapped by the vault key), `EncryptedFolder` |
| `Vault/` | The app: `App/` (model, window), `Sidebar/`, `Items/` (logins, hosts, databases, projects, cards, notes, New), `Folders/`, `Locations/`, `Keys/` (devices, people), `Settings/`, `Welcome/`, `Engine/` (folders on VaultFiles, people, the protocols), `Demo/` |
| `VaultFiles/Session/` | `DecryptSession` (temporary decryption, crash recovery), `FolderActivity` (progress for the UI), `FolderWatcher` (macOS) |
| `VaultHub/` | Hub as a backend: `HubKeys` (Ed25519 in Hub's encodings, `HubKeyStore`), `HubWire` (the protocol's types, auth and certificate headers), `HubConnection` (one Hub: status, devices, pending, approve and revoke), `HubDirectory` (the Hubs this device connects to) |
| `VaultSync/` | Folder sync over plain storage: `FolderSync` (the engine, an actor the app drives), `FolderSyncStatus` (for the UI), `FolderMembers` (signed member list, key epochs), `ChangeLog` (changes, log files, snapshots, the remote layout), `SyncLocalFolder` (plain or encrypted local copy), `SyncState` (each device's index) |

`swift test` runs the merge, store and sync tests. The sync tests use a fake CloudKit (`Tests/.../FakeCloud.swift`)
with several devices and several apps per device.
