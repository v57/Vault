# Cards, Notes, Databases and Projects

Besides logins and SSH hosts, your vault holds cards, notes, database connections and projects. The other v57 apps
save most of these; Vault shows them all in one place.

## New items

**New Login…** opens a sheet whose **Kind** grid also makes the other kinds: **Login**, **Card**, **Note** and
**SSH Host**, plus **Database** and **Remote** on iPad and the Mac. Pick a kind, fill in its fields and click **Save**.

The sheet's header says where the item is kept: in iCloud Keychain on your devices, or in this device's keychain while
iCloud is off.

## Cards

Open **Cards**. Each row shows the card's brand (Visa, Mastercard, American Express or Discover when Vault recognised
it from the number, or the brand you typed), the last four digits and the expiry.

- Select a card to see its **Holder**, **Number**, **Expires** and **Security code**. The number and the code are
  hidden: **Show** reveals and **Copy** copies them, after the app lock.
- To add a card, choose **New Card…** from the New menu (or the button in an empty list), fill in **Title**,
  **Holder**, **Number**, **Expires** (MM/YY) and **Code**, and click **Save**.

## Notes

Open **Notes** to read the notes you keep in [Markdown](https://github.com/v57/Markdown/blob/main/docs/README.md) and
[Shell](https://github.com/v57/Shell/blob/main/Docs/README.md). Encrypted notes show a lock. Select a note to read its
text and word count. You can select and copy text, but notes are read-only in Vault: edit them in Markdown or Shell.

To write a quick note, pick **Note** in the New sheet's Kind grid, type a **Title** and the **Text**, and click
**Save**. It goes in a folder named Vault, and Markdown and Shell show it too.

## Databases

Open **Databases** to see the connections
[Database](https://github.com/v57/Database/blob/main/docs/README.md) and Shell saved: name (with a Production chip),
engine, server, the SSH host it goes through, and user. Search by typing in the toolbar.

Select a connection to see its host and port (or its file), user and **Password** (Show and Copy, after the app lock).
If it connects through an SSH host, the link opens that host.

On iPad and the Mac you can add a connection: pick **Database** in the New sheet's Kind grid, choose PostgreSQL, MySQL,
MongoDB or Redis, fill in the name, user, host and port, and click **Save**. Database and Shell see it at once.

## Projects

Open **Projects** to see the projects [Git](https://github.com/v57/Git/blob/main/docs/README.md),
[Code](https://github.com/v57/Code/blob/main/docs/README.md) and Dev keep. Each shows its icon, where it is on this
device (or **Not on this device**) and whether it's an Xcode project or a Swift package. Select one to see its folder
on each device and its remote URL. Projects are read-only in Vault.

## Deleting

Logins and documents have their own **Delete…** (see [Logins and AutoFill](Logins-and-AutoFill.md#delete-a-login) and
[Documents](Documents.md#delete-a-document)). Vault doesn't delete cards, notes, SSH hosts or database connections yet.
Delete a note in Markdown, a host in Shell and a connection in Database.
