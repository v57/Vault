import Foundation

/// Base32 (RFC 4648), the way one-time-code secrets are written: `JBSWY3DPEHPK3PXP`.
public enum Base32 {
  static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
  static let lookup: [UInt8: UInt8] = {
    var table: [UInt8: UInt8] = [:]
    for (index, char) in alphabet.enumerated() {
      table[char] = UInt8(index)
      // Lowercase letters too.
      if char >= 65 && char <= 90 { table[char + 32] = UInt8(index) }
    }
    return table
  }()

  /// The bytes, or nil when the text has a character outside the alphabet. Ignores case, spaces, dashes and
  /// `=` padding, as people copy keys in groups ("jbsw y3dp ehpk 3pxp").
  public static func decode(_ text: String) -> Data? {
    var bytes = Data()
    var buffer: UInt32 = 0
    var bits = 0
    for char in text.utf8 {
      if char == 32 || char == 45 || char == 61 || char == 9 || char == 10 || char == 13 { continue }
      guard let value = lookup[char] else { return nil }
      buffer = (buffer << 5) | UInt32(value)
      bits += 5
      if bits >= 8 {
        bits -= 8
        bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
      }
    }
    return bytes
  }

  /// Uppercase base32, padded with `=` to a multiple of 8 characters when `padding` is on.
  public static func encode(_ data: Data, padding: Bool = true) -> String {
    var output: [UInt8] = []
    var buffer: UInt32 = 0
    var bits = 0
    for byte in data {
      buffer = (buffer << 8) | UInt32(byte)
      bits += 8
      while bits >= 5 {
        bits -= 5
        output.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
      }
    }
    if bits > 0 { output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)]) }
    if padding { while output.count % 8 != 0 { output.append(61) } }
    return String(decoding: output, as: UTF8.self)
  }
}
