import Foundation
import Testing

@testable import VaultKit

struct NotifierTests {
  @Test @MainActor func darwinNotificationsReachObservers() async throws {
    let name = "dev.v57.vault.test.\(UUID().uuidString)"
    let received = Received()
    let observer = VaultChangeObserver(name: name) { received.mark() }
    DarwinChangeNotifier(name: name).post()
    for _ in 0..<50 where !received.value {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(received.value)
    _ = observer
  }
}

final class Received: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.withLock { flag } }
  func mark() { lock.withLock { flag = true } }
}
