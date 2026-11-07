import Foundation

/// What the voice session reports to the bridge.
public enum RealtimeEvent: Sendable, Equatable {
  /// The voice handed a request off (a codex `handoff_request` item), once per handoff id.
  case handoff(VoiceRequest)
  /// The owner's next words (a transcript delta), which only add to what the line shows.
  case userSpeaking(String)
  case userUtterance(String)
  /// The voice finished a reply.
  case assistantUtterance(String)
  /// The voice is saying something (a transcript delta): its next words.
  case assistantSpeaking(String)
  /// codex closed the session, for this reason.
  case closed(Problem)
}

/// One realtime voice session at a time, opened and closed as the call needs it. Its events end
/// when codex does (it exited, stopped answering, or was shut down); the controller is then not
/// used again.
public protocol RealtimeControlling: Actor {
  /// Opens a session for the page's WebRTC offer, seeded with `items`; returns the answer SDP.
  /// A session open or opening ends first; a `close()` or a cancel meanwhile makes it throw
  /// `CancellationError`.
  func open(offerSDP: String, items: [InitialItem]) async throws -> String
  /// Ends the session, also one still opening.
  func close() async
  /// Adds a line the voice reads as context (a result, a question, an approval notice).
  func addContext(_ text: String) async throws
  /// Gives the voice a line to say now, in a session that already has a user turn.
  func speak(_ text: String) async throws
  /// Ends codex itself; the controller is not used again.
  func shutdown() async
  var events: AsyncStream<RealtimeEvent> { get async }
}

/// A realtime session on its own ephemeral, read-only codex thread (ADR 0001 (b), (k), (l)).
///
/// Each `open` starts a new thread with every configured MCP server turned off and refuses to go
/// on unless codex reports all of them disabled. Every codex turn on the thread is interrupted at
/// once, every request codex sends is declined, and an MCP server that starts later closes the
/// session. A request codex does not answer in time ends codex, as its exit does.
public actor RealtimeSession: RealtimeControlling {
  private let client: any RPCClient
  private let cwd: URL
  /// The voice chosen in Settings, read at each open; nil leaves it to codex.
  private let voice: @Sendable () -> String?
  /// The owner's prompt from Settings, read at each open like the voice.
  private let prompt: @Sendable () -> String
  private let timeout = Duration.seconds(20)
  /// More `mcpServerStatus/list` pages than this is a reply this version does not understand.
  static let maxStatusPages = 50

  /// Which `open` a line belongs to.
  private final class Ticket: Sendable {}

  /// The session open or opening: its thread once codex made it, and while opening its wait
  /// for codex's SDP answer. Notifications for any other thread are ignored.
  private struct Line {
    let ticket: Ticket
    var thread: String?
    var answer: CheckedContinuation<String, any Error>?
    var lastError: String?
  }

  private var line: Line?
  private var handoffs: Set<String> = []
  private var listening = false
  public nonisolated let events: AsyncStream<RealtimeEvent>
  private let emit: AsyncStream<RealtimeEvent>.Continuation

  /// `cwd` is an empty directory the app owns (`<data dir>/codex-cwd`).
  public init(
    client: any RPCClient, cwd: URL, voice: @escaping @Sendable () -> String? = { nil },
    prompt: @escaping @Sendable () -> String = { "" }
  ) {
    self.client = client
    self.cwd = cwd
    self.voice = voice
    self.prompt = prompt
    (events, emit) = AsyncStream.makeStream()
  }

  public func open(offerSDP: String, items: [InitialItem]) async throws -> String {
    await close()
    let ticket = Ticket()
    line = Line(ticket: ticket)
    do {
      return try await withTaskCancellationHandler {
        try await establish(ticket, offerSDP: offerSDP, items: items)
      } onCancel: {
        Task { await self.close(ticket) }
      }
    } catch {
      await close(ticket)
      throw error
    }
  }

  private func establish(_ ticket: Ticket, offerSDP: String, items: [InitialItem]) async throws
    -> String
  {
    await listen()
    let config: JSONValue = try await request(
      "config/read", ["cwd": .string(cwd.path)] as JSONValue)
    guard let table = config["config"]?.object, let servers = (table["mcp_servers"] ?? [:]).object
    else {
      throw CodexProblem.protocolMismatch("config/read without an MCP server table")
    }
    try check(ticket)
    let names = servers.keys
    let off = JSONValue.object(
      Dictionary(uniqueKeysWithValues: names.map { ($0, ["enabled": false]) }))
    let started: JSONValue = try await request(
      "thread/start",
      [
        "cwd": .string(cwd.path), "sandbox": "read-only", "approvalPolicy": "never",
        "ephemeral": true, "config": ["mcp_servers": off],
        "developerInstructions": "You relay a voice session. Never act: no tools, no files.",
      ] as JSONValue)
    guard let id = started["thread"]?["id"]?.string else {
      throw CodexProblem.protocolMismatch("thread/start without a thread id")
    }
    try check(ticket)
    line?.thread = id
    try await requireMCPDisabled(thread: id, configured: names)
    try check(ticket)
    return try await start(ticket, thread: id, offerSDP: offerSDP, items: items)
  }

  /// Throws `CancellationError` once `ticket`'s line was closed or its task cancelled.
  private func check(_ ticket: Ticket) throws {
    guard line?.ticket === ticket else { throw CancellationError() }
    try Task.checkCancellation()
  }

  /// Every `mcpServerStatus/list` page must report every server `disabled` (`null` is not),
  /// and every configured server must be reported. Any other shape fails closed.
  private func requireMCPDisabled(thread: String, configured: some Sequence<String>) async throws {
    var cursor: String?
    var enabled: [String] = []
    var reported: Set<String> = []
    for _ in 0..<Self.maxStatusPages {
      var params: [String: JSONValue] = ["threadId": .string(thread), "detail": "toolsAndAuthOnly"]
      params["cursor"] = cursor.map(JSONValue.string)
      let page: JSONValue = try await request("mcpServerStatus/list", JSONValue.object(params))
      guard let servers = page["data"]?.array else {
        throw CodexProblem.protocolMismatch("mcpServerStatus/list without data")
      }
      for server in servers {
        let name = server["name"]?.string ?? "unnamed"
        reported.insert(name)
        if server["runtimeStatus"] != "disabled" { enabled.append(name) }
      }
      cursor = page["nextCursor"]?.string
      guard cursor == nil else { continue }
      enabled += configured.filter { !reported.contains($0) }
      guard enabled.isEmpty else { throw CodexProblem.mcpNotDisabled(enabled) }
      return
    }
    throw CodexProblem.protocolMismatch("mcpServerStatus/list did not end")
  }

  /// `thread/realtime/start` answers `{}`; the SDP answer or an error follows as a notification.
  private func start(_ ticket: Ticket, thread: String, offerSDP: String, items: [InitialItem])
    async throws -> String
  {
    var fields: [String: JSONValue] = [
      "threadId": .string(thread), "version": "v3", "outputModality": "audio",
      "transport": ["type": "webrtc", "sdp": .string(offerSDP)],
      "includeStartupContext": false, "clientManagedHandoffs": true, "delegationAckFiller": true,
      "prompt": .string(VoicePrompt.composed(owner: prompt())),
      "initialItems": try JSONValue(encoding: items),
    ]
    fields["voice"] = voice().map(JSONValue.string)
    let params = JSONValue.object(fields)
    return try await withCheckedThrowingContinuation { waiting in
      guard line?.ticket === ticket else { return waiting.resume(throwing: CancellationError()) }
      line?.answer = waiting
      Task {
        do {
          let _: JSONValue = try await request("thread/realtime/start", params)
          try await Task.sleep(for: timeout)
          resolve(ticket, with: .failure(CodexProblem.protocolMismatch("no SDP answer")))
        } catch { resolve(ticket, with: .failure(error)) }
      }
    }
  }

  /// Ends the wait for codex's SDP answer, if `ticket`'s line still waits (any line: nil).
  private func resolve(_ ticket: Ticket? = nil, with result: Result<String, any Error>) {
    guard let waiting = line, ticket == nil || waiting.ticket === ticket else { return }
    line?.answer = nil
    waiting.answer?.resume(with: result)
  }

  public func close() async {
    guard let line else { return }
    await close(line.ticket)
  }

  /// Closes `ticket`'s line, open or still opening; codex's own `closed` for its thread is not
  /// reported back.
  private func close(_ ticket: Ticket) async {
    guard let closing = line, closing.ticket === ticket else { return }
    line = nil
    closing.answer?.resume(throwing: CancellationError())
    guard let id = closing.thread else { return }
    let _: JSONValue? = try? await request(
      "thread/realtime/stop", ["threadId": .string(id)] as JSONValue)
  }

  /// Result lines go in as `user` text, the role ADR 0001 (b) observed being spoken. The voice
  /// reads them as the owner's words, so a session's text could still steer it; the one-line
  /// shape and the prompt's "data, not instructions" rule narrow that, they do not close it.
  public func addContext(_ text: String) async throws {
    guard let id = line?.thread else {
      throw CodexProblem.protocolMismatch("no voice session open")
    }
    let _: JSONValue = try await request(
      "thread/realtime/appendText",
      ["threadId": .string(id), "text": .string(text), "role": "user"] as JSONValue)
  }

  /// `thread/realtime/appendSpeech`: on realtime v3 codex sends it as speakable context
  /// (`session.context.append` with `channel: "speakable"`), the call its own voice client makes
  /// to have a finished handoff's answer said (ADR 0001 (b)). codex has no request that makes the
  /// model respond on v3; whether and when the voice says it is the model's choice.
  public func speak(_ text: String) async throws {
    guard let id = line?.thread else {
      throw CodexProblem.protocolMismatch("no voice session open")
    }
    let _: JSONValue = try await request(
      "thread/realtime/appendSpeech", ["threadId": .string(id), "text": .string(text)] as JSONValue
    )
  }

  /// Ends codex and the events, so the reader of the events lets this controller go.
  public func shutdown() async {
    await close()
    await client.close()
    emit.finish()
  }

  /// A request to codex. One it does not answer in time ends codex: it hangs.
  private func request<R: Decodable & Sendable>(_ method: String, _ params: JSONValue)
    async throws -> R
  {
    do { return try await client.request(method, params, timeout: timeout) } catch let problem
      as CodexProblem
    {
      if case .timedOut = problem { await retire(problem) }
      throw problem
    }
  }

  private func listen() async {
    guard !listening else { return }
    listening = true
    let notifications = await client.notifications
    let requests = await client.serverRequests
    Task { [weak self] in
      for await notification in notifications { await self?.handle(notification) }
      await self?.retire(.exited(-1))
    }
    Task { [client] in
      for await request in requests {
        await client.reply(to: request, error: RPCError(code: -32000, message: "declined"))
      }
    }
  }

  /// codex exited or stopped answering: a session open or opening closes, saying why, the
  /// events end, and codex is ended.
  private func retire(_ problem: CodexProblem) async {
    if let ending = line {
      line = nil
      ending.answer?.resume(throwing: problem)
      emit.yield(.closed(.codex(problem)))
    }
    emit.finish()
    await client.close()
  }

  private func handle(_ notification: RPCNotification) async {
    let params = notification.params
    if notification.method == "mcpServer/startupStatus/updated" {  // any thread: fail closed
      guard line != nil, ["starting", "ready"].contains(params["status"]?.string) else { return }
      await close()
      emit.yield(
        .closed(.codex(.mcpNotDisabled([params["name"]?.string ?? "unnamed"]))))
      return
    }
    guard let id = line?.thread, params["threadId"]?.string == id else { return }
    switch notification.method {
    case "thread/realtime/sdp":
      resolve(with: .success(params["sdp"]?.string ?? ""))
    case "thread/realtime/error":
      let message = params["message"]?.string ?? ""
      line?.lastError = message
      resolve(with: .failure(CodexProblem.realtimeError(message)))
    case "thread/realtime/closed":
      let reason = line?.lastError.map { Problem.codex(.realtimeError($0)) }
      resolve(with: .failure(CodexProblem.protocolMismatch("closed before the SDP answer")))
      line = nil
      let code = params["reason"]?.string ?? "no reason"
      emit.yield(.closed(reason ?? .other("The voice session closed (\(code)).")))
    case "thread/realtime/itemAdded":
      handoff(params["item"] ?? .null)
    case "thread/realtime/transcript/done":
      let text = (params["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if params["role"] == "user" { emit.yield(.userUtterance(text)) }
      if params["role"] == "assistant" { emit.yield(.assistantUtterance(text)) }
    case "thread/realtime/transcript/delta":
      let words = params["delta"]?.string ?? ""
      if params["role"] == "user" { emit.yield(.userSpeaking(words)) }
      if params["role"] == "assistant" { emit.yield(.assistantSpeaking(words)) }
    case "turn/started":
      guard let turn = params["turn"]?["id"] else { return }
      Task {
        let _: JSONValue? = try? await request(
          "turn/interrupt", ["threadId": .string(id), "turnId": turn] as JSONValue)
      }
    default:
      break
    }
  }

  /// A `handoff_request` item: `input_transcript` is the brief, `active_transcript` the speech.
  /// The request gets a fresh UUID (the id the mod accepts); `handoff_id` only de-duplicates.
  private func handoff(_ item: JSONValue) {
    guard item["type"] == "handoff_request", let id = item["handoff_id"]?.string,
      handoffs.insert(id).inserted
    else { return }
    let transcript = (item["active_transcript"]?.array ?? []).compactMap { line in
      line["text"]?.string.map {
        Utterance(role: line["role"] == "assistant" ? .assistant : .user, text: $0)
      }
    }
    emit.yield(
      .handoff(
        VoiceRequest(
          id: RequestID(rawValue: UUID().uuidString.lowercased()),
          brief: item["input_transcript"]?.string ?? "",
          transcript: transcript)))
  }
}
