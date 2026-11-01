import Foundation
import Testing

@testable import BridgeCore

/// Records every request and answers from canned replies, by default the ADR 0001 fixtures.
actor FakeRPC: RPCClient {
  var calls: [(method: String, params: JSONValue)] = []
  var replies: [String: [JSONValue]]
  var declined: [JSONValue] = []
  /// Notifications pushed when `thread/realtime/start` is called.
  var onStart: [JSONValue]
  let notifications: AsyncStream<RPCNotification>
  let serverRequests: AsyncStream<RPCServerRequest>
  private let notify: AsyncStream<RPCNotification>.Continuation
  let ask: AsyncStream<RPCServerRequest>.Continuation

  init() throws {
    replies = [
      "config/read": [
        ["config": ["mcp_servers": ["example-stdio": ["command": "example"], "example-http": [:]]]]
      ],
      "thread/start": [try #require(adrJSON("thread-start-result")["result"])],
      "mcpServerStatus/list": [
        try #require(adrJSON("mcp-server-status-list-all-disabled")["result"])
      ],
    ]
    onStart = [try adrJSON("realtime-sdp")]
    (notifications, notify) = AsyncStream.makeStream()
    (serverRequests, ask) = AsyncStream.makeStream()
  }

  func set(_ method: String, _ values: [JSONValue]) { replies[method] = values }
  func setOnStart(_ values: [JSONValue]) { onStart = values }

  func request<P: Encodable & Sendable, R: Decodable & Sendable>(
    _ method: String, _ params: P, timeout: Duration
  ) async throws -> R {
    calls.append((method, try JSONValue(encoding: params)))
    var queue = replies[method] ?? [[:]]
    let reply = queue.count > 1 ? queue.removeFirst() : queue[0]
    replies[method] = queue
    if method == "thread/realtime/start" { onStart.forEach(push) }
    return try reply.decode(R.self)
  }

  nonisolated func push(_ message: JSONValue) {
    notify.yield(
      RPCNotification(method: message["method"]?.string ?? "", params: message["params"]!))
  }

  func reply(to request: RPCServerRequest, error: RPCError) { declined.append(request.id) }
  func close() {}

  func params(_ method: String) -> [JSONValue] {
    calls.filter { $0.method == method }.map(\.params)
  }
}

/// A fixture with its `params` fields changed.
func adrJSON(_ name: String, params changes: [String: JSONValue]) throws -> JSONValue {
  var message = try #require(adrJSON(name).object)
  message["params"] = .object(try #require(message["params"]?.object).merging(changes) { $1 })
  return .object(message)
}

/// A wrong reply leaves a test waiting for an event, so each test has a time limit.
@Suite(.timeLimit(.minutes(1)))
struct RealtimeSessionTests {
  let rpc: FakeRPC
  let session: RealtimeSession
  let cwd = URL(
    filePath: "/Users/example/Library/Application Support/claude-gpt-live-bridge/codex-cwd")
  let thread: JSONValue = "00000000-0000-0000-0000-000000000001"

  init() throws {
    rpc = try FakeRPC()
    session = RealtimeSession(client: rpc, voice: nil, cwd: cwd)
  }

  @Test func openSendsPinnedParams() async throws {
    let items = [InitialItem(role: .developer, text: "[CONTEXT] Example session: a summary.")]
    let answer = try await session.open(offerSDP: "offer", items: items)
    #expect(answer == (try adrJSON("realtime-sdp")["params"]?["sdp"]?.string))
    #expect(
      await rpc.calls.map(\.method) == [
        "config/read", "thread/start", "mcpServerStatus/list", "thread/realtime/start",
      ])
    let start = try #require(await rpc.params("thread/start").first)
    #expect(start["sandbox"] == "read-only" && start["approvalPolicy"] == "never")
    #expect(start["ephemeral"] == true && start["cwd"]?.string == cwd.path)
    let off: JSONValue = ["enabled": false]
    #expect(start["config"] == ["mcp_servers": ["example-stdio": off, "example-http": off]])
    #expect(await rpc.params("mcpServerStatus/list").first?["threadId"] == thread)
    let realtime = try #require(await rpc.params("thread/realtime/start").first)
    #expect(realtime["threadId"] == thread && realtime["version"] == "v3")
    #expect(realtime["outputModality"] == "audio")
    #expect(realtime["transport"] == ["type": "webrtc", "sdp": "offer"])
    #expect(realtime["includeStartupContext"] == false)
    #expect(realtime["clientManagedHandoffs"] == true && realtime["delegationAckFiller"] == true)
    #expect(realtime["prompt"]?.string == VoicePrompt.text)
    #expect(realtime["initialItems"] == (try JSONValue(encoding: items)))
  }

  @Test func openRefusesWhenAServerIsEnabled() async throws {
    let enabled = try #require(adrJSON("mcp-server-status-list-one-connected")["result"])
    await rpc.set("mcpServerStatus/list", [enabled])
    await #expect(throws: CodexProblem.mcpNotDisabled(["example-http"])) {
      try await session.open(offerSDP: "offer", items: [])
    }
    #expect(await rpc.params("thread/realtime/start").isEmpty)
  }

  @Test func openReadsEveryStatusPage() async throws {
    var first = try #require(adrJSON("mcp-server-status-list-all-disabled")["result"]?.object)
    first["nextCursor"] = "page-2"
    let second = try #require(adrJSON("mcp-server-status-list-one-connected")["result"])
    await rpc.set("mcpServerStatus/list", [.object(first), second])
    await #expect(throws: CodexProblem.mcpNotDisabled(["example-http"])) {
      try await session.open(offerSDP: "offer", items: [])
    }
    #expect(await rpc.params("mcpServerStatus/list").map { $0["cursor"] } == [nil, "page-2"])
  }

  @Test func realtimeErrorFailsOpen() async throws {
    let error = try adrJSON("realtime-error-version-unsupported", params: ["threadId": thread])
    await rpc.setOnStart([error])
    let message = "AVAS realtime calls require realtime v1 or v3"
    await #expect(throws: CodexProblem.realtimeError(message)) {
      try await session.open(offerSDP: "offer", items: [])
    }
  }

  @Test func errorThenCloseReportsTheProblem() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    rpc.push(try adrJSON("realtime-error-version-unsupported", params: ["threadId": thread]))
    rpc.push(try adrJSON("realtime-closed-error", params: ["threadId": thread]))
    var events = session.events.makeAsyncIterator()
    let sentence = CodexProblem.realtimeError("AVAS realtime calls require realtime v1 or v3")
      .sentence
    #expect(await events.next() == .closed(sentence))
  }

  @Test func startingServerClosesSession() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    rpc.push(try adrJSON("mcp-server-startup-status-starting"))
    var events = session.events.makeAsyncIterator()
    #expect(await events.next() == .closed(CodexProblem.mcpNotDisabled(["example-http"]).sentence))
    #expect(await rpc.params("thread/realtime/stop") == [["threadId": thread]])
  }

  @Test func failedServerIsIgnored() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    rpc.push(try adrJSON("mcp-server-startup-status-starting", params: ["status": "failed"]))
    rpc.push(try adrJSON("realtime-transcript-done-user"))
    var events = session.events.makeAsyncIterator()
    #expect(await events.next() == .userUtterance("Please list the files in this folder"))
  }

  @Test func turnStartedIsInterrupted() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    rpc.push(try adrJSON("turn-started"))
    let expected = try #require(adrJSON("turn-interrupt-request")["params"])
    #expect(await eventually { await rpc.params("turn/interrupt") == [expected] })
  }

  @Test func handoffItemBecomesRequest() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    let handoff = try adrJSON("realtime-item-added-handoff-request")
    rpc.push(handoff)
    rpc.push(handoff)  // the same handoff again is not a second request
    rpc.push(try adrJSON("realtime-transcript-done-assistant"))
    var events = session.events.makeAsyncIterator()
    let words = "Please list the files in this folder"
    let request = VoiceRequest(
      id: RequestID("item_000000000000000000001"), brief: words,
      transcript: [Utterance(role: .user, text: words)])
    #expect(await events.next() == .handoff(request))
    #expect(await events.next() == .assistantUtterance("I'm pulling up the folder now."))
    #expect(await events.next() == .assistantDone)
  }

  @Test func resultsAreAddedAsUserText() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    let observed = try #require(adrJSON("realtime-append-text-request")["params"]?.object)
    try await session.addContext(try #require(observed["text"]?.string))
    let sent = try #require(await rpc.params("thread/realtime/appendText").first?.object)
    #expect(sent["role"] == observed["role"] && sent["text"] == observed["text"])
    #expect(sent["threadId"] == thread)
  }

  @Test func serverRequestsAreDeclined() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    rpc.ask.yield(RPCServerRequest(id: "srv-1", method: "item/tool/call", params: [:]))
    #expect(await eventually { await rpc.declined == ["srv-1"] })
  }
}
