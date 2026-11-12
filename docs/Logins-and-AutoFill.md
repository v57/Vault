# Logins and AutoFill

A login holds a website's or an app's username and password, and can hold a one-time code and a passkey. Every v57 app
and AutoFill can use it.

## Find a login

Open **Logins** in the sidebar. The list is sorted by name. Each row shows the username and the website, with icons for
a linked item, a one-time code and a passkey.

- **Search:** type part of a title, username or website. On iPhone the search field is in the bottom bar; on iPad and
  the Mac it's in the toolbar.
- **Filter:** **All** shows every login. **With Codes** shows the logins that have a one-time code.

The status line under the list says where your logins are kept: synced through iCloud, or on this device when iCloud is
off.

## See a login

Select a login. On iPad and the Mac it opens in the inspector; on iPhone its page opens.

- **Sign-in** shows the **Username**, the **Password** (hidden), the **One-time code** with its countdown, and the
  **Website**. Tap the website to open it in your browser.
- **Linked** shows the host, database, folder or project the login belongs with. Tap one to open it.
- **Changes** shows when the password, one-time code, username and website last changed, and on which device.

## Show or copy a password

- **Show** in the password row reveals it. **Copy** copies it.
- **Copy Password** in the action bar (iPad and Mac) or the bottom bar (iPhone) copies it at once.
- On iPhone, the **…** menu has **Copy Username**, **Copy Code** and **Copy Website**.

The app lock asks for Touch ID, Face ID or your password first, unless you unlocked in the last five minutes.

A copied password or code stays on this device: it doesn't go to your other devices' clipboards, and clipboard managers
skip it. A copied password is cleared after 90 seconds, and a copied code when it expires, unless you copied something
else since.

## Make a new login

1. Click **+** in the Items section, or choose **New Login…** (⌘N).
2. Fill in **Title**, **Website** and **Username**.
3. Vault fills in a generated **Password**. Click **Generate** for another one. The meter under the field shows how
   strong the password is, and changes as you edit it.
4. Add a one-time code if the site gave you one (see below).
5. Under **Link to**, pick the host, database or folder this login belongs with.
6. Click **Save**.

**Generate** in the Logins toolbar (iPad and Mac) or bottom bar (iPhone) also opens New Login with a fresh password.

## Edit a login

Select the login and click **Edit**. The **Edit Login** sheet opens with its values. The saved password stays hidden
until you click **Show**, which asks the app lock first. Change what you need and click **Save**.

## Delete a login

Choose **More ▸ Delete…** in the login's inspector (iPad and Mac) or the **…** menu on its page (iPhone), then
**Delete**. The login is deleted with its password, one-time code and passkeys on all your devices. This can't be
undone.

## Add a one-time code

When a site sets up two-factor authentication, it shows a QR code or a setup key. In New Login or Edit Login:

- **Scan Code** (iPhone and iPad) opens the camera: over the whole screen on iPhone, with **Cancel** at the top, and
  in the sheet on iPad. Point it at the QR code. Once it reads a setup key the camera closes; a QR code that isn't a
  setup key gets a note, and the camera keeps looking. The first time, the system asks to let Vault use the camera.
- **Scan Screen** (Mac) finds the QR code on your screen.
- **Paste Key** reads a copied setup key or `otpauth://` link. If the clipboard holds none, Vault says "The pasteboard
  has no setup key."

Once it's read, the **One-time code** row shows the live digits. Click **Save**.

## Passkeys

A passkey signs you in to a site without a password. Vault saves passkeys through AutoFill (see below) and joins each
one to the login for the same site and account.

- A login with a passkey shows a **Passkey** row with the site and the date, and a key icon in the list.
- To remove a passkey, click the trash in its row, then **Remove**. The login and its password stay. The passkey is
  removed on all your devices.

## AutoFill

Vault fills passwords, one-time codes and passkeys in Safari and other apps. Turn it on once in the system settings:

- **On iPhone and iPad:** Settings ▸ General ▸ AutoFill & Passwords, then turn on Vault.
- **On the Mac:** System Settings ▸ General ▸ AutoFill & Passwords, then turn on Vault.

**Settings ▸ AutoFill** in Vault says whether the system offers Vault in password fields. While it's off,
**Turn On…** opens the system's AutoFill & Passwords settings; once it's on, **Settings…** opens them. The pane reads
the state again when you come back to Vault.

Open Vault once after turning it on, so it can tell the system which logins it has.

### Fill a password

- Tap Vault's suggestion above the keyboard (or in the field's menu on the Mac). It fills at once.
- Or choose Vault from the passwords button. A list opens with the logins for that site first, then **Other logins**,
  with a search field. Tap a login to fill its username and password. **Cancel** fills nothing.

### Fill a one-time code

In a site's code field, choose Vault. It lists the logins with codes, and fills the current code of the one you tap.
This needs iOS 18, iPadOS 18 or macOS 15 or later.

### Save and use a passkey

- When a site offers to make a passkey, choose Vault, then **Save**, and confirm with Touch ID or Face ID.
- When you sign in, Vault offers its passkey for that site. Confirm with Touch ID or Face ID.
- A site you already have a passkey for with the same account doesn't get a second one.

### The app lock in AutoFill

AutoFill follows the [app lock](Privacy-and-Security.md#the-app-lock). If you unlocked Vault in the last five minutes,
it fills at once. Otherwise it asks for Touch ID, Face ID or your password first.
