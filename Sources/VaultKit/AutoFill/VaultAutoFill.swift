import Foundation

#if canImport(AuthenticationServices) && (os(macOS) || os(iOS))
  import AuthenticationServices
#endif

/// AutoFill: which logins fit a website or app, and the list of them the system keeps so it can offer them in
/// password fields. The matching is plain Swift; publishing the list uses the platform's credential store (Apple:
/// `ASCredentialIdentityStore`, read by Vault's credential provider extension).
public enum VaultAutoFill {
  /// How well a login fits a website: its exact host, a subdomain of its site, the site of a subdomain.
  public enum Match: Int, Comparable, Sendable {
    case parentDomain = 1
    case subdomain = 2
    case exact = 3

    public static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
  }

  /// The host a service identifier names: a URL ("https://www.github.com/login"), a bare domain, or nil for an app's
  /// bundle id and anything without a host.
  public static func host(of identifier: String) -> String? {
    let text = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty else { return nil }
    let url = URL(string: text.contains("://") ? text : "https://" + text)
    guard var host = url?.host, host.contains(".") else { return nil }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host
  }

  /// How well a login whose site is `domain` fits `host`: the same host, `host` inside `domain`
  /// (accounts.github.com for github.com), or `domain` inside `host`'s site; nil when they're different sites.
  /// A bare top-level domain never matches (`com` isn't a site).
  public static func match(domain: String, host: String) -> Match? {
    let domain = domain.lowercased()
    let host = host.lowercased()
    if domain == host { return .exact }
    if host.hasSuffix("." + domain), domain.contains(".") { return .subdomain }
    if domain.hasSuffix("." + host), host.contains(".") { return .parentDomain }
    return nil
  }

  /// The logins that fit any of the service identifiers, best first (then by title).
  public static func logins(for identifiers: [String], in logins: [VaultLogin]) -> [VaultLogin] {
    let hosts = identifiers.compactMap(host(of:))
    let scored: [(VaultLogin, Match)] = logins.compactMap { login in
      guard let domain = login.domain else { return nil }
      let best = hosts.compactMap { match(domain: domain, host: $0) }.max()
      return best.map { (login, $0) }
    }
    return scored.sorted {
      $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.displayName.localizedStandardCompare($1.0.displayName) == .orderedAscending
    }.map(\.0)
  }

  #if canImport(AuthenticationServices) && (os(macOS) || os(iOS))
    /// Replaces what the system offers in password fields with these logins (each by its site and username; the
    /// password itself stays in the keychain until the person picks one). Does nothing unless Vault is turned on
    /// in the system's AutoFill settings.
    public static func publish(_ logins: [VaultLogin]) async {
      let store = ASCredentialIdentityStore.shared
      guard await store.state().isEnabled else { return }
      let identities: [ASPasswordCredentialIdentity] = logins.compactMap { login in
        guard let domain = login.domain, !login.username.isEmpty else { return nil }
        return ASPasswordCredentialIdentity(
          serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain), user: login.username,
          recordIdentifier: login.id)
      }
      try? await store.replaceCredentialIdentities(with: identities)
    }
  #else
    /// Elsewhere the platform's own autofill service reads the vault; nothing to publish.
    public static func publish(_ logins: [VaultLogin]) async {}
  #endif
}
