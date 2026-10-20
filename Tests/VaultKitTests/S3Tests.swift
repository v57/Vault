import Foundation
import Testing

@testable import VaultKit

/// Signature V4 against the examples AWS publishes ("Signature Calculations for the Authorization Header:
/// Transferring Payload in a Single Chunk", Amazon S3 API reference): each step's text and the signature.
struct AWSSignatureV4Tests {
  let signer = AWSSignatureV4(
    accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region: "us-east-1")
  /// 2013-05-24T00:00:00Z
  let date = Date(timeIntervalSince1970: 1_369_353_600)
  let host = "examplebucket.s3.amazonaws.com"
  let empty = AWSSignatureV4.emptyPayloadHash

  @Test func getObjectWithARange() {
    let headers = [
      "host": host, "range": "bytes=0-9", "x-amz-content-sha256": empty, "x-amz-date": "20130524T000000Z",
    ]
    let canonical = signer.canonicalRequest(
      method: "GET", path: "/test.txt", query: [], headers: headers, payloadHash: empty)
    #expect(
      canonical == """
        GET
        /test.txt

        host:examplebucket.s3.amazonaws.com
        range:bytes=0-9
        x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        x-amz-date:20130524T000000Z

        host;range;x-amz-content-sha256;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """)
    let toSign = signer.stringToSign(canonicalRequest: canonical, date: date)
    #expect(
      toSign == """
        AWS4-HMAC-SHA256
        20130524T000000Z
        20130524/us-east-1/s3/aws4_request
        7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972
        """)
    #expect(
      signer.signature(stringToSign: toSign, date: date)
        == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")

    // The whole header, as `sign` makes it.
    let added = signer.sign(
      method: "GET", path: "/test.txt", headers: ["host": host, "range": "bytes=0-9"], payloadHash: empty, date: date)
    #expect(
      added["Authorization"]
        == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    )
    #expect(added["x-amz-date"] == "20130524T000000Z")
    #expect(added["x-amz-content-sha256"] == empty)
    #expect(added["host"] == nil)
  }

  @Test func putObject() {
    let body = Data("Welcome to Amazon S3.".utf8)
    let payload = AWSSignatureV4.payloadHash(body)
    #expect(payload == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
    let headers = [
      "date": "Fri, 24 May 2013 00:00:00 GMT", "host": host, "x-amz-content-sha256": payload,
      "x-amz-date": "20130524T000000Z", "x-amz-storage-class": "REDUCED_REDUNDANCY",
    ]
    // The key "test$file.text" goes out encoded.
    let canonical = signer.canonicalRequest(
      method: "PUT", path: "/test$file.text", query: [], headers: headers, payloadHash: payload)
    #expect(
      canonical == """
        PUT
        /test%24file.text

        date:Fri, 24 May 2013 00:00:00 GMT
        host:examplebucket.s3.amazonaws.com
        x-amz-content-sha256:44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
        x-amz-date:20130524T000000Z
        x-amz-storage-class:REDUCED_REDUNDANCY

        date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class
        44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
        """)
    let toSign = signer.stringToSign(canonicalRequest: canonical, date: date)
    #expect(toSign.hasSuffix("\n9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d"))
    #expect(
      signer.signature(stringToSign: toSign, date: date)
        == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
  }

  @Test func listObjects() {
    let headers = ["host": host, "x-amz-content-sha256": empty, "x-amz-date": "20130524T000000Z"]
    // Query items sort by name, whatever order they come in.
    let canonical = signer.canonicalRequest(
      method: "GET", path: "/", query: [("prefix", "J"), ("max-keys", "2")], headers: headers, payloadHash: empty)
    #expect(
      canonical == """
        GET
        /
        max-keys=2&prefix=J
        host:examplebucket.s3.amazonaws.com
        x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        x-amz-date:20130524T000000Z

        host;x-amz-content-sha256;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """)
    let toSign = signer.stringToSign(canonicalRequest: canonical, date: date)
    #expect(toSign.hasSuffix("\ndf57d21db20da04d7fa30298dd4488ba3a2b47ca3a489c74750e0f1e7df1b9b7"))
    #expect(
      signer.signature(stringToSign: toSign, date: date)
        == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
  }

  @Test func getBucketLifecycle() {
    let headers = ["host": host, "x-amz-content-sha256": empty, "x-amz-date": "20130524T000000Z"]
    let canonical = signer.canonicalRequest(
      method: "GET", path: "/", query: [("lifecycle", "")], headers: headers, payloadHash: empty)
    #expect(canonical.split(separator: "\n", omittingEmptySubsequences: false)[2] == "lifecycle=")
    let toSign = signer.stringToSign(canonicalRequest: canonical, date: date)
    #expect(
      signer.signature(stringToSign: toSign, date: date)
        == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
  }

  @Test func encoding() {
    #expect(AWSSignatureV4.encodePath("/bucket/a b/ü+x~y.z") == "/bucket/a%20b/%C3%BC%2Bx~y.z")
    #expect(AWSSignatureV4.encodePath("/bucket/dir/") == "/bucket/dir/")
    #expect(AWSSignatureV4.canonicalQuery([("prefix", "a/b c"), ("delimiter", "/")]) == "delimiter=%2F&prefix=a%2Fb%20c")
    #expect(AWSSignatureV4.canonicalQuery([("b", "1"), ("a", "2"), ("a", "1")]) == "a=1&a=2&b=1")
  }

  @Test func sessionTokensAreSigned() {
    var signer = signer
    signer.sessionToken = "token"
    let added = signer.sign(method: "GET", path: "/", headers: ["host": host], payloadHash: empty, date: date)
    #expect(added["x-amz-security-token"] == "token")
    #expect(added["Authorization"]?.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token") == true)
  }
}

struct S3FileSystemTests {
  static func fileSystem(
    _ fake: FakeS3, endpoint: String = "http://127.0.0.1:9000", prefix: String = "", pageSize: Int = 1000,
    secret: String? = nil, addressing: S3Configuration.Addressing = .automatic
  ) throws -> S3FileSystem {
    let configuration = try S3Configuration(
      endpoint: endpoint, bucket: fake.bucket, region: fake.region, accessKeyID: fake.accessKeyID,
      secretAccessKey: secret ?? fake.secretAccessKey, prefix: prefix, addressing: addressing)
    return S3FileSystem(configuration: configuration, transport: fake, pageSize: pageSize)
  }

  @Test func listsPageByPage() async throws {
    let fake = FakeS3()
    let fs = try Self.fileSystem(fake, pageSize: 2)
    for index in 0..<7 { try await fs.write(Data([UInt8(index)]), to: "many/file\(index)") }
    try await fs.createDirectory("many/sub")
    await fake.clearLog()
    let entries = try await fs.list("many")
    #expect(entries.map(\.name) == (0..<7).map { "file\($0)" } + ["sub"])
    #expect(entries.last?.isDirectory == true)
    #expect(entries.first?.size == 1)
    #expect(entries.first?.modified == Date(timeIntervalSince1970: 1_700_000_000))
    let lists = await fake.log.filter { $0.contains("list-type=2") }
    #expect(lists.count == 4)
    #expect(lists.dropFirst().allSatisfy { $0.contains("continuation-token=") })
  }

  @Test func foldersWithoutMarkers() async throws {
    // Keys another tool wrote: no folder markers.
    let fake = FakeS3(objects: ["photos/2024/a.jpg": Data("a".utf8), "photos/2024/b.jpg": Data("bb".utf8), "top": Data()])
    let fs = try Self.fileSystem(fake)
    #expect(try await fs.list("").map(\.path) == ["photos", "top"])
    #expect(try await fs.list("photos").map(\.path) == ["photos/2024"])
    #expect(try await fs.stat("photos/2024")?.isDirectory == true)
    let file = try #require(try await fs.stat("photos/2024/b.jpg"))
    #expect(file.size == 2 && !file.isDirectory)
    #expect(file.modified == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(try await fs.stat("photos/20") == nil)
  }

  @Test func staysUnderItsPrefix() async throws {
    let fake = FakeS3(objects: ["other/x": Data("x".utf8)])
    let fs = try Self.fileSystem(fake, prefix: "/vault/devices/")
    try await fs.write(Data("1".utf8), to: "a/b.txt")
    try await fs.createDirectory("empty")
    #expect(await fake.keys == ["other/x", "vault/devices/a/b.txt", "vault/devices/empty/"])
    #expect(try await fs.list("").map(\.name) == ["a", "empty"])
    #expect(try await fs.list("empty").isEmpty)
    try await fs.rename("a", to: "c/a")
    #expect(await fake.keys == ["other/x", "vault/devices/c/a/b.txt", "vault/devices/empty/"])
  }

  @Test func addressing() async throws {
    let fake = FakeS3()
    // AWS: the bucket in the host name.
    let aws = try Self.fileSystem(fake, endpoint: "s3.us-east-1.amazonaws.com")
    try await aws.write(Data("x".utf8), to: "dir/a b.txt")
    _ = try await aws.read("dir/a b.txt")
    #expect(await fake.log.contains("HEAD vault-test.s3.us-east-1.amazonaws.com /dir"))
    #expect(await fake.log.contains("GET vault-test.s3.us-east-1.amazonaws.com /?list-type=2&max-keys=1&prefix=dir%2Fa%20b.txt%2F"))
    #expect(await fake.log.contains("PUT vault-test.s3.us-east-1.amazonaws.com /dir/a%20b.txt"))
    await fake.clearLog()
    // Anything else (MinIO, R2): the bucket in the path, the port kept.
    let minio = try Self.fileSystem(fake, endpoint: "http://nas.local:9000")
    #expect(try await minio.read("dir/a b.txt") == Data("x".utf8))
    #expect(await fake.log == ["GET nas.local /vault-test/dir/a%20b.txt"])
    await fake.clearLog()
    _ = try await minio.list("")
    #expect(await fake.log == ["GET nas.local /vault-test?delimiter=%2F&list-type=2&max-keys=1000&prefix="])
    // Forced path style on AWS.
    await fake.clearLog()
    _ = try await Self.fileSystem(fake, endpoint: "https://s3.amazonaws.com", addressing: .path).read("dir/a b.txt")
    #expect(await fake.log == ["GET s3.amazonaws.com /vault-test/dir/a%20b.txt"])
  }

  @Test func regions() throws {
    #expect(S3Configuration.region(forHost: "s3.eu-central-1.amazonaws.com") == "eu-central-1")
    #expect(S3Configuration.region(forHost: "s3-us-west-2.amazonaws.com") == "us-west-2")
    #expect(S3Configuration.region(forHost: "s3.dualstack.ap-south-1.amazonaws.com") == "ap-south-1")
    #expect(S3Configuration.region(forHost: "s3.amazonaws.com") == "us-east-1")
    #expect(S3Configuration.region(forHost: "0123abcd.r2.cloudflarestorage.com") == "auto")
    #expect(S3Configuration.region(forHost: "s3.us-west-004.backblazeb2.com") == "us-west-004")
    #expect(S3Configuration.region(forHost: "minio.local") == "us-east-1")

    let r2 = try S3Configuration(
      endpoint: "0123abcd.r2.cloudflarestorage.com", bucket: "b", region: "", accessKeyID: "k", secretAccessKey: "s")
    #expect(r2.region == "auto" && r2.endpoint.absoluteString == "https://0123abcd.r2.cloudflarestorage.com")
    #expect(!r2.usesVirtualHost)
    let aws = try S3Configuration(endpoint: "", bucket: "b-1", region: "eu-west-3", accessKeyID: "k", secretAccessKey: "s")
    #expect(aws.endpoint.absoluteString == "https://s3.eu-west-3.amazonaws.com" && aws.usesVirtualHost)
    let dotted = try S3Configuration(endpoint: "", bucket: "my.bucket", region: "", accessKeyID: "k", secretAccessKey: "s")
    #expect(dotted.region == "us-east-1" && !dotted.usesVirtualHost)
    #expect(throws: S3Error.self) {
      try S3Configuration(endpoint: "ftp://x", bucket: "b", region: "", accessKeyID: "k", secretAccessKey: "s")
    }
    #expect(throws: S3Error.self) {
      try S3Configuration(endpoint: "", bucket: " ", region: "", accessKeyID: "k", secretAccessKey: "s")
    }
  }

  @Test func r2SignsForRegionAuto() async throws {
    let fake = FakeS3(region: "auto")
    let configuration = try S3Configuration(
      endpoint: "https://acc.r2.cloudflarestorage.com", bucket: fake.bucket, region: "", accessKeyID: fake.accessKeyID,
      secretAccessKey: fake.secretAccessKey)
    let fs = S3FileSystem(configuration: configuration, transport: fake)
    try await fs.write(Data("r2".utf8), to: "x")
    #expect(try await fs.read("x") == Data("r2".utf8))
  }

  @Test func serverErrors() async throws {
    let fake = FakeS3()
    let wrongSecret = try Self.fileSystem(fake, secret: "wrong")
    await #expect(throws: S3Error.server(status: 403, code: "SignatureDoesNotMatch", message: "")) {
      try await wrongSecret.list("")
    }
    let wrongBucket = S3FileSystem(
      configuration: S3Configuration(
        endpoint: URL(string: "http://127.0.0.1:9000")!, bucket: "nope", region: fake.region,
        accessKeyID: fake.accessKeyID, secretAccessKey: fake.secretAccessKey),
      transport: fake)
    do {
      _ = try await wrongBucket.stat("x")
      Issue.record("expected an error")
    } catch let error as S3Error {
      #expect(error == .server(status: 404, code: "NoSuchBucket", message: ""))
      #expect(error.localizedDescription == "The bucket doesn’t exist.")
    }
  }

  @Test func factory() throws {
    let s3 = VaultRemote(
      name: "R2", kind: .s3, endpoint: "acc.r2.cloudflarestorage.com", bucket: "backup", path: "vault",
      accessKeyID: "key")
    let fs = try #require(try RemoteConnections.fileSystem(for: s3, secret: "secret", transport: FakeS3()) as? S3FileSystem)
    #expect(fs.configuration.region == "auto")
    #expect(fs.configuration.prefix == "vault")
    #expect(fs.configuration.secretAccessKey == "secret")
    #expect(throws: S3Error.self) { try RemoteConnections.fileSystem(for: s3, secret: nil) }
    for kind in [VaultRemote.Kind.sftp, .smb, .icloud, .ftp] {
      #expect(try RemoteConnections.fileSystem(for: VaultRemote(kind: kind), secret: "x") == nil)
    }
  }
}
