import Foundation

/// The file system for a remote record.
public enum RemoteConnections {
  /// The backend for `remote`, or nil for a kind that has none yet (SFTP is adapted by the app from Database's
  /// `SSHTunnel.SFTPClient`; SMB, FTP and iCloud are still to come). `secret` is the remote's `VaultSecrets`
  /// password (the S3 secret key).
  ///
  /// Making a file system contacts nothing; the first call on it does. Whether the remote is `enabled` is the
  /// caller's to check.
  public static func fileSystem(
    for remote: VaultRemote, secret: String?, transport: (any S3Transport)? = nil
  ) throws -> (any RemoteFileSystem)? {
    switch remote.kind {
    case .s3:
      guard !remote.accessKeyID.isEmpty, let secret, !secret.isEmpty else {
        throw S3Error.invalidConfiguration("The remote “\(remote.displayName)” needs an access key and a secret key.")
      }
      let configuration = try S3Configuration(
        endpoint: remote.endpoint, bucket: remote.bucket, region: remote.region, accessKeyID: remote.accessKeyID,
        secretAccessKey: secret, prefix: remote.path)
      return S3FileSystem(configuration: configuration, transport: transport ?? URLSessionS3Transport())
    case .sftp, .smb, .icloud, .ftp:
      return nil
    }
  }
}
