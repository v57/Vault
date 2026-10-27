import Foundation

#if os(macOS)
  import SystemConfiguration
#endif

/// A Mac lets the user's other devices in over SSH without a Hub: it publishes itself as a host (`VaultHost.device`:
/// its address, user and host key) and adds the devices the user allows to its `authorized_keys`
/// (`VaultAuthorizedKeys`). The others find its projects' folders (`path.<device>`) on that host.
extension VaultStore {
  /// The id of the host a device publishes for itself.
  public func deviceHostID(device: String) throws -> String {
    try derivedID("deviceHost|\(device)")
  }

  /// Publishes this device as a host, or brings it up to date. The name, hostname and user follow what's given until
  /// the user changes them; the host key is trusted for every app. Writes only what changed, so it can run at every
  /// launch. Returns whether it wrote.
  @discardableResult
  public func publishDeviceHost(
    name: String, address: String, user: String, port: Int = 22, hostKey: String?, allowed: Set<String>
  ) throws -> Bool {
    let id = try deviceHostID(device: deviceID)
    let route = VaultHost.DeviceRoute(deviceID: deviceID, address: address, hostKey: hostKey, allowed: allowed)
    var host: VaultHost
    if let old = try record(VaultHost.self, id: id) {
      host = old
      if old.hostname.isEmpty || old.hostname == old.device?.address { host.hostname = address }
      if old.user.isEmpty { host.user = user }
      if old.name.isEmpty { host.name = name }
      host.port = port
      if old.hostname != host.hostname || old.port != host.port || old.device?.hostKey != hostKey {
        try untrustDeviceKey(of: old)
      }
    } else {
      host = VaultHost(id: id, name: name, hostname: address, port: port, user: user, source: "device")
    }
    host.device = route
    let wrote = try save(host)
    if route.hostKeyIsPinnable, let fingerprint = route.hostKeyFingerprint,
      try knownFingerprint(host: host.hostname, port: host.port) != fingerprint
    {
      try trust(fingerprint: fingerprint, host: host.hostname, port: host.port, keyType: hostKey.flatMap(Self.keyType))
    }
    return wrote
  }

  /// Takes this device's host away, and the trust it gave its key.
  public func withdrawDeviceHost() throws {
    let id = try deviceHostID(device: deviceID)
    guard let host = try record(VaultHost.self, id: id) else { return }
    try untrustDeviceKey(of: host)
    try delete(id: id)
  }

  /// Drops the trust publishing gave a host's address, unless the user has since accepted another key there.
  private func untrustDeviceKey(of host: VaultHost) throws {
    guard host.device?.hostKeyIsPinnable == true, let fingerprint = host.device?.hostKeyFingerprint,
      try knownFingerprint(host: host.hostname, port: host.port) == fingerprint
    else { return }
    try delete(id: try knownHostID(host: host.hostname, port: host.port))
  }
}

#if os(macOS)
  /// What this Mac tells the user's other devices about reaching it over SSH.
  public enum VaultThisMac {
    /// "Studio.local": the Bonjour name the Mac answers to on its network.
    public static var localAddress: String? {
      SCDynamicStoreCopyLocalHostName(nil).map { "\($0 as String).local" }
    }

    /// The host key the Mac's sshd offers the v57 apps (ECDSA, else RSA: their libssh2 has no Ed25519).
    public static func hostKey(directory: URL = URL(fileURLWithPath: "/etc/ssh")) -> String? {
      for name in ["ssh_host_ecdsa_key.pub", "ssh_host_rsa_key.pub"] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { continue }
        // "<type> <blob> <comment>": the comment names the machine it was made on, which the others don't need.
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count >= 2 { return "\(words[0]) \(words[1])" }
      }
      return nil
    }

    /// Whether this app can change `~/.ssh` (a sandboxed one sees only its container).
    public static var canManageSSH: Bool {
      ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
    }

    /// Whether Remote Login is on: sshd answers on port 22 here. Blocks for up to a second.
    public static func remoteLoginIsOn(port: UInt16 = 22) -> Bool {
      let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
      guard socket >= 0 else { return false }
      defer { close(socket) }
      var timeout = timeval(tv_sec: 1, tv_usec: 0)
      setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard connected == 0 else { return false }
      var banner = [UInt8](repeating: 0, count: 4)
      return recv(socket, &banner, banner.count, MSG_WAITALL) == banner.count && banner == Array("SSH-".utf8)
    }
  }

  extension Vault {
    /// Whether this Mac lets the user's other devices in over SSH.
    public var sharesThisMac: Bool { thisDeviceHost != nil }

    /// Lets the user's other devices find this Mac and its projects' folders, and reach it over SSH: publishes it as
    /// a host. Each device still needs allowing (`setAllowed`) before it can sign in.
    public func shareThisMac() {
      perform { _ in try publishThisMac(force: true) }
    }

    /// Stops: takes the host away and every device's key Vault added to `authorized_keys`.
    public func stopSharingThisMac(keys: VaultAuthorizedKeys = .user) {
      perform { store in
        try keys.disallowAll()
        try store.withdrawDeviceHost()
      }
    }

    /// Adds a device's key to this Mac's `authorized_keys`, or takes it out, and tells the others.
    public func setAllowed(_ allowed: Bool, device: VaultDeviceKey, keys: VaultAuthorizedKeys = .user) {
      perform { _ in
        if allowed { try keys.allow(device) } else { try keys.disallow(device) }
        try publishThisMac(keys: keys)
      }
    }

    /// Whether a device's key is in this Mac's `authorized_keys`.
    public func allowedDevices(keys: VaultAuthorizedKeys = .user) -> Set<String> {
      (try? keys.allowedDevices(among: deviceKeys)) ?? []
    }

    /// Brings this Mac's host up to date (its address, user and host key, the devices it allows) and takes out
    /// the keys of devices that are gone or have a new key. Does nothing while the Mac isn't shared, or in an app
    /// that can't reach `~/.ssh`. Every Mac app runs it at launch and when a device's key changes.
    public func refreshThisMac() {
      guard isPersonal, sharesThisMac, VaultThisMac.canManageSSH else { return }
      perform { _ in
        try VaultAuthorizedKeys.user.removeStale(keeping: deviceKeys)
        try publishThisMac()
      }
    }

    /// Publishes this Mac as it is now. Without `force`, only while it's already published.
    private func publishThisMac(force: Bool = false, keys: VaultAuthorizedKeys = .user) throws {
      guard let store, force || sharesThisMac else { return }
      let others = deviceKeys.filter { $0.id != deviceID }
      try store.publishDeviceHost(
        name: VaultDevice.name, address: VaultThisMac.localAddress ?? ProcessInfo.processInfo.hostName,
        user: NSUserName(), hostKey: VaultThisMac.hostKey(), allowed: try keys.allowedDevices(among: others))
    }
  }
#endif
