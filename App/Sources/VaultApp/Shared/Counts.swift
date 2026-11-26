import Foundation


// "1 document", "3 documents": a count with its noun, each form its own phrase so it translates (never "1 devices").
extension Int {
  var documentsLabel: String { String(localized: "\(self) documents") }
  var pagesLabel: String { String(localized: "\(self) pages") }
  var filesLabel: String { String(localized: "\(self) files") }
  var peopleLabel: String { String(localized: "\(self) people") }
  var devicesLabel: String { String(localized: "\(self) devices") }
  var itemsLabel: String { String(localized: "\(self) items") }
  var loginsLabel: String { String(localized: "\(self) logins") }
  var cardsLabel: String { String(localized: "\(self) cards") }
  var notesLabel: String { String(localized: "\(self) notes") }
  var hostsLabel: String { String(localized: "\(self) hosts") }
  var foldersLabel: String { String(localized: "\(self) folders") }
  var remotesLabel: String { String(localized: "\(self) remotes") }
  var collectionsLabel: String { String(localized: "\(self) collections") }
  var vaultsLabel: String { String(localized: "\(self) vaults") }
  var keysLabel: String { String(localized: "\(self) keys") }
  var vaultKeysLabel: String { String(localized: "\(self) vault keys") }
  var accountsLabel: String { String(localized: "\(self) accounts") }
  var editsLabel: String { String(localized: "\(self) edits") }
}
