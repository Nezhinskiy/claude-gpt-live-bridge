import Foundation
import Network
import os

public enum ServerError: LocalizedError, Equatable {
  /// Another process accepts connections on the socket (a second copy of the app).
  case socketInUse(String)
  case startFailed(String)

  public var errorDescription: String? {
    switch self {
    case .socketInUse: "another copy of LiveBridge is already running; quit it first."
    case .startFailed(let reason): "its socket could not be opened (\(reason))."
    }
  }
}

/// A minimal HTTP/1.1 server on a Unix domain socket: one request per connection, bodies framed
/// by `Content-Length` only, at most `maxBodyBytes`. A server starts once; `stop` is final.
public final class UnixHTTPServer: Sendable {
  public static let maxBodyBytes = 131_072
  static let maxHeadBytes = 16_384

  private let socketPath: String
  private let router: any Router
  private let listener: NWListener
  private let queue = DispatchQueue(label: "livebridge.http")
  /// The inode of the socket file this server bound; `stop` removes only that file.
  private let boundInode = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

  public init(socketPath: URL, router: any Router) throws {
    guard socketPath.path.utf8.count <= Paths.maxSocketPathBytes else {
      throw PathsError.socketPathTooLong(socketPath.path)
    }
    self.socketPath = socketPath.path
    self.router = router
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .unix(path: socketPath.path)
    listener = try NWListener(using: parameters)
  }

  /// Binds the socket and returns once the listener is ready. While another process still
  /// accepts on it, tries again every 200 ms for up to `retryFor` (a relaunched app waiting for
  /// the old instance to quit), then throws `socketInUse`.
  public func start(retryFor: Duration = .zero) async throws {
    let deadline = ContinuousClock.now + retryFor
    while true {
      do { return try bind() } catch ServerError.socketInUse where ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(200))
      }
    }
  }

  /// One attempt: replaces a stale socket file that nothing accepts on.
  private func bind() throws {
    if FileManager.default.fileExists(atPath: socketPath) {
      if Self.somethingAccepts(at: socketPath) { throw ServerError.socketInUse(socketPath) }
      try FileManager.default.removeItem(atPath: socketPath)
    }
    let settled = DispatchSemaphore(value: 0)
    let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready: settled.signal()
      case .failed(let error):
        failure.withLock { $0 = "\(error)" }
        settled.signal()
      default: break
      }
    }
    listener.newConnectionHandler = { [router, queue] connection in
      connection.start(queue: queue)
      Self.receive(connection, Data(), router: router)
    }
    listener.start(queue: queue)
    if settled.wait(timeout: .now() + 5) == .timedOut {
      failure.withLock { $0 = "the listener did not become ready" }
    }
    if let reason = failure.withLock({ $0 }) {
      stop()
      throw ServerError.startFailed(reason)
    }
    boundInode.withLock { $0 = Self.inode(at: socketPath) }
  }

  /// Stops listening and removes the socket file, unless another instance has bound a socket at
  /// the path since (an app relaunched after an update binds as soon as this one stops answering).
  public func stop() {
    listener.cancel()
    guard let bound = boundInode.withLock({ $0 }), Self.inode(at: socketPath) == bound else {
      return
    }
    try? FileManager.default.removeItem(atPath: socketPath)
  }

  private static func inode(at path: String) -> UInt64? {
    var info = stat()
    return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
  }

  private static func receive(_ connection: NWConnection, _ buffer: Data, router: any Router) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, end, error in
      let buffer = buffer + (data ?? Data())
      switch HTTPRequest.parse(buffer) {
      case .complete(let request):
        Task { respond(connection, await router.handle(request)) }
      case .rejected(let response):
        respond(connection, response)
      case .incomplete where end || error != nil:
        connection.cancel()
      case .incomplete:
        receive(connection, buffer, router: router)
      }
    }
  }

  private static func respond(_ connection: NWConnection, _ response: HTTPResponse) {
    let head =
      "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
      + "Content-Type: application/json\r\nContent-Length: \(response.body.count)\r\n"
      + "Connection: close\r\n\r\n"
    connection.send(
      content: Data(head.utf8) + response.body, isComplete: true,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  private static func reason(_ status: Int) -> String {
    let reasons = [400: "Bad Request", 404: "Not Found", 409: "Conflict", 413: "Content Too Large"]
    return reasons[status] ?? (status < 400 ? "OK" : "Error")
  }

  /// Whether a process accepts connections on the socket at `path`.
  private static func somethingAccepts(at path: String) -> Bool {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
      }
    }
  }
}

extension HTTPRequest {
  enum Parse: Equatable {
    case incomplete
    case complete(HTTPRequest)
    case rejected(HTTPResponse)
  }

  /// Parses one request from the bytes received so far.
  static func parse(_ buffer: Data) -> Parse {
    guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
      return buffer.count > UnixHTTPServer.maxHeadBytes
        ? .rejected(.error(400, "the request head is too large")) : .incomplete
    }
    let lines = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
      .components(separatedBy: "\r\n")
    let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
      let target = URLComponents(string: String(requestLine[1]))
    else { return .rejected(.error(400, "malformed request line")) }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else {
        return .rejected(.error(400, "malformed header"))
      }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
    }
    if headers["transfer-encoding"] != nil {
      return .rejected(.error(400, "only Content-Length bodies are accepted"))
    }
    guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
      return .rejected(.error(400, "malformed Content-Length"))
    }
    if length > UnixHTTPServer.maxBodyBytes {
      return .rejected(.error(413, "the body is larger than \(UnixHTTPServer.maxBodyBytes) bytes"))
    }
    guard buffer.count - headEnd.upperBound >= length else { return .incomplete }
    let query = (target.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    return .complete(
      HTTPRequest(
        method: String(requestLine[0]), path: target.path,
        query: Dictionary(query, uniquingKeysWith: { _, last in last }),
        body: Data(buffer[headEnd.upperBound..<headEnd.upperBound + length])))
  }
}
