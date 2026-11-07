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
  /// The next request for each of these methods waits for `release()`.
  var held: Set<String> = []
  private var holding: [CheckedContinuation<Void, Never>] = []
  /// Requests for these methods fail, as codex not answering in time does.
  var failing: [String: CodexProblem] = [:]
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
  func hold(_ method: String) { held.insert(method) }
  var waiting: Int { holding.count }
  func release() {
    for wait in holding { wait.resume() }
    holding = []
  }
  func fail(_ method: String, with problem: CodexProblem) { failing[method] = problem }
  func setOnStart(_ values: [JSONValue]) { onStart = values }

  func request<P: Encodable & Sendable, R: Decodable & Sendable>(
    _ method: String, _ params: P, timeout: Duration
  ) async throws -> R {
    calls.append((method, try JSONValue(encoding: params)))
    if held.remove(method) != nil { await withCheckedContinuation { holding.append($0) } }
    if let problem = failing[method] { throw problem }
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
  var closes = 0
  func close() { closes += 1 }
  /// codex exits: its streams end.
  nonisolated func exit() {
    notify.finish()
    ask.finish()
  }

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
    filePath: "/Users/example/Library/Application Support/LiveBridge/codex-cwd")
  let thread: JSONValue = "00000000-0000-0000-0000-000000000001"

  init() throws {
    rpc = try FakeRPC()
    session = RealtimeSession(client: rpc, cwd: cwd)
  }

  @Test func openSendsPinnedParams() async throws {
    let items = [InitialItem(role: .user, text: "[CONTEXT] Example session: a summary.")]
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
    #expect(realtime["voice"] == nil)  // codex's default
    #expect(realtime["model"] == nil)  // codex ignores a model on this route (ADR 0001 (k))
  }

  /// The voice chosen in Settings is read at each open, so a change applies from the next one.
  @Test func openUsesTheChosenVoice() async throws {
    let chosen = Chosen()
    let session = RealtimeSession(client: rpc, cwd: cwd, voice: { chosen.voice })
    chosen.voice = "cedar"
    _ = try await session.open(offerSDP: "offer", items: [])
    await session.close()
    chosen.voice = "viola"
    _ = try await session.open(offerSDP: "offer", items: [])
    #expect(await rpc.params("thread/realtime/start").map { $0["voice"] } == ["cedar", "viola"])
  }

  /// `--voice-instructions`, in debug builds: the voice gets these and none of its rules.
  @Test func debugInstructionsReplaceTheVoicesRules() async throws {
    let session = RealtimeSession(client: rpc, cwd: cwd, instructions: "Read each line.")
    _ = try await session.open(offerSDP: "offer", items: [])
    let sent = await rpc.params("thread/realtime/start").map { $0["prompt"]?.string }
    #expect(sent == ["Read each line."])
  }

  /// The owner's prompt from Settings is read at each open and goes last in the instructions;
  /// an empty one sends the built-in instructions alone.
  @Test func openUsesTheOwnersPrompt() async throws {
    let chosen = Chosen()
    let session = RealtimeSession(client: rpc, cwd: cwd, prompt: { chosen.prompt })
    chosen.prompt = "Speak with me in Spanish."
    _ = try await session.open(offerSDP: "offer", items: [])
    await session.close()
    chosen.prompt = ""
    _ = try await session.open(offerSDP: "offer", items: [])
    #expect(
      await rpc.params("thread/realtime/start").map { $0["prompt"]?.string }
        == [VoicePrompt.composed(owner: "Speak with me in Spanish."), VoicePrompt.text])
  }

  /// A close while an open is still on its way cancels it: the open throws, and codex is not
  /// asked for a realtime session the line no longer wants.
  @Test func closeCancelsAnOpenUnderWay() async throws {
    await rpc.hold("thread/start")
    let opened = Task { try await session.open(offerSDP: "offer", items: []) }
    #expect(await eventually { await rpc.waiting == 1 })
    await session.close()
    await rpc.release()
    await #expect(throws: CancellationError.self) { _ = try await opened.value }
    #expect(await rpc.params("thread/realtime/start").isEmpty)
  }

  /// One line at a time: an open while another is on its way ends that one, so no wait for an
  /// answer is lost and the second open gets its own.
  @Test func aSecondOpenEndsTheFirst() async throws {
    await rpc.hold("thread/start")
    let first = Task { try await session.open(offerSDP: "offer", items: []) }
    #expect(await eventually { await rpc.waiting == 1 })
    let second = try await session.open(offerSDP: "offer", items: [])
    #expect(second == (try adrJSON("realtime-sdp")["params"]?["sdp"]?.string))
    await rpc.release()
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    #expect(await rpc.params("thread/realtime/start").count == 1)
  }

  /// A task cancelled while its open waits for codex's answer gets its own error back, and the
  /// realtime session it started is stopped.
  @Test func cancellingTheOpenStopsItsSession() async throws {
    await rpc.setOnStart([])  // codex never sends the SDP answer
    let open = Task { try await session.open(offerSDP: "offer", items: []) }
    #expect(await eventually { await !rpc.params("thread/realtime/start").isEmpty })
    open.cancel()
    await #expect(throws: CancellationError.self) { _ = try await open.value }
    #expect(await eventually { await rpc.params("thread/realtime/stop") == [["threadId": thread]] })
  }

  /// codex not answering in time ends the controller as its exit does: the line closes, saying
  /// why, the events end and codex is ended, so the next line starts a fresh one.
  @Test func aRequestTimeoutRetiresCodex() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    await rpc.fail("thread/realtime/appendText", with: .timedOut("thread/realtime/appendText"))
    var events = session.events.makeAsyncIterator()
    await #expect(throws: CodexProblem.timedOut("thread/realtime/appendText")) {
      try await session.addContext("[RESULT] Example session: Done.")
    }
    #expect(await events.next() == .closed(.codex(.timedOut("thread/realtime/appendText"))))
    #expect(await events.next() == nil)
    #expect(await rpc.closes == 1)
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

  /// A reply this version cannot read, a configured server codex does not report, a status
  /// list that never ends, or a config without an MCP server table each refuse the session
  /// (fail closed).
  @Test func mcpCheckFailsClosed() async throws {
    let open = { try await session.open(offerSDP: "offer", items: []) }
    let disabled = try #require(adrJSON("mcp-server-status-list-all-disabled")["result"]?.object)
    let withoutStdio = disabled.merging([
      "data": .array(Array(disabled["data"]?.array?.dropFirst() ?? []))
    ]) { $1 }
    await rpc.set("mcpServerStatus/list", [.object(withoutStdio)])
    await #expect(throws: CodexProblem.mcpNotDisabled(["example-stdio"])) { try await open() }
    await rpc.set("mcpServerStatus/list", [["servers": []]])
    await #expect(throws: CodexProblem.self) { try await open() }
    await rpc.set(
      "mcpServerStatus/list", [.object(disabled.merging(["nextCursor": "again"]) { $1 })])
    await #expect(throws: CodexProblem.self) { try await open() }
    #expect(await rpc.params("mcpServerStatus/list").count == 2 + RealtimeSession.maxStatusPages)
    await rpc.set("mcpServerStatus/list", [.object(disabled)])  // only the config can fail now
    let noTable = CodexProblem.protocolMismatch("config/read without an MCP server table")
    for config: JSONValue in [
      ["settings": [:]], ["config": "none"], ["config": ["mcp_servers": []]],
    ] {
      await rpc.set("config/read", [config])
      await #expect(throws: noTable) { try await open() }
    }
    #expect(await rpc.params("thread/realtime/start").isEmpty)
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
    let problem = CodexProblem.realtimeError("AVAS realtime calls require realtime v1 or v3")
    #expect(await events.next() == .closed(.codex(problem)))
  }

  @Test func startingServerClosesSession() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    rpc.push(try adrJSON("mcp-server-startup-status-starting"))
    var events = session.events.makeAsyncIterator()
    #expect(await events.next() == .closed(.codex(.mcpNotDisabled(["example-http"]))))
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
    guard case .handoff(let request) = await events.next() else {
      Issue.record("no handoff")
      return
    }
    // The mod accepts only UUID request ids; codex's `item_…` id only de-duplicates.
    #expect(request.id.rawValue.wholeMatch(of: /[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/) != nil)
    #expect(request.brief == words && request.transcript == [Utterance(role: .user, text: words)])
    #expect(await events.next() == .assistantUtterance("I'm pulling up the folder now."))
  }

  @Test func assistantDeltaCarriesTheVoicesWords() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    rpc.push(try adrJSON("realtime-transcript-delta-user", params: ["role": "assistant"]))
    var events = session.events.makeAsyncIterator()
    #expect(await events.next() == .assistantSpeaking("Please list"))
  }

  @Test func userDeltaCarriesTheOwnersWords() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    rpc.push(try adrJSON("realtime-transcript-delta-user"))
    var events = session.events.makeAsyncIterator()
    #expect(await events.next() == .userSpeaking("Please list"))
  }

  @Test func resultsAreAddedAsUserText() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    let observed = try #require(adrJSON("realtime-append-text-request")["params"]?.object)
    try await session.addContext(try #require(observed["text"]?.string))
    let sent = try #require(await rpc.params("thread/realtime/appendText").first?.object)
    #expect(sent["role"] == observed["role"] && sent["text"] == observed["text"])
    #expect(sent["threadId"] == thread)
  }

  /// A result to say now goes as speakable text (`appendSpeech`), codex's own way to have the
  /// voice say a finished handoff's answer; the text carries no role.
  @Test func aResultToSayNowIsAppendedAsSpeech() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    try await session.speak("[RESULT] Example session: Done.")
    let sent = try #require(await rpc.params("thread/realtime/appendSpeech").first?.object)
    #expect(sent == ["threadId": thread, "text": "[RESULT] Example session: Done."])
    #expect(await rpc.params("thread/realtime/appendText").isEmpty)
  }

  @Test func speakingWithNoSessionOpenFails() async throws {
    await #expect(throws: CodexProblem.self) { try await session.speak("[RESULT] x: y") }
    #expect(await rpc.params("thread/realtime/appendSpeech").isEmpty)
  }

  /// The events end with the session, so whoever reads them lets the controller go.
  @Test func eventsEndAtShutdownAndWhenCodexExits() async throws {
    var events = session.events.makeAsyncIterator()
    await session.shutdown()
    #expect(await events.next() == nil)
    let codex = try FakeRPC()
    let other = RealtimeSession(client: codex, cwd: cwd)
    _ = try await other.open(offerSDP: "offer", items: [])
    var more = other.events.makeAsyncIterator()
    codex.exit()
    #expect(await more.next() == .closed(.codex(.exited(-1))))
    #expect(await more.next() == nil)
  }

  @Test func serverRequestsAreDeclined() async throws {
    _ = try await session.open(offerSDP: "offer", items: [])
    rpc.ask.yield(RPCServerRequest(id: "srv-1", method: "item/tool/call", params: [:]))
    #expect(await eventually { await rpc.declined == ["srv-1"] })
  }
}

final class Chosen: @unchecked Sendable {
  var voice: String?
  var prompt = ""
}
