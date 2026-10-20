import Testing

@testable import VaultKit

@Test func autoFillHosts() {
  #expect(VaultAutoFill.host(of: "https://www.github.com/login") == "github.com")
  #expect(VaultAutoFill.host(of: "accounts.google.com") == "accounts.google.com")
  #expect(VaultAutoFill.host(of: "com.atlas.app") == "com.atlas.app")
  #expect(VaultAutoFill.host(of: "localhost") == nil)
  #expect(VaultAutoFill.host(of: "") == nil)
}

@Test func autoFillMatches() {
  #expect(VaultAutoFill.match(domain: "github.com", host: "github.com") == .exact)
  #expect(VaultAutoFill.match(domain: "github.com", host: "gist.github.com") == .subdomain)
  #expect(VaultAutoFill.match(domain: "staging.atlas.example.com", host: "atlas.example.com") == .parentDomain)
  #expect(VaultAutoFill.match(domain: "github.com", host: "notgithub.com") == nil)
  #expect(VaultAutoFill.match(domain: "com", host: "github.com") == nil)
  #expect(VaultAutoFill.match(domain: "github.com", host: "com") == nil)
}

@Test func autoFillRanksLogins() {
  let logins = [
    VaultLogin(title: "Atlas staging", website: "staging.atlas.example.com", username: "aiko"),
    VaultLogin(title: "Atlas admin", website: "https://atlas.example.com", username: "aiko"),
    VaultLogin(title: "GitHub", website: "github.com", username: "aiko-tanaka"),
    VaultLogin(title: "Ubiquiti", website: "", username: "admin"),
  ]
  let found = VaultAutoFill.logins(for: ["https://atlas.example.com/login"], in: logins).map(\.title)
  #expect(found == ["Atlas admin", "Atlas staging"])
  #expect(VaultAutoFill.logins(for: ["https://gist.github.com"], in: logins).map(\.title) == ["GitHub"])
  #expect(VaultAutoFill.logins(for: ["com.example.app"], in: logins).isEmpty)
}
