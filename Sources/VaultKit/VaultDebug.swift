#if DEBUG && os(macOS)
  import Foundation
  import os

  extension Vault {
    /// Debug builds answer two Darwin notifications, for testing the apps together without clicking:
    ///
    /// - `dev.v57.vault.dump`: writes the vault's state to `/tmp/vault-<bundle id>.json`.
    /// - `dev.v57.vault.command`: runs the commands in `/tmp/vault-command-<bundle id>.json` (an array of
    ///   objects: `{"add": "/path"}`, `{"remove": "/path"}`, `{"save": "<id>", "kind": "host", "fields": {…}}`,
    ///   `{"delete": "<id>"}`, `{"sealNote": "/path.mdenc", "text": "…"}`, `{"openNote": "/path"}` (its text goes
    ///   in the dump), `{"removeFile": "/path"}`, `{"sync": true}`), then dumps.
    ///
    ///     notifyutil -p dev.v57.vault.dump
    func listenForDumpRequests() {
      dumpObserver = VaultChangeObserver(name: "dev.v57.vault.dump") { [weak self] in
        Task { @MainActor in self?.writeDump() }
      }
      commandObserver = VaultChangeObserver(name: "dev.v57.vault.command") { [weak self] in
        Task { @MainActor in self?.runCommands() }
      }
    }

    nonisolated(unsafe) private static var lastNoteText: String?
    private var noteText: String? {
      get { Self.lastNoteText }
      set { Self.lastNoteText = newValue }
    }

    private var bundleName: String { Bundle.main.bundleIdentifier ?? "app" }

    func runCommands() {
      let url = URL(fileURLWithPath: "/tmp/vault-command-\(bundleName).json")
      guard let store, let data = try? Data(contentsOf: url),
        let commands = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
      else { return }
      try? FileManager.default.removeItem(at: url)
      for command in commands {
        do {
          if let path = command["add"] as? String {
            try store.addProject(path: path, remoteURL: command["remote"] as? String)
          } else if let path = command["remove"] as? String {
            try store.removeProject(path: path)
          } else if let id = command["save"] as? String, let kind = command["kind"] as? String {
            let fields = (command["fields"] as? [String: Any] ?? [:]).mapValues(Self.json)
            try store.save(id: id, kind: kind, changes: fields)
          } else if let id = command["delete"] as? String {
            try store.delete(id: id)
          } else if let path = command["sealNote"] as? String {
            let data = try EncryptedNote.seal(command["text"] as? String ?? "", keys: store.keys)
            try data.write(to: URL(fileURLWithPath: path))
          } else if let path = command["openNote"] as? String {
            noteText = try EncryptedNote.text(of: Data(contentsOf: URL(fileURLWithPath: path)), keys: store.keys)
          } else if let path = command["writeFile"] as? String {
            // As another editor would: a plain write, no file coordination.
            try Data((command["text"] as? String ?? "").utf8).write(to: URL(fileURLWithPath: path))
          } else if let path = command["readFile"] as? String {
            noteText = (try? Data(contentsOf: URL(fileURLWithPath: path))).map { data in
              (try? EncryptedNote.text(of: data, keys: store.keys)) ?? "<\(data.count) bytes>"
            } ?? "<missing>"
          } else if let path = command["removeFile"] as? String {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: URL(fileURLWithPath: path), options: .forDeleting, error: &error) {
              try? FileManager.default.removeItem(at: $0)
            }
          } else if command["sync"] != nil {
            sync?.syncNow()
          }
        } catch {
          self.error = error.localizedDescription
        }
      }
      writeDump()
    }

    private static func json(_ value: Any) -> JSONValue {
      switch value {
      case let value as String: .string(value)
      case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): .bool(number.boolValue)
      case let value as Int: .int(Int64(value))
      case let value as Double: .double(value)
      case let value as [Any]: .array(value.map(json))
      case let value as [String: Any]: .object(value.mapValues(json))
      default: .null
      }
    }

    func writeDump() {
      reload(force: true)
      var dump: [String: Any] = [
        "bundle": bundleName,
        "device": deviceID,
        "directory": store?.directory.path ?? "",
        "keychainShared": VaultKeychain.isShared,
        "syncRunning": sync?.isRunning ?? false,
        "syncError": sync?.lastError ?? "",
        "error": error ?? "",
        "revision": store?.revision ?? -1,
        "pending": (try? store?.pendingCount()) ?? -1,
        "projects": projects.map {
          [
            "id": $0.id, "name": $0.name, "remote": $0.remoteURL ?? "", "paths": $0.paths, "groupID": $0.groupID ?? "",
            "order": $0.order,
          ]
        },
        "projectGroups": projectGroups.map {
          ["id": $0.id, "name": $0.name, "parentID": $0.parentID ?? "", "order": $0.order, "paths": $0.paths]
        },
        "hosts": hosts.map {
          ["id": $0.id, "name": $0.displayName, "hostname": $0.hostname, "port": $0.port, "user": $0.user, "auth": $0.auth.rawValue]
        },
        "databases": databases.map {
          ["id": $0.id, "name": $0.name, "engine": $0.engine, "host": $0.host, "port": $0.port, "sshHostID": $0.sshHostID ?? ""]
        },
        "deviceKeys": deviceKeys.map { ["id": $0.id, "name": $0.deviceName, "fingerprint": $0.fingerprint ?? ""] },
      ]
      if let noteText { dump["noteText"] = noteText }
      if let notes = try? store?.records(VaultNote.self) {
        dump["notes"] = notes.map { ["id": $0.id, "path": $0.path, "text": String($0.text.prefix(80))] }
      }
      // Items of kind "test", written by `save` commands while testing sync.
      if let tests = try? store?.items(kind: "test") {
        dump["test"] = Dictionary(uniqueKeysWithValues: tests.map { item in
          (item.id, item.values.mapValues { value -> Any in
            switch value {
            case .string(let text): text
            case .int(let number): number
            default: "\(value)"
            }
          })
        })
      }
      if VaultIdentity.exists, let key = try? VaultIdentity.key() {
        dump["identity"] = VaultIdentity.fingerprint(blob: VaultIdentity.publicKeyBlob(key))
      }
      let url = URL(fileURLWithPath: "/tmp/vault-\(bundleName).json")
      do {
        let data = try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
      } catch {
        Logger(subsystem: "dev.v57.vault", category: "debug").error("Dump failed: \(error, privacy: .public)")
      }
    }
  }
#endif
