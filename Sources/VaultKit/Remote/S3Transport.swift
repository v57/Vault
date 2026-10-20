import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// One HTTP request to an S3 server, signed.
public struct S3Request: Sendable {
  public var method: String
  public var url: URL
  public var headers: [String: String]
  public var body: Data

  public init(method: String, url: URL, headers: [String: String] = [:], body: Data = Data()) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }
}

public struct S3Response: Sendable {
  public var status: Int
  /// Lowercased names.
  public var headers: [String: String]
  public var body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    self.body = body
  }
}

/// How `S3FileSystem` reaches the server: `URLSessionS3Transport` in the apps, an in-memory bucket in tests.
public protocol S3Transport: Sendable {
  func send(_ request: S3Request) async throws -> S3Response
}

/// The network, through an ephemeral `URLSession` that caches nothing and doesn't follow redirects (a signed
/// request is only valid for the host it was signed for).
public final class URLSessionS3Transport: NSObject, S3Transport, URLSessionTaskDelegate, @unchecked Sendable {
  private let session: URLSession

  public init(timeout: TimeInterval = 60) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = timeout
    session = URLSession(configuration: configuration)
    super.init()
  }

  deinit { session.finishTasksAndInvalidate() }

  public func send(_ request: S3Request) async throws -> S3Response {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    for (name, value) in request.headers where name.lowercased() != "host" {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    if request.method == "PUT" || request.method == "POST" { urlRequest.httpBody = request.body }
    let (data, response) = try await session.data(for: urlRequest, delegate: self)
    guard let http = response as? HTTPURLResponse else { throw S3Error.invalidResponse("not an HTTP response") }
    var headers: [String: String] = [:]
    for (name, value) in http.allHeaderFields {
      if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
    }
    return S3Response(status: http.statusCode, headers: headers, body: data)
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}
