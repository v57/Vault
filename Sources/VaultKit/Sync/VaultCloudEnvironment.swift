import Foundation

#if os(macOS)
  import Security
#endif

/// This build's CloudKit environment (security audit M2), read from its own code signature: "Production",
/// "Development", or nil off Apple platforms and for a build without the vault's container.
///
/// - The Mac asks for its entitlement (`SecTask`).
/// - iOS can't, so it reads the signature's entitlements from its own executable. Without the key, a build signed with a
///   development profile (`get-task-allow`) uses Development and any other (TestFlight, App Store, ad hoc) Production.
public enum VaultCloudEnvironment {
  public static let production = "Production"
  public static let development = "Development"
  static let entitlement = "com.apple.developer.icloud-container-environment"

  public static let current: String? = read()

  private static func read() -> String? {
    #if os(macOS)
      guard let task = SecTaskCreateFromSelf(nil) else { return nil }
      let containers =
        SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        as? [String]
      guard containers?.contains(VaultConfiguration.cloudContainer) == true else { return nil }
      return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? String ?? development
    #elseif os(iOS) || os(visionOS) || os(tvOS) || os(watchOS)
      guard let executable = Bundle.main.executableURL,
        let binary = try? Data(contentsOf: executable, options: .alwaysMapped)
      else { return nil }
      let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) }
      return environment(signature: binary, profile: profile)
    #else
      return nil
    #endif
  }

  /// The environment a build signed with these entitlements (somewhere in `signature`) and this provisioning profile
  /// (nil for an App Store or TestFlight build) syncs in.
  static func environment(signature: Data, profile: Data?) -> String {
    if let value = stringValue(of: entitlement, in: signature) { return value }
    if let profile, boolValue(of: "get-task-allow", in: profile) == true { return development }
    return production
  }

  /// `<key>key</key><string>value</string>` in an XML plist inside `data` (the signature's entitlements blob, or the
  /// profile's), whitespace between them allowed.
  static func stringValue(of key: String, in data: Data) -> String? {
    guard let rest = after(key: key, in: data), rest.starts(with: Data("<string>".utf8)) else { return nil }
    let body = rest.dropFirst("<string>".utf8.count)
    guard let end = body.range(of: Data("</string>".utf8)), end.lowerBound - body.startIndex <= 64 else { return nil }
    return String(decoding: body[body.startIndex..<end.lowerBound], as: UTF8.self)
  }

  static func boolValue(of key: String, in data: Data) -> Bool? {
    guard let rest = after(key: key, in: data) else { return nil }
    if rest.starts(with: Data("<true/>".utf8)) { return true }
    if rest.starts(with: Data("<false/>".utf8)) { return false }
    return nil
  }

  /// What follows the key's closing tag, without leading whitespace.
  private static func after(key: String, in data: Data) -> Data? {
    guard let found = data.range(of: Data("<key>\(key)</key>".utf8)) else { return nil }
    var index = found.upperBound
    while index < data.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(data[index]) { index += 1 }
    return data[index...]
  }
}
