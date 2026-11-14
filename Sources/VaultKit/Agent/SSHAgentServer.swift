#if os(macOS)
  import Darwin
  import Foundation

  /// The agent's Unix socket: accepts connections from processes of this user, reads framed requests and writes what
  /// `handle` answers. It lives in the process that starts it (Vault), never a helper; `stop()` closes it and removes the
  /// file, and a file left by a crash is replaced at the next `start()`.
  public final class SSHAgentServer: @unchecked Sendable {
    /// One request on one connection: who connected (`pid`), and a number that's the same for every request of that
    /// connection (one `ssh` run lists keys, then signs).
    public struct Context: Sendable {
      public let pid: pid_t
      public let connection: Int
    }

    public typealias Handler = @Sendable (SSHAgentProtocol.Request, Context) async -> Data
    /// Called once a connection closes, with its number.
    public typealias Closed = @Sendable (Int) -> Void

    public let path: URL
    private let handle: Handler
    private let closed: Closed
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var connections: Set<Int32> = []
    private var nextConnection = 0

    public init(path: URL, handle: @escaping Handler, closed: @escaping Closed = { _ in }) {
      self.path = path
      self.handle = handle
      self.closed = closed
    }

    public var isRunning: Bool { lock.withLock { listener >= 0 } }

    public enum ServerError: LocalizedError {
      case pathTooLong
      case failed(String, Int32)

      public var errorDescription: String? {
        switch self {
        case .pathTooLong: "The agent's socket path is too long for a Unix socket."
        case .failed(let call, let code): "Couldn’t open the agent’s socket (\(call): \(String(cString: strerror(code))))."
        }
      }
    }

    public func start() throws {
      guard !isRunning else { return }
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      unlink(path.path)
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.path.utf8)
      guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ServerError.pathTooLong }
      withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
      }
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw ServerError.failed("socket", errno) }
      // Only this user, from the moment it exists: bind under a umask, then make sure.
      let previous = umask(0o077)
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      umask(previous)
      guard bound == 0 else {
        let code = errno
        close(fd)
        throw ServerError.failed("bind", code)
      }
      chmod(path.path, 0o600)
      guard listen(fd, 16) == 0 else {
        let code = errno
        close(fd)
        unlink(path.path)
        throw ServerError.failed("listen", code)
      }
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
      source.setEventHandler { [weak self] in self?.accept(on: fd) }
      source.setCancelHandler { close(fd) }
      lock.withLock {
        listener = fd
        self.source = source
      }
      source.resume()
    }

    public func stop() {
      let (source, open) = lock.withLock {
        defer {
          listener = -1
          self.source = nil
          connections = []
        }
        return (self.source, connections)
      }
      guard let source else { return }
      source.cancel()
      // Wakes the connections' blocked reads; each closes its own descriptor.
      for fd in open { shutdown(fd, SHUT_RDWR) }
      unlink(path.path)
    }

    deinit { stop() }

    private func accept(on listener: Int32) {
      while true {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Another user's process can't reach the file (0600), but check its credentials anyway.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
          close(fd)
          continue
        }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size)
        let number = lock.withLock {
          nextConnection += 1
          connections.insert(fd)
          return nextConnection
        }
        let context = Context(pid: pid, connection: number)
        Thread.detachNewThread { [self] in serve(fd, context: context) }
      }
    }

    /// One connection, on its own thread: blocking reads, one request at a time, as clients send them.
    private func serve(_ fd: Int32, context: Context) {
      defer {
        lock.withLock { _ = connections.remove(fd) }
        close(fd)
        closed(context.connection)
      }
      while let header = read(fd, count: 4) {
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= SSHAgentProtocol.maximumLength, let body = read(fd, count: length) else { return }
        let reply: Data
        if let request = SSHAgentProtocol.request(body) {
          let box = ReplyBox()
          let done = DispatchSemaphore(value: 0)
          let handle = self.handle
          Task.detached {
            box.value = await handle(request, context)
            done.signal()
          }
          done.wait()
          reply = box.value
        } else {
          reply = SSHAgentProtocol.failureMessage
        }
        guard write(fd, SSHAgentProtocol.framed(reply)) else { return }
      }
    }

    private final class ReplyBox: @unchecked Sendable {
      var value = SSHAgentProtocol.failureMessage
    }

    private func read(_ fd: Int32, count: Int) -> Data? {
      var data = Data(count: count)
      var done = 0
      while done < count {
        let got = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + done, count - done) }
        if got < 0, errno == EINTR { continue }
        guard got > 0 else { return nil }
        done += got
      }
      return data
    }

    private func write(_ fd: Int32, _ data: Data) -> Bool {
      var done = 0
      while done < data.count {
        let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, data.count - done) }
        if sent < 0, errno == EINTR { continue }
        guard sent > 0 else { return false }
        done += sent
      }
      return true
    }
  }
#endif
