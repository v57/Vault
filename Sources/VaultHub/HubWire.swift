import Foundation
import HubService
import VaultKit

/// What the Hub sends and takes, as `Docs/Devices/protocol.md` (§2, §3, §6) defines it. Decoding is lenient: a field
/// this version doesn't know, or one a Hub leaves out, never fails a whole list.
enum HubWire {
  /// `hub/info`.
  struct Info: Decodable, Sendable {
    var key: String
    var proto: Int?
    var pro: Bool?
    var mode: String?

    enum CodingKeys: String, CodingKey {
      case key, pro, mode
      case proto = "protocol"
    }
  }

  /// `hub/devices`.
  struct Device: Decodable, Sendable {
    var id: String
    var key: String
    var name: String
    var platform: String?
    var os: String?
    var arch: String?
    var parent: String?
    var approved: Bool
    var revoked: Bool
    var online: Bool
    var network: String?
    var overlay: Overlay?
    var lastSeen: String?
    var capabilities: Capabilities?
    var services: [Service]?

    struct Overlay: Decodable, Sendable {
      var address: String
      var authority: String?
    }

    struct Service: Decodable, Sendable {
      var key: String?
      var instance: String?
      var name: String?
      var online: Bool?
    }

    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      key = try c.decode(String.self, forKey: .key)
      name = (try? c.decode(String.self, forKey: .name)) ?? ""
      platform = try? c.decode(String.self, forKey: .platform)
      os = try? c.decode(String.self, forKey: .os)
      arch = try? c.decode(String.self, forKey: .arch)
      parent = try? c.decode(String.self, forKey: .parent)
      approved = (try? c.decode(Bool.self, forKey: .approved)) ?? false
      revoked = (try? c.decode(Bool.self, forKey: .revoked)) ?? false
      online = (try? c.decode(Bool.self, forKey: .online)) ?? false
      network = try? c.decode(String.self, forKey: .network)
      overlay = try? c.decode(Overlay.self, forKey: .overlay)
      lastSeen = try? c.decode(String.self, forKey: .lastSeen)
      capabilities = try? c.decode(Capabilities.self, forKey: .capabilities)
      services = try? c.decode([Service].self, forKey: .services)
    }

    enum CodingKeys: String, CodingKey {
      case id, key, name, platform, os, arch, parent, approved, revoked, online, network, overlay, lastSeen
      case capabilities, services
    }
  }

  struct Capabilities: Decodable, Sendable {
    var ssh: SSH?
    var tools: [String: ToolValue]?

    struct SSH: Decodable, Sendable {
      var port: Int?
      var user: String?
      var hostKey: String?
      var hostKeySignature: String?
    }

    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      ssh = try? c.decode(SSH.self, forKey: .ssh)
      tools = try? c.decode([String: ToolValue].self, forKey: .tools)
    }

    enum CodingKeys: String, CodingKey { case ssh, tools }
  }

  /// A tool's value: a version, a flag, or a list (simulators).
  struct ToolValue: Decodable, Sendable {
    var text: String?

    init(from decoder: any Decoder) throws {
      let c = try decoder.singleValueContainer()
      if let text = try? c.decode(String.self) {
        self.text = text
      } else if let flag = try? c.decode(Bool.self) {
        text = flag ? "yes" : nil
      } else if let list = try? c.decode([String].self) {
        text = list.joined(separator: ", ")
      } else if let number = try? c.decode(Double.self) {
        text = number.rounded() == number ? String(Int(number)) : String(number)
      }
    }
  }

  /// `hub/devices/pending`.
  struct PendingDevice: Decodable, Sendable {
    var id: String
    var key: String
    var name: String?
    var platform: String?
    var parent: String?
    var safetyCode: String
    var firstSeen: String?
  }

  /// `hub/profile/update`: how the Hub's own app lists this connection.
  struct Profile: Encodable, Sendable {
    var name: String
    var icon: Icon
  }

  struct ID: Encodable, Sendable { var id: String }
  struct Rename: Encodable, Sendable {
    var id: String
    var name: String
  }

  // MARK: Signed strings

  /// The `auth` header: `key.<SPKI>.<signature>.<expiry>`, signing `hub1:<hub SPKI>:<expiry>` once the Hub's key is
  /// pinned (v1), else the expiry alone (v0).
  static func auth(_ key: HubKey, hubKey: String?, expiry: Int) -> String {
    let signed = hubKey.map { "hub1:\($0):\(expiry)" } ?? "\(expiry)"
    return "key.\(key.spki).\(key.sign(signed)).\(expiry)"
  }

  /// The `device` header: the device key's certificate for the key the app connects with.
  static func certificate(
    device: HubKey, service: String, instance: String, deviceName: String?, platform: String?, parent: String? = nil,
    issued: Int, lifetime: Int = 604_800
  ) -> String {
    // Fields in the protocol's order with no whitespace, so the vectors match byte for byte.
    var json = "{\"v\":1,\"device\":\(quoted(device.spki)),\"service\":\(quoted(service)),\"instance\":\(quoted(instance))"
    if let deviceName { json += ",\"deviceName\":\(quoted(deviceName))" }
    if let platform { json += ",\"platform\":\(quoted(platform))" }
    if let parent { json += ",\"parent\":\(quoted(parent))" }
    json += ",\"iat\":\(issued),\"exp\":\(issued + lifetime)}"
    let payload = base64URL(Data(json.utf8))
    return "\(payload).\(device.sign(payload))"
  }

  /// The string a device signs for its SSH host key.
  static func hostKeySigned(_ hostKey: String) -> String { "ssh1:\(hostKey)" }

  static func quoted(_ text: String) -> String {
    let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
    return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func date(_ text: String?) -> Date? {
    guard let text else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}

extension VaultHubDevice {
  /// The Hub's entry as Vault keeps it. The SSH host key is kept only when the device's own key signed it, so a Hub
  /// can't hand apps a key of its choosing.
  init(_ wire: HubWire.Device) {
    var ssh: SSH?
    if let offer = wire.capabilities?.ssh {
      var hostKey: String?
      if let key = offer.hostKey, let signature = offer.hostKeySignature,
        HubKey.verify(signature, of: HubWire.hostKeySigned(key), spki: wire.key)
      {
        hostKey = key
      }
      ssh = SSH(port: offer.port ?? 22, hostKey: hostKey, user: offer.user)
    }
    // The Hub's id is checked against the key it lists, so a mismatched entry can't stand in for another device.
    let id = HubKey.deviceID(spki: wire.key) == wire.id ? wire.id : "unverified-\(wire.id)"
    self.init(
      id: id, name: wire.name, platform: wire.platform ?? "other", os: wire.os, arch: wire.arch, parent: wire.parent,
      isApproved: wire.approved && !id.hasPrefix("unverified-"), isRevoked: wire.revoked, isOnline: wire.online,
      isNetworkOnline: wire.network.map { $0 == "online" }, address: wire.overlay?.address,
      lastSeen: HubWire.date(wire.lastSeen), ssh: ssh,
      tools: (wire.capabilities?.tools ?? [:]).compactMapValues(\.text),
      services: (wire.services ?? []).compactMap { $0.instance ?? $0.name })
  }
}

/// A device waiting for an owner to let it in, with the code to compare on both screens.
public struct HubPendingDevice: Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var platform: String
  public var parent: String?
  public var safetyCode: String
  public var firstSeen: Date?
  /// Whether the code the Hub sent is the one its key gives: a mismatch means the Hub altered the request.
  public var codeChecks: Bool

  public init(
    id: String, name: String, platform: String, parent: String? = nil, safetyCode: String, firstSeen: Date? = nil,
    codeChecks: Bool = true
  ) {
    self.id = id
    self.name = name
    self.platform = platform
    self.parent = parent
    self.safetyCode = safetyCode
    self.firstSeen = firstSeen
    self.codeChecks = codeChecks
  }

  init(_ wire: HubWire.PendingDevice) {
    // The code shown is always the one this device computes from the key, never the Hub's own claim.
    let computed = HubKey.safetyCode(spki: wire.key)
    self.init(
      id: wire.id, name: wire.name ?? "", platform: wire.platform ?? "other", parent: wire.parent,
      safetyCode: computed ?? wire.safetyCode, firstSeen: HubWire.date(wire.firstSeen),
      codeChecks: computed == wire.safetyCode && HubKey.deviceID(spki: wire.key) == wire.id)
  }
}
