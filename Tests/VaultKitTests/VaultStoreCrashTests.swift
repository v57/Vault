#if os(macOS)
  import CryptoKit
  import Foundation
  import Testing

  @testable import VaultKit

  /// Real processes, really killed. `VaultStoreCrashHelper` opens a store on an old file, as an app does on its first launch
  /// with this build. A kill lands wherever it lands, inside SQLite's own commits too, which the copies of the files in
  /// `FormatMigrationTests` can't reach.
  @Suite struct VaultStoreCrashTests {
    private static let rows = 2500
    private static let keyData = Data(repeating: 7, count: 32)

    private var keys: MemoryKeyProvider {
      MemoryKeyProvider(keys: ["0000000000000001": SymmetricKey(data: Self.keyData)])
    }

    private func helper() throws -> URL {
      // Built beside the test bundle, as the test target depends on it.
      let candidate = Bundle(for: FlakyKeys.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VaultStoreCrashHelper")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      throw CocoaError(.fileNoSuchFile)
    }

    private func run(_ helper: URL, in directory: URL) throws -> (process: Process, output: Pipe) {
      let process = Process()
      process.executableURL = helper
      process.arguments = [directory.path, Self.keyData.base64EncodedString()]
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      try process.run()
      return (process, output)
    }

    private func waitForExit(_ process: Process, seconds: TimeInterval = 120) -> Bool {
      let end = Date.now.addingTimeInterval(seconds)
      while process.isRunning, Date.now < end { Thread.sleep(forTimeInterval: 0.002) }
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        return false
      }
      return true
    }

    /// An old store, on disk with nothing in its WAL, ready to be copied for each run.
    private func preparedOldStore() throws -> URL {
      let old = try OldBuildStore(keys: keys, device: "mac")
      try old.database.transaction {
        for index in 0..<Self.rows {
          var fields = ItemFields()
          _ = fields.apply(["n": .int(Int64(index))], clock: HybridClock.zero.next(now: .now, device: "mac"))
          let sealed = try OldBuildStore.format1(id: "row-\(index)", kind: "host", fields: fields, keys: keys)
          try old.database.query(
            "INSERT INTO items(id, kind, key_id, payload, version, modified) VALUES(?, 'host', ?, ?, 1, 1)",
            [.text("row-\(index)"), .text(sealed.keyID), .blob(sealed.payload)])
        }
      }
      try old.database.checkpointFully()
      old.database.close()
      return old.directory
    }

    private func copyOfOldStore(_ source: URL) throws -> URL {
      let directory = temporaryDirectory()
      for name in try FileManager.default.contentsOfDirectory(atPath: source.path) where name == OldBuildStore.fileName {
        try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: directory.appendingPathComponent(name))
      }
      return directory
    }

    private func digest(_ url: URL) throws -> Data {
      Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    private func expectWholeStore(in directory: URL, _ note: String) throws {
      let store = try VaultStore(directory: directory, keys: keys, deviceID: "mac", notifier: nil, owner: "test")
      #expect(!store.isWaitingToMigrate, "\(note)")
      #expect(try store.items(kind: "host").count == Self.rows, "\(note)")
      #expect(try store.pendingCount() == Self.rows, "\(note)")
      let oldRows = try store.database.query("SELECT COUNT(*) FROM items WHERE NOT \(VaultStore.format2Rows)")[0][0].int
      #expect(oldRows == 0, "\(note)")
      #expect(try store.database.query("PRAGMA quick_check").first?.first?.text == "ok", "\(note)")
    }

    @Test func aKillAtAnyMomentLeavesTheOldStoreOrAWholeNewOne() throws {
      let helper = try helper()
      let source = try preparedOldStore()
      let original = try digest(source.appendingPathComponent(OldBuildStore.fileName))

      // How long a whole run takes, so the kills land across it.
      let timed = try copyOfOldStore(source)
      let started = Date.now
      let first = try run(helper, in: timed)
      #expect(waitForExit(first.process))
      #expect(first.process.terminationStatus == 0)
      let duration = Date.now.timeIntervalSince(started)
      try expectWholeStore(in: timed, "uninterrupted")

      var killedBeforeTheFile = 0
      var killedAfterTheFile = 0
      var leftovers = 0
      for round in 0..<30 {
        let directory = try copyOfOldStore(source)
        let delay = duration * Double(round) / 29 * 1.1
        let running = try run(helper, in: directory)
        Thread.sleep(forTimeInterval: delay)
        kill(running.process.processIdentifier, SIGKILL)
        running.process.waitUntilExit()

        let final = directory.appendingPathComponent(VaultStore.fileName)
        if FileManager.default.fileExists(atPath: final.path) { killedAfterTheFile += 1 } else { killedBeforeTheFile += 1 }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        if names.contains(where: { $0.contains(".tmp") }) { leftovers += 1 }
        // The old file is untouched, byte for byte, and the file under the final name, if it's there, is whole.
        #expect(try digest(directory.appendingPathComponent(OldBuildStore.fileName)) == original, "round \(round)")
        if FileManager.default.fileExists(atPath: final.path) {
          let database = try SQLiteConnection(url: final)
          #expect(Int(try database.query("SELECT COUNT(*) FROM items")[0][0].int ?? 0) == Self.rows, "round \(round)")
          database.close()
        }
        // And the next open finishes the job.
        try expectWholeStore(in: directory, "round \(round)")
        #expect(try digest(directory.appendingPathComponent(OldBuildStore.fileName)) == original, "round \(round)")
        try? FileManager.default.removeItem(at: directory)
      }
      print("kills: \(killedBeforeTheFile) before the file, \(killedAfterTheFile) after, \(leftovers) left a temporary file; a run took \(duration)s")
      // Otherwise this ran nothing it claims to.
      #expect(killedBeforeTheFile > 0)
      #expect(leftovers > 0)
    }

    /// Four processes, one winner: every process ends with the same file, and each row was rewritten once.
    @Test func fourProcessesRacingGetOneWinner() throws {
      let helper = try helper()
      let source = try preparedOldStore()
      for _ in 0..<4 {
        let directory = try copyOfOldStore(source)
        let runs = try (0..<4).map { _ in try run(helper, in: directory) }
        for running in runs {
          #expect(waitForExit(running.process))
          let output = String(decoding: running.output.fileHandleForReading.availableData, as: UTF8.self)
          #expect(running.process.terminationStatus == 0, "\(output)")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.contains(".tmp") }, "\(names)")
        try expectWholeStore(in: directory, "race")
        let store = try VaultStore(directory: directory, keys: keys, deviceID: "mac", notifier: nil, owner: "test")
        #expect(store.formatStatus.resealed == Self.rows)
        #expect(try store.database.query("SELECT MAX(version) FROM items")[0][0].int == 2)
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }
#endif
