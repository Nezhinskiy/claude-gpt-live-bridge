import Foundation
import Network
import Testing

@testable import BridgeCore

actor RecordingRouter: Router {
  private(set) var requests: [HTTPRequest] = []

  func handle(_ req: HTTPRequest) async -> HTTPResponse {
    requests.append(req)
    return .json(ErrorReply(error: "recorded"))
  }
}

struct UnixHTTPServerTests {
  let socket = FileManager.default.temporaryDirectory
    .appending(path: "lb-\(UUID().uuidString.prefix(8)).sock")
  let router = RecordingRouter()

  func withServer(_ body: () async throws -> Void) async throws {
    let server = try UnixHTTPServer(socketPath: socket, router: router)
    try server.start()
    defer { server.stop() }
    try await body()
  }

  /// Writes `request` to the socket and returns the status and body the server sends back.
  func exchange(_ request: Data) async throws -> (status: Int, body: Data) {
    let connection = NWConnection(to: .unix(path: socket.path), using: .tcp)
    defer { connection.cancel() }
    let reply = await withCheckedContinuation { (done: CheckedContinuation<Data, Never>) in
      connection.start(queue: .global())
      connection.send(content: request, completion: .contentProcessed { _ in })
      Self.readToEnd(connection, Data()) { done.resume(returning: $0) }
    }
    let head = try #require(reply.range(of: Data("\r\n\r\n".utf8)))
    let statusLine = String(decoding: reply[..<head.lowerBound], as: UTF8.self)
    let status = try #require(Int(statusLine.split(separator: " ")[1]))
    return (status, Data(reply[head.upperBound...]))
  }

  static func readToEnd(
    _ connection: NWConnection, _ buffer: Data, then done: @escaping @Sendable (Data) -> Void
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, end, error in
      let buffer = buffer + (data ?? Data())
      if end || error != nil { done(buffer) } else { readToEnd(connection, buffer, then: done) }
    }
  }

  func post(_ path: String, _ body: Data, headers: String = "") -> Data {
    Data(
      "POST \(path) HTTP/1.1\r\nHost: bridge\r\nContent-Length: \(body.count)\r\n\(headers)\r\n"
        .utf8)
      + body
  }

  @Test func routesJoin() async throws {
    FileManager.default.createFile(atPath: socket.path, contents: Data("stale".utf8))
    let join = JoinBody(
      sessionId: SessionID(rawValue: "00000000-0000-0000-0000-000000000001"),
      title: "Example session")
    try await withServer {
      let reply = try await exchange(post("/v1/join", try JSONEncoder().encode(join)))
      #expect(reply.status == 200)
      let seen = try #require(await router.requests.first)
      #expect(seen.method == "POST" && seen.path == "/v1/join")
      #expect(try seen.decodeBody(JoinBody.self) == join)
    }
  }

  @Test func routesPollWithQuery() async throws {
    try await withServer {
      let get = Data("GET /v1/next?sessionId=a%20b HTTP/1.1\r\nHost: bridge\r\n\r\n".utf8)
      let reply = try await exchange(get)
      #expect(reply.status == 200)
      let seen = try #require(await router.requests.first)
      #expect(seen.method == "GET" && seen.path == "/v1/next" && seen.query == ["sessionId": "a b"])
    }
  }

  @Test func rejectsOversizeBody() async throws {
    try await withServer {
      let reply = try await exchange(post("/v1/answer", Data(count: 131_073)))
      #expect(reply.status == 413)
      #expect(await router.requests.isEmpty)
    }
  }

  @Test func rejectsChunked() async throws {
    try await withServer {
      let chunked = Data(
        "POST /v1/answer HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n".utf8)
      let reply = try await exchange(chunked)
      #expect(reply.status == 400)
      #expect(await router.requests.isEmpty)
    }
  }

  @Test func secondServerDoesNotStealTheSocket() async throws {
    try await withServer {
      let second = try UnixHTTPServer(socketPath: socket, router: router)
      #expect(throws: ServerError.socketInUse(socket.path)) { try second.start() }
    }
  }

  @Test func tooLongSocketPathIsAClearError() {
    let path = "/private/tmp/" + String(repeating: "a", count: 91)
    #expect(path.utf8.count == 104)
    #expect(throws: PathsError.socketPathTooLong(path)) {
      try UnixHTTPServer(socketPath: URL(filePath: path), router: router)
    }
  }
}
