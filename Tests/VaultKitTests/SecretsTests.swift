import Foundation
import Testing

@testable import VaultKit

struct SecretsTests {
  init() { VaultSecrets.useInMemoryStore() }

  @Test func passwordsLiveInMemory() throws {
    #expect(VaultSecrets.isInMemory)
    let id = UUID().uuidString
    #expect(VaultSecrets.password(for: id) == nil)
    try VaultSecrets.setPassword("hunter2", for: id)
    #expect(VaultSecrets.password(for: id) == "hunter2")
    try VaultSecrets.setPassword("", for: id)
    #expect(VaultSecrets.password(for: id) == nil)
  }

  @Test func secretsByName() throws {
    let name = "token.\(UUID().uuidString)"
    try VaultSecrets.setSecret(Data([1, 2, 3]), named: name)
    #expect(VaultSecrets.secret(name) == Data([1, 2, 3]))
    try VaultSecrets.setSecretText("abc", named: name)
    #expect(VaultSecrets.secretText(name) == "abc")
    try VaultSecrets.setSecret(nil, named: name)
    #expect(VaultSecrets.secret(name) == nil)
  }

  @Test func switchingAgainKeepsTheSecrets() throws {
    let id = UUID().uuidString
    try VaultSecrets.setPassword("kept", for: id)
    VaultSecrets.useInMemoryStore()
    #expect(VaultSecrets.password(for: id) == "kept")
  }

  @Test func addNewKeepsTheFirstValue() throws {
    let memory = MemorySecretBacking()
    #expect(try memory.addNew(Data([1]), named: "a", label: ""))
    #expect(try !memory.addNew(Data([2]), named: "a", label: ""))
    #expect(try memory.read("a") == Data([1]))
    try memory.delete("a")
    #expect(memory.names.isEmpty)
  }
}
