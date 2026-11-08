# Devices and People

**Devices & People** in the sidebar's Keys section lists your devices and their keys, the people you share with, and
your identity for sharing.

## This device

The first card is this device:

- **Name:** **Rename…** changes the name your other devices and apps show. Leave it empty to use the system's name.
- **SSH key:** each device has its own SSH key, made in its Secure Enclave. It never leaves the device. **Copy** copies
  its fingerprint.
- **Signs:** a key made since November 2026 signs only after you confirm it's you with Touch ID, Face ID or your
  password, and a yes lasts 15 minutes in each app. An older key signs with nothing asked; the card says so.

## Your other devices

**Your other devices** lists each device that runs a v57 app on your Apple Account, with its platform, key fingerprint,
when it was last seen, and whether it's up to date. Touch and hold (or right-click) a device for **Rename…** and
**Lost Device…**.

**Settings ▸ Devices** on iPhone and iPad (and **Settings ▸ Remote** on the Mac) lists the same devices with how many
projects each has, and **Remove…** for a device you no longer use. Removing only tidies the list: the device comes back
if it runs a v57 app again. To cut a device off, use Lost Device.

### Devices without iCloud Keychain

Linux, Windows and Android devices don't have iCloud Keychain. To bring one into your vault, click **Add Device…**
under **A device without iCloud Keychain**. The **Add a Device** sheet shows a QR code and a link. Scan the code, or
open the link, in the v57 app on that device.

### Devices on your Hub

With a Hub connected, a row shows how many devices are on it and how many wait to join. Tap it to open the
[Hub](Hub.md) screen.

## A lost or stolen device

Touch and hold the device and choose **Lost Device…**. The sheet walks you through five steps. Each runs only when you
click it, and you can skip or try any step again. **Done** closes the sheet.

1. **Remove It from Your Apple Account:** **Open…** opens your Apple Account's device page in your browser. Remove the
   device there, then click **I Removed It**.
2. **Stop Trusting It:** **Stop Trusting** takes it out of every v57 app, and it doesn't come back by itself. If you
   own a Hub it's on, **Revoke** stops the Hub letting it in at once.
3. **Take It Off Your Servers:** for each server where you accepted its key, **Take Out** signs in with this device's
   key and removes the lost device's line from the server's `authorized_keys`. **Take Out of All** does them one after
   another. On the Mac, **This Mac** removes its lines from the Mac's own file. Servers you never accepted it on aren't
   contacted.
4. **Make a New Vault Key:** **Make New Key** seals every record again with a new key. The lost device keeps what it
   copied before but can't read anything new or write to your vault. Your other devices get the new key through iCloud
   Keychain, so iCloud has to be on. Do step 1 first, or the lost device would get the new key too.
5. **Change These by Hand:** lists the logins, passkeys, cards and saved passwords the device could read, so you can
   change them on their sites.

A device you stopped trusting shows under **Not trusted**. **Trust Again** lets it back in the next time a v57 app runs
on it.

## People

To share with someone, each of you needs an identity for sharing: a key pair of its own, kept in iCloud Keychain apart
from your devices' SSH keys.

### Set up your identity

Under **Your identity**, click **Set Up Sharing**. Vault makes your identity once and shows its **Signing** and
**Key wrapping** fingerprints. It's the same on all your Apple devices. On iPad and the Mac, **Show QR Code** shows your
invite.

### Invite someone

Click **Invite** (or **Invite…** in People). The sheet shows a QR code and a link. Let the other person scan the code,
or send them the link with **Copy Link**.

### Add someone from their invite

- Scan their QR code: **Scan Theirs** in a folder's **Share…** sheet, or **Join from Another Device…** on the welcome.
  On iPhone the camera fills the screen.
- Or click **Paste Link** with their invite link copied. Vault refuses a link that isn't an invite or was changed after
  it was made.
- Or tap their invite link in Messages or Notes: Vault opens and adds them.

The person shows under **People** as waiting until you compare codes.

### Compare safety codes

Select the person. Their **Safety code** shows as groups of digits. The same code shows on their devices. Compare them
in person or on a call you trust. If they match, click **It Matches**: the person shows as **Verified**. A different
code would mean someone swapped a key.

### Remove someone

Select the person and click **Remove…**, then confirm. They go from your People list.

Sending a folder or logins to someone comes in a later version of Vault.

## Let your devices sign in to a Mac

**On the Mac**, **Settings ▸ Remote** lets your other devices work on this Mac over SSH, without a Hub: Git, Code,
Shell, Database, Player and Get on your iPhone, iPad or other computers. Each device signs in with its own key, only
once you allow it.

1. Turn on Remote Login in System Settings ▸ General ▸ Sharing. While it's off, the pane says **Remote Login Is Off**,
   and **Open Sharing…** takes you there.
2. Turn on **Let Your Devices In**. This Mac then shows as a host on your other devices.
3. Under your devices, turn on **Can Sign In** for each device that may sign in.
4. Under **Apps on Your Devices**, turn on **Can Sign In** for Get or Player on a device, if you want them to reach
   this Mac. These apps don't hold your device's key: each signs in with its own, only to run a command or read files,
   with no terminal and no tunnels.

More on the pane:

- **Sign In with a Password** controls whether anyone who knows the Mac's password can sign in from the network. Off is
  the safest choice: your devices have their own keys and keep working. macOS asks for your password to change it.
- **Other Keys** lists the other lines in the Mac's `authorized_keys`, added by hand or by another app. Each can sign in
  as you. **Remove…** takes one out, and **Add Key…** adds a public key line.

In Devices & People on the Mac, **SSH from your devices** links to this pane.
