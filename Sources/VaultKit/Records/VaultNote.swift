import Foundation

/// A note: Markdown text that syncs through the vault, shared by Markdown (which keeps it as a file in its
/// notes folder, `NotesMirror`) and Shell (which reads the record).
///
/// The text is always encrypted in iCloud like every vault item, titles and folders included. `encrypted`
/// only decides the local file: an encrypted note is `Name.mdenc` on disk (only the v57 apps read it), a plain
/// one `Name.md` that any editor opens. Edits to `text` made on two devices at once merge line by line
/// (`VaultStore.textFields`).
public struct VaultNote: VaultRecord, Hashable {
  public static let kind = "note"

  public var id: String
  /// The folder inside the notes folder ("" for the top, "Work/Ideas" for a subfolder).
  public var folder: String
  /// The file name without its extension.
  public var name: String
  public var encrypted: Bool
  public var text: String
  public var created: Date?

  public init(
    id: String = UUID().uuidString, folder: String = "", name: String, encrypted: Bool = true, text: String = "",
    created: Date? = .now
  ) {
    self.id = id
    self.folder = folder
    self.name = name
    self.encrypted = encrypted
    self.text = text
    self.created = created
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    folder = read.string("folder", default: "")
    name = read.string("name", default: "Untitled")
    encrypted = read.bool("encrypted", default: true)
    text = read.string("text", default: "")
    created = read.date("created")
  }

  public var values: [String: JSONValue] {
    [
      "folder": .string(folder), "name": .string(name), "encrypted": .bool(encrypted), "text": .string(text),
      "created": .init(created),
    ]
  }

  /// The file's path inside the notes folder, extension included.
  public var path: String {
    let file = name + "." + (encrypted ? EncryptedNote.fileExtension : "md")
    return folder.isEmpty ? file : folder + "/" + file
  }
}

/// Any other file in the notes folder (an image a note links to), synced with the notes. Files over
/// `maximumSize` stay on the device.
public struct VaultNoteFile: VaultRecord, Hashable {
  public static let kind = "noteFile"
  public static let maximumSize = 25 * 1024 * 1024

  public var id: String
  /// The file's path inside the notes folder, extension included.
  public var path: String
  public var data: Data

  public init(id: String = UUID().uuidString, path: String, data: Data) {
    self.id = id
    self.path = path
    self.data = data
  }

  public init(id: String, values: [String: JSONValue]) {
    let read = FieldReader(values)
    self.id = id
    path = read.string("path", default: "")
    data = read.string("data").flatMap { Data(base64Encoded: $0) } ?? Data()
  }

  public var values: [String: JSONValue] {
    ["path": .string(path), "data": .string(data.base64EncodedString())]
  }
}
