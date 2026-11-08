import CryptoKit
import Foundation

#if canImport(CommonCrypto)
  import CommonCrypto
#endif

/// PBKDF2 with HMAC-SHA256 (RFC 8018): what turns a backup's passphrase into its key. CommonCrypto's where there is one,
/// else the same computation over CryptoKit's HMAC (swift-crypto off Apple platforms), so a file made on one system opens
/// on every other.
enum PBKDF2 {
  static func sha256(password: Data, salt: Data, iterations: Int, length: Int = 32) -> Data {
    #if canImport(CommonCrypto)
      var derived = Data(count: length)
      let status = derived.withUnsafeMutableBytes { out in
        password.withUnsafeBytes { pass in
          salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
              CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
              saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
              CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
              out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
          }
        }
      }
      if status == kCCSuccess { return derived }
    #endif
    return portableSHA256(password: password, salt: salt, iterations: iterations, length: length)
  }

  /// The computation itself, for systems without CommonCrypto (and the test that both agree).
  static func portableSHA256(password: Data, salt: Data, iterations: Int, length: Int = 32) -> Data {
    // The key's pads are worked out once and copied for each block: HMAC is a value.
    let keyed = HMAC<SHA256>(key: SymmetricKey(data: password))
    var output = Data()
    var block: UInt32 = 1
    while output.count < length {
      var mac = keyed
      mac.update(data: salt)
      mac.update(data: withUnsafeBytes(of: block.bigEndian) { Data($0) })
      var u = Data(mac.finalize())
      var t = [UInt8](u)
      if iterations > 1 {
        for _ in 1..<iterations {
          var next = keyed
          next.update(data: u)
          u = Data(next.finalize())
          u.withUnsafeBytes { bytes in
            for index in 0..<t.count { t[index] ^= bytes[index] }
          }
        }
      }
      output.append(contentsOf: t)
      block += 1
    }
    return output.prefix(length)
  }
}
