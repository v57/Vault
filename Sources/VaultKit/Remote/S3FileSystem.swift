import Foundation

/// Where an S3 bucket is and how to sign for it.
public struct S3Configuration: Sendable, Hashable {
  public enum Addressing: String, Sendable, Hashable {
    /// Virtual-host style on AWS when the bucket name allows it, path style everywhere else.
    case automatic
    /// `https://endpoint/bucket/key`: MinIO, R2, and buckets with dots in their names.
    case path
    /// `https://bucket.endpoint/key`.
    case virtualHost
  }

  /// The server, without the bucket: "https://s3.eu-central-1.amazonaws.com",
  /// "https://<account>.r2.cloudflarestorage.com", "https://s3.us-west-004.backblazeb2.com", "http://nas:9000".
  public var endpoint: URL
  public var bucket: String
  /// The signing region: "auto" for R2, "us-east-1" for MinIO unless it was set up with another.
  public var region: String
  public var accessKeyID: String
  public var secretAccessKey: String
  public var sessionToken: String?
  /// The folder in the bucket everything goes under ("" for the whole bucket).
  public var prefix: String
  public var addressing: Addressing

  public init(
    endpoint: URL, bucket: String, region: String, accessKeyID: String, secretAccessKey: String,
    sessionToken: String? = nil, prefix: String = "", addressing: Addressing = .automatic
  ) {
    self.endpoint = endpoint
    self.bucket = bucket
    self.region = region
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.sessionToken = sessionToken
    self.prefix = prefix
    self.addressing = addressing
  }

  /// A configuration from what a user types: an endpoint with or without a scheme (empty means AWS in `region`),
  /// and a region that may be empty (taken from the endpoint's name, "auto" for R2, else "us-east-1").
  public init(
    endpoint: String, bucket: String, region: String, accessKeyID: String, secretAccessKey: String,
    prefix: String = "", addressing: Addressing = .automatic
  ) throws {
    let trimmedRegion = region.trimmingCharacters(in: .whitespaces)
    var text = endpoint.trimmingCharacters(in: .whitespaces)
    if text.isEmpty {
      let region = trimmedRegion.isEmpty ? "us-east-1" : trimmedRegion
      text = region == "us-east-1" ? "https://s3.amazonaws.com" : "https://s3.\(region).amazonaws.com"
    }
    if !text.contains("://") { text = "https://" + text }
    while text.hasSuffix("/") { text.removeLast() }
    guard let url = URL(string: text), let host = url.host, !host.isEmpty, ["http", "https"].contains(url.scheme ?? "")
    else { throw S3Error.invalidConfiguration("“\(endpoint)” isn’t a server address.") }
    let bucket = bucket.trimmingCharacters(in: .whitespaces)
    guard !bucket.isEmpty, !bucket.contains("/") else {
      throw S3Error.invalidConfiguration("“\(bucket)” isn’t a bucket name.")
    }
    self.init(
      endpoint: url, bucket: bucket, region: trimmedRegion.isEmpty ? Self.region(forHost: host) : trimmedRegion,
      accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, prefix: try RemotePath.normalize(prefix),
      addressing: addressing)
  }

  /// The region an endpoint's name gives: "s3.eu-central-1.amazonaws.com" → "eu-central-1", R2 → "auto".
  public static func region(forHost host: String) -> String {
    let host = host.lowercased()
    if host.hasSuffix(".r2.cloudflarestorage.com") || host == "r2.cloudflarestorage.com" { return "auto" }
    let labels = host.split(separator: ".").map(String.init)
    if host.hasSuffix(".amazonaws.com") || host.hasSuffix(".backblazeb2.com") {
      // s3.<region>.amazonaws.com, s3-<region>.amazonaws.com, s3.dualstack.<region>.amazonaws.com
      for label in labels.dropLast(2) where label.contains("-") {
        let name = label.hasPrefix("s3-") ? String(label.dropFirst(3)) : label
        if name.split(separator: "-").count >= 3 { return name }
      }
    }
    return "us-east-1"
  }

  var usesVirtualHost: Bool {
    switch addressing {
    case .path: false
    case .virtualHost: true
    case .automatic:
      // Dots in a bucket name break the TLS wildcard certificate; capitals and underscores aren't host names.
      (endpoint.host ?? "").lowercased().hasSuffix("amazonaws.com") && bucket.range(of: "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", options: .regularExpression) != nil
    }
  }
}

public enum S3Error: LocalizedError, Equatable {
  case invalidConfiguration(String)
  /// The server answered with an error: HTTP status, S3's error code ("AccessDenied", "NoSuchBucket", …) and message.
  case server(status: Int, code: String, message: String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let detail): detail
    case .server(let status, let code, let message):
      switch code {
      case "AccessDenied": "The S3 server refused access. Check the key’s permissions for this bucket."
      case "InvalidAccessKeyId": "The S3 server doesn’t know this access key."
      case "SignatureDoesNotMatch": "The S3 server didn’t accept the secret key."
      case "NoSuchBucket": "The bucket doesn’t exist."
      case "PermanentRedirect", "AuthorizationHeaderMalformed":
        "The bucket is in another region. " + (message.isEmpty ? "" : message)
      default: "The S3 server answered \(status)\(code.isEmpty ? "" : " (\(code))")" + (message.isEmpty ? "." : ": \(message)")
      }
    case .invalidResponse(let detail): "The S3 server sent something unexpected: \(detail)"
    }
  }
}

/// A bucket (or a folder in one) as a remote: AWS S3, Cloudflare R2, Backblaze B2, MinIO, anything that speaks
/// S3 with Signature V4.
///
/// S3 has keys, not folders: a folder is the keys under `path/`, plus an empty `path/` object (a folder marker)
/// that `createDirectory` writes so empty folders stay. Folders made by other tools without markers list the same.
/// To keep the `RemoteFileSystem` rules, a folder that a delete or a move empties gets a marker, and writes check
/// that no file sits where a parent folder should be.
public struct S3FileSystem: RemoteFileSystem {
  public let configuration: S3Configuration
  private let transport: any S3Transport
  private let clock: @Sendable () -> Date
  private let signer: AWSSignatureV4
  /// Keys per list request (S3's maximum is 1,000).
  private let pageSize: Int

  public init(
    configuration: S3Configuration, transport: any S3Transport = URLSessionS3Transport(),
    clock: @escaping @Sendable () -> Date = { Date() }, pageSize: Int = 1000
  ) {
    self.configuration = configuration
    self.transport = transport
    self.clock = clock
    self.pageSize = max(1, min(pageSize, 1000))
    signer = AWSSignatureV4(
      accessKeyID: configuration.accessKeyID, secretAccessKey: configuration.secretAccessKey,
      region: configuration.region, sessionToken: configuration.sessionToken)
  }

  // MARK: RemoteFileSystem

  public func list(_ path: String) async throws -> [RemoteFileInfo] {
    let path = try RemotePath.normalize(path)
    let page = try await listKeys(prefix: folderKey(path), delimiter: true, limit: nil)
    var entries: [String: RemoteFileInfo] = [:]
    for folder in page.folders {
      let name = String(folder.dropFirst(folderKey(path).count).dropLast())
      guard !name.isEmpty, RemotePath.isPlainName(name) else { continue }
      entries[name] = RemoteFileInfo(path: RemotePath.join(path, name), isDirectory: true)
    }
    for object in page.objects {
      let name = String(object.key.dropFirst(folderKey(path).count))
      // The folder's own marker, and names a path can't hold.
      guard !name.isEmpty, RemotePath.isPlainName(name), entries[name] == nil else { continue }
      entries[name] = RemoteFileInfo(
        path: RemotePath.join(path, name), isDirectory: false, size: object.size, modified: object.modified)
    }
    if entries.isEmpty, !path.isEmpty, page.objects.isEmpty {
      // Not even a marker: no folder here.
      if try await head(path) != nil { throw RemoteFileError.notADirectory(path) }
      throw RemoteFileError.notFound(path)
    }
    return entries.values.sorted { $0.name < $1.name }
  }

  public func stat(_ path: String) async throws -> RemoteFileInfo? {
    let path = try RemotePath.normalize(path)
    if path.isEmpty { return RemoteFileInfo(path: "", isDirectory: true) }
    if let file = try await head(path) { return file }
    return try await isFolder(path) ? RemoteFileInfo(path: path, isDirectory: true) : nil
  }

  public func read(_ path: String, range: Range<Int64>?) async throws -> Data {
    let path = try RemotePath.normalize(path)
    guard !path.isEmpty else { throw RemoteFileError.isADirectory(path) }
    var headers: [String: String] = [:]
    if let range {
      let lower = max(range.lowerBound, 0)
      guard range.upperBound > lower else {
        // Nothing to read; still say whether the file is there.
        guard let info = try await stat(path) else { throw RemoteFileError.notFound(path) }
        if info.isDirectory { throw RemoteFileError.isADirectory(path) }
        return Data()
      }
      headers["range"] = "bytes=\(lower)-\(range.upperBound - 1)"
    }
    let response = try await send("GET", key: objectKey(path), headers: headers)
    switch response.status {
    case 200, 206: return response.body
    case 416: return Data()  // the range starts past the end
    case 404:
      throw try await isFolder(path) ? RemoteFileError.isADirectory(path) : RemoteFileError.notFound(path)
    default: throw Self.error(response)
    }
  }

  public func write(_ data: Data, to path: String) async throws {
    let path = try RemotePath.normalize(path)
    guard !path.isEmpty else { throw RemoteFileError.isADirectory(path) }
    try await checkWritable(path)
    let response = try await send(
      "PUT", key: objectKey(path), headers: ["content-type": "application/octet-stream"], body: data)
    guard response.status == 200 else { throw Self.error(response) }
  }

  public func createDirectory(_ path: String) async throws {
    let path = try RemotePath.normalize(path)
    guard !path.isEmpty else { return }
    if try await head(path) != nil { throw RemoteFileError.alreadyExists(path) }
    if try await isFolder(path) { return }
    try await checkParents(path)
    try await putMarker(path)
  }

  public func rename(_ source: String, to destination: String) async throws {
    let source = try RemotePath.normalize(source)
    let destination = try RemotePath.normalize(destination)
    guard !source.isEmpty, !destination.isEmpty else { throw RemoteFileError.invalidPath(source) }
    let file = try await head(source)
    let isDirectory = file == nil ? try await isFolder(source) : false
    guard file != nil || isDirectory else { throw RemoteFileError.notFound(source) }
    guard source != destination else { return }
    if destination.hasPrefix(source + "/") { throw RemoteFileError.invalidPath(destination) }
    if try await isFolder(destination) { throw RemoteFileError.alreadyExists(destination) }
    if isDirectory, try await head(destination) != nil { throw RemoteFileError.alreadyExists(destination) }
    try await checkParents(destination)

    if file != nil {
      try await copy(objectKey(source), to: objectKey(destination))
      try await deleteKey(objectKey(source))
    } else {
      // Every key under the folder, its marker included; copied first, then deleted, so a failure halfway
      // leaves the source whole.
      let keys = try await listKeys(prefix: folderKey(source), delimiter: false, limit: nil).objects.map(\.key)
      let sourcePrefix = folderKey(source)
      let destinationPrefix = folderKey(destination)
      for key in keys { try await copy(key, to: destinationPrefix + key.dropFirst(sourcePrefix.count)) }
      for key in keys { try await deleteKey(key) }
    }
    try await keepFolder(RemotePath.parent(source))
  }

  public func delete(_ path: String) async throws {
    let path = try RemotePath.normalize(path)
    guard !path.isEmpty else { throw RemoteFileError.invalidPath(path) }
    if try await head(path) != nil {
      try await deleteKey(objectKey(path))
    } else {
      let marker = folderKey(path)
      let inside = try await listKeys(prefix: marker, delimiter: false, limit: 2).objects.map(\.key)
      if inside.isEmpty { throw RemoteFileError.notFound(path) }
      if inside != [marker] { throw RemoteFileError.directoryNotEmpty(path) }
      try await deleteKey(marker)
    }
    try await keepFolder(RemotePath.parent(path))
  }

  // MARK: Keys

  /// The object key for a path ("" is the root folder: the prefix itself).
  func objectKey(_ path: String) -> String {
    RemotePath.join(configuration.prefix, path)
  }

  /// The key prefix of a folder's contents, ending in `/` ("" for the bucket's root).
  func folderKey(_ path: String) -> String {
    let key = objectKey(path)
    return key.isEmpty ? "" : key + "/"
  }

  // MARK: Requests

  private func head(_ path: String) async throws -> RemoteFileInfo? {
    let response = try await send("HEAD", key: objectKey(path))
    switch response.status {
    case 200:
      let size = response.headers["content-length"].flatMap(Int64.init) ?? 0
      return RemoteFileInfo(
        path: path, isDirectory: false, size: size, modified: response.headers["last-modified"].flatMap(Self.httpDate))
    case 404: return nil
    default: throw Self.error(response)
    }
  }

  /// Whether any key (a marker or a file) sits under `path/`.
  private func isFolder(_ path: String) async throws -> Bool {
    path.isEmpty ? true : try await !listKeys(prefix: folderKey(path), delimiter: false, limit: 1).objects.isEmpty
  }

  /// Refuses a write where a folder is, or under a file.
  private func checkWritable(_ path: String) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { if try await isFolder(path) { throw RemoteFileError.isADirectory(path) } }
      group.addTask { try await checkParents(path) }
      try await group.waitForAll()
    }
  }

  /// Refuses a path whose parent folders include a file.
  private func checkParents(_ path: String) async throws {
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count > 1 else { return }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 1..<parts.count {
        let parent = parts[..<index].joined(separator: "/")
        group.addTask { if try await head(parent) != nil { throw RemoteFileError.notADirectory(parent) } }
      }
      try await group.waitForAll()
    }
  }

  /// A folder that no longer holds anything gets a marker, so it stays.
  private func keepFolder(_ path: String) async throws {
    guard !path.isEmpty, try await !isFolder(path) else { return }
    try await putMarker(path)
  }

  private func putMarker(_ path: String) async throws {
    let response = try await send("PUT", key: folderKey(path), headers: ["content-type": "application/x-directory"])
    guard response.status == 200 else { throw Self.error(response) }
  }

  private func copy(_ source: String, to destination: String) async throws {
    let copySource = AWSSignatureV4.encodePath("/" + configuration.bucket + "/" + source)
    let response = try await send("PUT", key: destination, headers: ["x-amz-copy-source": copySource])
    // A copy can fail after the 200 has been sent: the body then holds an <Error>.
    guard response.status == 200, S3XML.parse(response.body)?.name != "Error" else { throw Self.error(response) }
  }

  private func deleteKey(_ key: String) async throws {
    let response = try await send("DELETE", key: key)
    guard response.status == 204 || response.status == 200 || response.status == 404 else { throw Self.error(response) }
  }

  struct Listing {
    struct Object {
      var key: String
      var size: Int64
      var modified: Date?
    }
    var objects: [Object] = []
    var folders: [String] = []
  }

  /// ListObjectsV2, following continuation tokens until `limit` keys (or all).
  func listKeys(prefix: String, delimiter: Bool, limit: Int?) async throws -> Listing {
    var listing = Listing()
    var token: String?
    repeat {
      var query = [("list-type", "2"), ("prefix", prefix)]
      if delimiter { query.append(("delimiter", "/")) }
      let wanted = limit.map { $0 - listing.objects.count - listing.folders.count } ?? pageSize
      query.append(("max-keys", String(min(pageSize, wanted))))
      if let token { query.append(("continuation-token", token)) }
      let response = try await send("GET", key: nil, query: query)
      guard response.status == 200 else { throw Self.error(response) }
      guard let root = S3XML.parse(response.body), root.name == "ListBucketResult" else {
        throw S3Error.invalidResponse("the bucket listing isn’t readable")
      }
      for contents in root.children("Contents") {
        guard let key = contents.child("Key")?.text else { continue }
        listing.objects.append(
          .init(
            key: key, size: contents.child("Size").flatMap { Int64($0.text) } ?? 0,
            modified: contents.child("LastModified").flatMap { Self.isoDate($0.text) }))
      }
      listing.folders += root.children("CommonPrefixes").compactMap { $0.child("Prefix")?.text }
      let truncated = root.child("IsTruncated")?.text == "true"
      token = truncated ? root.child("NextContinuationToken")?.text : nil
      if let limit, listing.objects.count + listing.folders.count >= limit { break }
    } while token != nil
    return listing
  }

  /// Signs and sends a request for `key` (nil for the bucket itself).
  func send(
    _ method: String, key: String?, query: [(String, String)] = [], headers: [String: String] = [:],
    body: Data = Data()
  ) async throws -> S3Response {
    let endpoint = configuration.endpoint
    let base = endpoint.path.hasSuffix("/") ? String(endpoint.path.dropLast()) : endpoint.path
    var host = endpoint.host ?? ""
    var path: String
    if configuration.usesVirtualHost {
      host = configuration.bucket + "." + host
      path = base + "/" + (key ?? "")
    } else {
      path = base + "/" + configuration.bucket + (key.map { "/" + $0 } ?? "")
    }
    if path.isEmpty { path = "/" }
    if let port = endpoint.port { host += ":\(port)" }
    var signedHeaders = headers
    signedHeaders["host"] = host
    let payloadHash = AWSSignatureV4.payloadHash(body)
    signedHeaders.merge(
      signer.sign(method: method, path: path, query: query, headers: signedHeaders, payloadHash: payloadHash, date: clock())
    ) { _, new in new }
    let queryString = AWSSignatureV4.canonicalQuery(query)
    let text = "\(endpoint.scheme ?? "https")://\(host)\(AWSSignatureV4.encodePath(path))"
      + (queryString.isEmpty ? "" : "?" + queryString)
    guard let url = URL(string: text) else { throw S3Error.invalidConfiguration("“\(text)” isn’t a valid address.") }
    return try await transport.send(S3Request(method: method, url: url, headers: signedHeaders, body: body))
  }

  static func error(_ response: S3Response) -> Error {
    let xml = S3XML.parse(response.body)
    let code = xml?.child("Code")?.text ?? ""
    var message = xml?.child("Message")?.text ?? ""
    if code == "PermanentRedirect" || code == "AuthorizationHeaderMalformed",
      let region = xml?.child("Region")?.text ?? response.headers["x-amz-bucket-region"]
    {
      message = "Use the region “\(region)”."
    } else if code.isEmpty, let region = response.headers["x-amz-bucket-region"], response.status == 301 {
      return S3Error.server(status: 301, code: "PermanentRedirect", message: "Use the region “\(region)”.")
    }
    return S3Error.server(status: response.status, code: code, message: message)
  }

  // MARK: Dates

  static func isoDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }

  /// `Wed, 12 Oct 2009 17:50:00 GMT`.
  static func httpDate(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: text)
  }
}

extension RemotePath {
  /// A single name a path can hold (S3 keys can have empty, `.` or `..` parts, which the file system skips).
  static func isPlainName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }
}
