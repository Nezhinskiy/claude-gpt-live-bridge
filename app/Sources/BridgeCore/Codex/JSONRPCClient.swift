import Foundation

/// Any JSON value: codex's messages are read by field, not decoded into full types, so a field
/// codex adds in a later release cannot break them.
public enum JSONValue: Codable, Sendable, Equatable, ExpressibleByStringLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral
{
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(stringLiteral value: String) { self = .string(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements) { $1 })
  }

  /// The JSON form of any encodable value.
  public init(encoding value: some Encodable) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let bool = try? value.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? value.decode(Double.self) {
      self = .number(number)
    } else if let string = try? value.decode(String.self) {
      self = .string(string)
    } else if let array = try? value.decode([JSONValue].self) {
      self = .array(array)
    } else {
      self = .object(try value.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let bool): try container.encode(bool)
    case .number(let number): try container.encode(number)
    case .string(let string): try container.encode(string)
    case .array(let array): try container.encode(array)
    case .object(let object): try container.encode(object)
    }
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { object[key] } else { nil }
  }

  public var string: String? { if case .string(let string) = self { string } else { nil } }
  public var array: [JSONValue]? { if case .array(let array) = self { array } else { nil } }
  public var object: [String: JSONValue]? {
    if case .object(let object) = self { object } else { nil }
  }

  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    if let value = self as? T { return value }
    return try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}

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

public struct RPCError: Error, Codable, Sendable, Equatable {
  public var code: Int
  public var message: String
  public init(code: Int, message: String) {
    self.code = code
    self.message = message
  }
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

  public init(executable: URL, arguments: [String], cwd: URL) {
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice  // codex logs can carry paths and addresses
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    (notifications, notify) = AsyncStream.makeStream()
    (serverRequests, ask) = AsyncStream.makeStream()
  }

  /// Starts the process and its reader.
  public func start() throws {
    signal(SIGPIPE, SIG_IGN)  // a write after codex exits must fail, not end the app
    do { try process.run() } catch { throw CodexProblem.notInstalled }
    let lines = output.fileHandleForReading.bytes.lines
    Task { [weak self] in
      do { for try await line in lines { await self?.receive(line) } } catch {}
      await self?.finish()
    }
  }

  /// Sends a request and waits up to `timeout` for its result. A JSON-RPC error is thrown as
  /// `RPCError`; no reply in time, or codex gone, as `CodexProblem`.
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
        self.resolve(id, .failure(CodexProblem.protocolMismatch("no reply to \(method)")))
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

  private func receive(_ line: String) {
    guard let message = try? JSONDecoder().decode(Incoming.self, from: Data(line.utf8)) else {
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

  /// Runs `codex features list`, starts `codex app-server` with every unwanted feature codex
  /// has turned off, initialises it and checks the ChatGPT sign-in. Throws `CodexProblem`.
  public static func launchVerified(codex: URL, cwd: URL) async throws -> JSONRPCClient {
    let features = try await Self.output(of: codex, ["features", "list"])
    let present = CodexLaunch.presentFeatures(featuresListOutput: features)
    let client = JSONRPCClient(
      executable: codex,
      arguments: CodexLaunch.argv(disable: CodexLaunch.wantDisabled.filter(present.contains)),
      cwd: cwd)
    do {
      try await client.start()
      let hello: JSONValue = [
        "clientInfo": [
          "name": "claude-gpt-live-bridge", "title": "LiveBridge", "version": "0.1.0",
        ],
        "capabilities": ["experimentalApi": true, "requestAttestation": false],
      ]
      let _: JSONValue = try await client.request("initialize", hello, timeout: .seconds(20))
      await client.notify("initialized")
      let account: JSONValue = try await client.request(
        "account/read", JSONValue.object([:]), timeout: .seconds(20))
      guard account["account"]?.object != nil else { throw CodexProblem.notLoggedIn }
      return client
    } catch {
      await client.close()
      throw error is CodexProblem ? error : CodexProblem.protocolMismatch("\(error)")
    }
  }

  private static func output(of executable: URL, _ arguments: [String]) async throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw CodexProblem.notInstalled }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw CodexProblem.exited(process.terminationStatus)
    }
    return String(decoding: data, as: UTF8.self)
  }
}
