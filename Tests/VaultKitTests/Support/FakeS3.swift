import Foundation

@testable import VaultKit

/// An S3 server in memory, for `S3FileSystem` tests: one bucket, ListObjectsV2 (prefix, delimiter, max-keys,
/// continuation tokens), HEAD, GET with Range, PUT, copy, DELETE. It checks every request's signature with its own
/// copy of the secret, the way a real server does, from the URL it received: so what the client sends has to be
/// what it signed. Nothing touches the network.
actor FakeS3: S3Transport {
  struct Object {
    var data: Data
    var modified: Date
  }

  let bucket: String
  let accessKeyID: String
  let secretAccessKey: String
  let region: String
  private(set) var objects: [String: Object] = [:]
  /// Every request, "METHOD host path?query".
  private(set) var log: [String] = []

  init(
    bucket: String = "vault-test", accessKeyID: String = "AKIDTEST", secretAccessKey: String = "secret",
    region: String = "us-east-1", objects: [String: Data] = [:]
  ) {
    self.bucket = bucket
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.region = region
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    self.objects = objects.mapValues { Object(data: $0, modified: date) }
  }

  var keys: [String] { objects.keys.sorted() }

  func clearLog() { log = [] }

  nonisolated func send(_ request: S3Request) async throws -> S3Response {
    await handle(request)
  }

  private func handle(_ request: S3Request) -> S3Response {
    guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
      let host = components.host
    else { return error(400, "InvalidURI") }
    let encodedPath = components.percentEncodedPath
    let query: [(String, String)] = (components.percentEncodedQuery ?? "").split(separator: "&").map { pair in
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
        String($0).removingPercentEncoding ?? String($0)
      }
      return (parts[0], parts.count > 1 ? parts[1] : "")
    }
    log.append("\(request.method) \(host) \(encodedPath)" + (components.percentEncodedQuery.map { "?" + $0 } ?? ""))

    if let failure = checkSignature(request, encodedPath: encodedPath, query: query) { return failure }

    // Virtual-host style names the bucket in the host, path style in the first segment.
    let path = encodedPath.removingPercentEncoding ?? encodedPath
    var key: String
    if host.hasPrefix(bucket + ".") {
      key = String(path.dropFirst())
    } else {
      let parts = path.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.first.map(String.init) == bucket else { return error(404, "NoSuchBucket") }
      key = parts.count > 1 ? String(parts[1]) : ""
    }

    switch request.method {
    case "GET" where key.isEmpty:
      return list(Dictionary(query, uniquingKeysWith: { a, _ in a }))
    case "GET":
      guard let object = objects[key] else { return error(404, "NoSuchKey") }
      guard let range = request.headers["range"] else { return S3Response(status: 200, body: object.data) }
      let bounds = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
      guard bounds.count == 2, bounds[0] < object.data.count else { return error(416, "InvalidRange") }
      return S3Response(status: 206, body: object.data.subdata(in: bounds[0]..<min(bounds[1] + 1, object.data.count)))
    case "HEAD":
      guard let object = objects[key] else { return S3Response(status: 404) }
      return S3Response(
        status: 200,
        headers: ["Content-Length": String(object.data.count), "Last-Modified": "Tue, 14 Nov 2023 22:13:20 GMT"])
    case "PUT":
      if let source = request.headers["x-amz-copy-source"] {
        let sourcePath = source.removingPercentEncoding ?? source
        let sourceKey = String(sourcePath.dropFirst(bucket.count + 2))
        guard sourcePath.hasPrefix("/" + bucket + "/"), let object = objects[sourceKey] else {
          return error(404, "NoSuchKey")
        }
        objects[key] = Object(data: object.data, modified: object.modified)
        return S3Response(status: 200, body: Data("<CopyObjectResult><ETag>\"x\"</ETag></CopyObjectResult>".utf8))
      }
      guard request.headers["x-amz-content-sha256"] == AWSSignatureV4.payloadHash(request.body) else {
        return error(400, "XAmzContentSHA256Mismatch")
      }
      objects[key] = Object(data: request.body, modified: Date(timeIntervalSince1970: 1_700_000_000))
      return S3Response(status: 200)
    case "DELETE":
      objects[key] = nil
      return S3Response(status: 204)
    default:
      return error(405, "MethodNotAllowed")
    }
  }

  /// ListObjectsV2. The continuation token is the last key or common prefix of the page before.
  private func list(_ query: [String: String]) -> S3Response {
    guard query["list-type"] == "2" else { return error(400, "InvalidArgument") }
    let prefix = query["prefix"] ?? ""
    let delimiter = query["delimiter"]
    let maxKeys = query["max-keys"].flatMap(Int.init) ?? 1000
    // "P<prefix>" after a common prefix (skip every key under it), "K<key>" after a key.
    let token = query["continuation-token"].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
    let after = token.map { String($0.dropFirst()) }
    let afterPrefix = token?.hasPrefix("P") == true
    var contents: [String] = []
    var prefixes: [String] = []
    var last: String?
    var truncated = false
    for key in keys where key.hasPrefix(prefix) {
      if let after, key <= after || (afterPrefix && key.hasPrefix(after)) { continue }
      var entry = key
      var isPrefix = false
      if let delimiter, let range = key.dropFirst(prefix.count).range(of: delimiter) {
        entry = String(key[..<range.upperBound])
        isPrefix = true
        if prefixes.last == entry { continue }
      }
      if contents.count + prefixes.count == maxKeys {
        truncated = true
        break
      }
      if isPrefix { prefixes.append(entry) } else { contents.append(entry) }
      last = (isPrefix ? "P" : "K") + entry
    }
    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    xml += "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>\(bucket)</Name>"
    xml += "<Prefix>\(escape(prefix))</Prefix><KeyCount>\(contents.count + prefixes.count)</KeyCount>"
    xml += "<MaxKeys>\(maxKeys)</MaxKeys><IsTruncated>\(truncated)</IsTruncated>"
    if truncated, let last { xml += "<NextContinuationToken>\(Data(last.utf8).base64EncodedString())</NextContinuationToken>" }
    for key in contents {
      let object = objects[key]!
      xml += "<Contents><Key>\(escape(key))</Key><LastModified>2023-11-14T22:13:20.000Z</LastModified>"
      xml += "<ETag>&quot;x&quot;</ETag><Size>\(object.data.count)</Size><StorageClass>STANDARD</StorageClass></Contents>"
    }
    for prefix in prefixes { xml += "<CommonPrefixes><Prefix>\(escape(prefix))</Prefix></CommonPrefixes>" }
    xml += "</ListBucketResult>"
    return S3Response(status: 200, headers: ["Content-Type": "application/xml"], body: Data(xml.utf8))
  }

  private func checkSignature(_ request: S3Request, encodedPath: String, query: [(String, String)]) -> S3Response? {
    guard let authorization = request.headers["Authorization"], let date = request.headers["x-amz-date"],
      let payloadHash = request.headers["x-amz-content-sha256"]
    else { return error(403, "AccessDenied", "Missing authorization") }
    var fields: [String: String] = [:]
    for part in authorization.dropFirst(AWSSignatureV4.algorithm.count + 1).split(separator: ",") {
      let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
      if pair.count == 2 { fields[pair[0]] = pair[1] }
    }
    guard let credential = fields["Credential"], let signedNames = fields["SignedHeaders"],
      let signature = fields["Signature"]
    else { return error(400, "AuthorizationHeaderMalformed") }
    guard credential.hasPrefix(accessKeyID + "/") else { return error(403, "InvalidAccessKeyId") }
    guard credential.hasSuffix("/\(region)/s3/aws4_request") else { return error(400, "AuthorizationHeaderMalformed") }
    let names = signedNames.split(separator: ";").map(String.init)
    guard names.contains("host"), names.contains("x-amz-date"), names.contains("x-amz-content-sha256") else {
      return error(403, "AccessDenied", "Required headers aren't signed")
    }
    var headers: [String: String] = [:]
    for (name, value) in request.headers where names.contains(name.lowercased()) { headers[name.lowercased()] = value }
    // The Host header a client sends is the URL's.
    if let host = request.url.host { headers["host"] = host + (request.url.port.map { ":\($0)" } ?? "") }
    guard let when = parse(date) else { return error(403, "AccessDenied", "Bad date") }
    let signer = AWSSignatureV4(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, region: region)
    let path = encodedPath.split(separator: "/", omittingEmptySubsequences: false)
      .map { String($0).removingPercentEncoding ?? String($0) }.joined(separator: "/")
    let canonical = signer.canonicalRequest(
      method: request.method, path: path, query: query, headers: headers, payloadHash: payloadHash)
    // The client must have sent the path it signed: re-encoding what arrived gives the same text.
    guard AWSSignatureV4.encodePath(path) == encodedPath else { return error(400, "InvalidURI") }
    let expected = signer.signature(stringToSign: signer.stringToSign(canonicalRequest: canonical, date: when), date: when)
    return expected == signature ? nil : error(403, "SignatureDoesNotMatch")
  }

  private func parse(_ timestamp: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.date(from: timestamp)
  }

  private func error(_ status: Int, _ code: String, _ message: String = "") -> S3Response {
    let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>\(code)</Code><Message>\(message)</Message></Error>"
    return S3Response(status: status, body: Data(xml.utf8))
  }

  private func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
