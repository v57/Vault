import Foundation

/// Security audit M2: every app on a device shares one store, so they must all sync with one CloudKit environment. The
/// vault syncs in Production; a build signed for Development (a debug build without the entitlement) would put
/// Development's change tags into the shared file and its edits where the other devices never look. Such a build
/// doesn't sync (`CloudSync.isEntitled`) and, once the vault has synced in Production, can't write either: its edits
/// would only go up later under another build's name. It reads everything and says why it can't save.
public struct VaultEnvironmentMismatch: LocalizedError, Equatable, Sendable {
  /// The environment the vault syncs in.
  public var vault: String
  /// This build's.
  public var build: String

  public var errorDescription: String? {
    "This build of the app uses iCloud’s \(build) environment, but your vault syncs in \(vault). So the two don’t mix, the vault is read-only in this build. Use a release, TestFlight or App Store build, or a build signed for \(vault)."
  }
}

extension VaultStore {
  /// The engine state CloudSync sets on its first start in Production (since 2026-10-26).
  static let productionMark = "environment.production"
  static let environmentKey = "cloud.environment"

  /// The environment the vault has synced in: recorded by `CloudSync`, or Production for a store that synced before the
  /// record existed; nil when it never synced.
  public var cloudEnvironment: String? {
    withLock {
      if let recorded = try? meta(Self.environmentKey) { return recorded }
      return (try? engineState(Self.productionMark)) == nil ? nil : VaultCloudEnvironment.production
    }
  }

  /// Why this store refuses writes; nil while it takes them.
  public var writeRefusal: VaultEnvironmentMismatch? { withLock { _writeRefusal } }

  /// Makes the store read-only when `build`, this build's environment, isn't the one the vault synced in. Nil (off
  /// Apple platforms, or unknown) checks nothing.
  public func checkCloudEnvironment(_ build: String?) {
    guard let build, let vault = cloudEnvironment, vault != build else { return refuseWrites(nil) }
    refuseWrites(VaultEnvironmentMismatch(vault: vault, build: build))
  }

  /// Personal's refusal for an account's store, which shares its keys and its sync.
  func refuseWrites(_ refusal: VaultEnvironmentMismatch?) {
    withLock { _writeRefusal = refusal }
  }

  /// Notes the environment the store syncs in (`CloudSync`, once it runs there).
  func recordCloudEnvironment(_ environment: String) {
    withLock {
      guard (try? meta(Self.environmentKey)) != environment else { return }
      try? setMeta(Self.environmentKey, environment)
    }
  }
}
