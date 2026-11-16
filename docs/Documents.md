# Documents

Keep passports, ID cards, insurance policies, contracts and other papers in your vault: Vault reads the pages on your
device, fills in what it finds, shows what runs out soon and makes redacted copies to send to someone.

Pages are read on this device and encrypted before they're saved. See [How documents are kept](#how-documents-are-kept).

## The library

Open **All Documents** in the sidebar's Documents section. The section's header counts the documents and says how many
have a reminder that has come (**to renew**).

- **Coming Up** lists the documents with a date in the next 90 days, or whose reminder has come, with the time left. A
  date stays there for 30 days after it passed. With documents waiting in the Inbox, a row counts them, with **File…**.
- Then a section per collection (Identity and the others), with **Show all** when there are more than four.
- **Inbox** holds documents not filed in a collection yet, such as the ones you shared to Vault from another app. It
  shows in the sidebar only while it has something in it.

Each card shows the first page, whose document it is, the date it ends and a badge with the days left.

- **Filters:** **All**, **Coming Up** and **Recent** (the 24 added last). On iPad and the Mac, chips also filter by
  person: **Everyone** or one person.
- **Search:** finds names, kinds, field values, tags and words on the pages themselves.
- **On iPad and the Mac**, switch between **Cards** and **List**. In List, select several documents to set their
  collection, whose they are, or tags for all of them at once, or right-click them to **Move to** a collection or
  delete them together.

The first time you open Documents, Vault adds the default collections, Identity among them.

## Add a document

<!-- only: mac -->

- **Import** in the toolbar picks PDFs or pictures. You can pick several.
- **File ▸ Import from iPhone or iPad** takes a photo or scans pages with your iPhone or iPad.
- Drop PDFs or pictures onto the library.
- **New Document…** (⌥⌘N) in the File menu or the sidebar's New menu opens an empty **Add Document**, where you drop
  files or click **Choose Files…**.

<!-- /only -->

<!-- only: ios -->

- **Scan** (iPad) or **Add** (iPhone) opens the camera to scan pages.
- **Import** picks PDFs or pictures from Files. You can pick several.
- **New Document…** in the sidebar's New menu opens an empty **Add Document**, with **Scan…** and **Choose Files…**.
- Drop PDFs or pictures onto the library.

<!-- /only -->

From another app, you can also open a PDF or a picture in Vault, or share it to Vault (see
[Share to Vault from other apps](#share-to-vault-from-other-apps)).

The **Add Document** sheet opens and reads the pages. Then:

1. Check the pages. On a photo, drag the page's corners to crop it, and pick **Color**, **Grey** or **Document**. The
   trash button removes a page, and the **+** in the strip adds more.
2. Check the kind under **Looks like**. Vault suggests one. On a passport's or ID's data page, Vault reads the
   machine-readable zone and fills in the holder, nationality, number, date of birth and expiry, taking the number and
   dates only where their check digits match. The printed labels (such as Surname, Given names, Nationality and
   Passport No.) fill in what the zone lacks. Pick another kind from the menu if the suggestion is wrong.
3. Fill in or correct the **Title** and the fields. A number such as a passport number goes in a hidden field. An
   empty date field shows its format (YYYY-MM-DD). Vault leaves a date empty rather than suggest one that can't be
   right, such as a birth or an issue in the future, or an expiry before the issue.
4. Pick the **Collection** (or **Inbox**) and **Whose** it is (or **No one**). **Add Person** adds someone new.
5. Add **Tags**, set the **Reminder** (how many months before it ends) and add **Notes**.
6. Click **Add Document**.

A file can be up to 25 MB.

## Open a document

Select a document to see its details: the fields for its kind, hidden fields with **Show** and **Copy**, how long it's
valid, its pages, copies you shared, linked items and notes. On iPhone, tap the document, then **Details**.

Open it to see its pages large (**Open** on iPad and the Mac, a tap on iPhone):

- **Zoom** and **Fit**, **Rotate**, **Full Screen**, and the page strip to move between pages. A PDF shows its first
  40 pages.
- On a passport or ID page, Vault marks the machine-readable zone and says whether its check digits match.
- **Find on pages** (iPad and the Mac) highlights the matching lines.
- **Back** or Esc returns to the library.

### Full screen

Tap a page (double-click on the Mac), or click **Full Screen**, to see the pages alone on black. Pinch or double-tap
to zoom and drag to move around. **‹** and **›**, the ← and → keys or a swipe go to the other pages. **Close**, Esc or
a swipe down closes it.

## Quick actions

Touch and hold a document's card, or right-click a card or a row in List, for its quick actions: **Open**,
**Share a Copy…**, **Copy Number** (and any other hidden field), **Edit…**, **Duplicate**, **Move to** the Inbox or a
collection, and **Delete…**. A hidden field is copied after the app lock, and cleared from the clipboard after 90
seconds. The same actions are in **More** in the document's details.

## Reminders

In a document's details, **Reminder** sets how many months before the end date (1 to 24) it shows in **Coming Up**,
with the date it will show. Turn the switch off to skip it. A policy with a notice period also shows the last day to
cancel. For a passport, Vault reminds you that many countries want 6 months left when you arrive.

Reminders show in Vault's Coming Up and the sidebar. Vault doesn't send notifications.

## Edit, duplicate and add pages

- **Edit…** (in the details, or in the quick actions; **Edit** on an open document) opens the document's values.
  Hidden fields show as dots until you click **Show**, which asks for Touch ID or Face ID first. Change what you need
  and click **Save**.
- **Duplicate** makes a copy and opens it for editing, for example for next year's policy.
- The **+** in an open document's page strip adds pages: on the Mac it picks files, on iPhone and iPad it opens Edit,
  where you scan or choose them.

## Delete a document

Click **Delete Document…** under the document's actions (on iPhone, at the bottom of its Details), or choose
**Delete…** in its quick actions, then **Delete**. Its pages are deleted on all your devices. This can't be undone.

## Share a redacted copy

**Share a Copy…** makes a PDF to send to someone, with the parts you choose blacked out in the pictures themselves, not
just covered. The PDF has no text layer.

1. Type who it's **For**. It goes into the watermark ("For … only" and the date).
2. Leave **Watermark** on to print it across every page.
3. The **Hide** switches for each hidden field (such as the number) and, on an identity document, the
   **machine-readable zone** start on. The preview blacks them out. Vault warns you if it can't find a hidden value on
   the pages.
4. Turn **Include this page** off for pages you don't want to send. For a passport or a card, only the first page (the
   data page or the front) starts included.
5. **On the Mac**, click **Save PDF…** and choose where to save it. **On iPhone and iPad**, tap **Make PDF**, then
   **Share…**.

Once it's sent, a copy can't be taken back. Vault keeps a note of who got which copy, and what was hidden, under
**Copies Shared**.

## Share to Vault from other apps

On iPhone, iPad and the Mac, Vault appears in the share sheet for PDFs and pictures, up to 10 at a time.

1. In Photos, Files, Mail or Safari, choose Share, then Vault.
2. The **Add to Vault** sheet shows what you're adding. Tap **Add to Inbox**.

Pictures shared together become one document; each PDF becomes its own. They land in the **Inbox** the next time
Vault opens or comes to the front, and Vault reads their pages then. Vault takes PDFs and pictures only, up to 25 MB
each. Open Vault once on a device before sharing to it there.

The share sheet holds none of your keys: it seals what you share to a key only Vault can open, and leaves it for Vault
to pick up.

You can also open a PDF or a picture in Vault from another app ("Open in"). It goes straight to Add Document.

## Collections and people

**Settings ▸ Documents** manages the lists Documents uses:

- **Collections:** **Edit…** a collection's name, symbol and colour; in **More**, move it up or down or **Delete…** it
  (not Identity). Its documents go to the Inbox. **New…** makes one, and a click on a suggested one adds it.
- **People:** **Add…** a person with a name and a colour, **Edit…**, move or **Delete…** them. Their documents stay,
  as no one's. People here are only whose a document is, not the people you share with.

## How documents are kept

- Pages are read on the device: a PDF's own text, or text recognized in the picture. Nothing is sent anywhere to read
  them.
- A document is a record in your vault, encrypted like every other before it's saved or synced.
- Its pages, thumbnail and the text read from them are sealed again with a key only Vault has, so the other v57 apps,
  which open the same vault, can't read them.
- Hidden fields, such as a passport number, are kept in the keychain with your passwords, not in the record.
