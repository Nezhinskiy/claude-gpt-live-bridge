import Foundation

public struct RPCNotification: Sendable, Equatable {
  public var method: String
  public var params: JSONValue
}

/// A request codex sends the client, such as an approval prompt. The bridge declines them all.
public struct RPCServerRequest: Sendable, Equatable {
  public var id: JSONValue
  public var method: String
  public var params: JSONValue
}

public struct RPCError: LocalizedError, Codable, Sendable, Equatable {
  public var code: Int
  public var message: String
  public init(code: Int, message: String) {
    self.code = code
    self.message = message
  }
  public var errorDescription: String? { "Codex refused a request: \(message) (\(code))." }
}

/// The JSON-RPC connection to `codex app-server`; tests put a recording fake behind it.
public protocol RPCClient: Actor {
  func request<P: Encodable & Sendable, R: Decodable & Sendable>(
    _ method: String, _ params: P, timeout: Duration
  ) async throws -> R
  var notifications: AsyncStream<RPCNotification> { get }
  var serverRequests: AsyncStream<RPCServerRequest> { get }
  func reply(to request: RPCServerRequest, error: RPCError) async
  func close() async
}

/// `codex app-server` as a child process speaking newline-delimited JSON-RPC on stdio. The
/// child leads its own process group (Foundation's `Process` does that on macOS), so `close()`
/// also ends anything it started.
public actor JSONRPCClient: RPCClient {
  private struct Outgoing<P: Encodable>: Encodable {
    var id: JSONValue?
    var method: String?
    var params: P?
    var error: RPCError?
  }

  private struct Incoming: Decodable {
    var id: JSONValue?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: RPCError?
  }

  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let encoder = JSONEncoder()
  private var nextID = 1
  private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
  private var ended = false
  public let notifications: AsyncStream<RPCNotification>
  public let serverRequests: AsyncStream<RPCServerRequest>
  private let notify: AsyncStream<RPCNotification>.Continuation
  private let ask: AsyncStream<RPCServerRequest>.Continuation

  public init(executable: URL, arguments: [String], cwd: URL, searchPath: [String] = []) {
    process.executableURL = executable
    process.arguments = arguments
    process.use(searchPath: searchPath)
    process.currentDirectoryURL = cwd
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice  // codex logs can carry paths and addresses
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    (notifications, notify) = AsyncStream.makeStream()
    (serverRequests, ask) = AsyncStream.makeStream()
  }

  /// Starts the process and its reader. Each client reads its own pipe as data arrives:
  /// `FileHandle.bytes` serves every reader in the process from one queue with a blocking
  /// read, so a client waiting on an idle codex would hold up every other client's replies.
  public func start() throws {
    signal(SIGPIPE, SIG_IGN)  // a write after codex exits must fail, not end the app
    do { try process.run() } catch { throw CodexProblem.notInstalled }
    let (chunks, sink) = AsyncStream.makeStream(of: Data.self)
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        sink.finish()
      } else {
        sink.yield(data)
      }
    }
    Task { [weak self] in
      var buffer = Data()
      for await chunk in chunks {
        buffer += chunk
        while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {  // `\n` alone ends a message
          await self?.receive(buffer[..<end])
          buffer = buffer[(end + 1)...]
        }
      }
      await self?.finish()
    }
  }

  /// Sends a request and waits up to `timeout` for its result. A JSON-RPC error is thrown as
  /// `RPCError`; no reply in time as `CodexProblem.timedOut`, codex gone as `.exited`.
  public func request<P: Encodable & Sendable, R: Decodable & Sendable>(
    _ method: String, _ params: P, timeout: Duration
  ) async throws -> R {
    if ended { throw CodexProblem.exited(process.isRunning ? -1 : process.terminationStatus) }
    let id = nextID
    nextID += 1
    let line = try encoder.encode(Outgoing(id: .number(Double(id)), method: method, params: params))
    let result = try await withCheckedThrowingContinuation { reply in
      pending[id] = reply
      send(line)
      Task {
        try? await Task.sleep(for: timeout)
        self.resolve(id, .failure(CodexProblem.timedOut(method)))
      }
    }
    do { return try result.decode(R.self) } catch {
      throw CodexProblem.protocolMismatch("unexpected reply to \(method)")
    }
  }

  /// Sends a notification, such as `initialized`.
  public func notify(_ method: String) {
    guard let line = try? encoder.encode(Outgoing<JSONValue>(method: method)) else { return }
    send(line)
  }

  public func reply(to request: RPCServerRequest, error: RPCError) {
    guard let line = try? encoder.encode(Outgoing<JSONValue>(id: request.id, error: error))
    else { return }
    send(line)
  }

  /// Closes stdin, sends `SIGTERM` to the process group, and `SIGKILL` after 2 s.
  public func close() async {
    try? input.fileHandleForWriting.close()
    let group = process.processIdentifier
    guard group > 0 else { return }  // never started: `kill(0, …)` would signal our own group
    kill(-group, SIGTERM)
    for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
    kill(-group, SIGKILL)
    finish()
  }

  private func send(_ line: Data) {
    try? input.fileHandleForWriting.write(contentsOf: line + Data("\n".utf8))
  }

  private func receive(_ line: Data) {
    guard let message = try? JSONDecoder().decode(Incoming.self, from: line) else {
      return
    }
    switch (message.id, message.method) {
    case (let id?, let method?):
      ask.yield(RPCServerRequest(id: id, method: method, params: message.params ?? .null))
    case (nil, let method?):
      notify.yield(RPCNotification(method: method, params: message.params ?? .null))
    case (.number(let id)?, nil):
      resolve(Int(id), message.error.map { .failure($0) } ?? .success(message.result ?? .null))
    default:
      break
    }
  }

  private func resolve(_ id: Int, _ result: Result<JSONValue, any Error>) {
    pending.removeValue(forKey: id)?.resume(with: result)
  }

  /// codex's output ended: every waiting request fails and the streams finish.
  private func finish() {
    ended = true
    let status = process.isRunning ? -1 : process.terminationStatus
    for id in pending.keys { resolve(id, .failure(CodexProblem.exited(status))) }
    notify.finish()
    ask.finish()
  }
}
