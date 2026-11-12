import Foundation


// "1 document", "3 documents": a count with its noun, each form its own phrase so it translates (never "1 devices").
extension Int {
  var documentsLabel: String { self == 1 ? String(localized: "1 document") : String(localized: "\(self) documents") }
  var pagesLabel: String { self == 1 ? String(localized: "1 page") : String(localized: "\(self) pages") }
  var filesLabel: String { self == 1 ? String(localized: "1 file") : String(localized: "\(self) files") }
  var peopleLabel: String { self == 1 ? String(localized: "1 person") : String(localized: "\(self) people") }
  var devicesLabel: String { self == 1 ? String(localized: "1 device") : String(localized: "\(self) devices") }
  var itemsLabel: String { self == 1 ? String(localized: "1 item") : String(localized: "\(self) items") }
  var loginsLabel: String { self == 1 ? String(localized: "1 login") : String(localized: "\(self) logins") }
  var cardsLabel: String { self == 1 ? String(localized: "1 card") : String(localized: "\(self) cards") }
  var notesLabel: String { self == 1 ? String(localized: "1 note") : String(localized: "\(self) notes") }
  var hostsLabel: String { self == 1 ? String(localized: "1 host") : String(localized: "\(self) hosts") }
  var foldersLabel: String { self == 1 ? String(localized: "1 folder") : String(localized: "\(self) folders") }
  var remotesLabel: String { self == 1 ? String(localized: "1 remote") : String(localized: "\(self) remotes") }
  var collectionsLabel: String { self == 1 ? String(localized: "1 collection") : String(localized: "\(self) collections") }
  var vaultsLabel: String { self == 1 ? String(localized: "1 vault") : String(localized: "\(self) vaults") }
  var keysLabel: String { self == 1 ? String(localized: "1 key") : String(localized: "\(self) keys") }
  var vaultKeysLabel: String { self == 1 ? String(localized: "1 vault key") : String(localized: "\(self) vault keys") }
  var accountsLabel: String { self == 1 ? String(localized: "1 account") : String(localized: "\(self) accounts") }
  var editsLabel: String { self == 1 ? String(localized: "1 edit") : String(localized: "\(self) edits") }
}
