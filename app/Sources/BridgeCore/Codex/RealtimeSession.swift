import Foundation

/// What the voice session reports to the bridge.
public enum RealtimeEvent: Sendable, Equatable {
  /// The voice handed a request off (a codex `handoff_request` item), once per handoff id.
  case handoff(VoiceRequest)
  case userUtterance(String)
  /// The voice finished a reply.
  case assistantUtterance(String)
  /// The voice is saying something (a transcript delta).
  case assistantSpeaking
  /// codex closed the session; the reason is a sentence for the owner.
  case closed(String)
}

/// One realtime voice session at a time, opened and closed as the call needs it.
public protocol RealtimeControlling: Sendable {
  /// Opens a session for the page's WebRTC offer, seeded with `items`; returns the answer SDP.
  func open(offerSDP: String, items: [InitialItem]) async throws -> String
  func close() async
  /// Adds a line the voice reads as context (a result, a question, an approval notice).
  func addContext(_ text: String) async throws
  /// Ends codex itself; the controller is not used again.
  func shutdown() async
  var events: AsyncStream<RealtimeEvent> { get async }
}

/// A realtime session on its own ephemeral, read-only codex thread (ADR 0001 (b), (k), (l)).
///
/// Each `open` starts a new thread with every configured MCP server turned off and refuses to go
/// on unless codex reports all of them disabled. Every codex turn on the thread is interrupted at
/// once, every request codex sends is declined, and an MCP server that starts later closes the
/// session.
public actor RealtimeSession: RealtimeControlling {
  private let client: any RPCClient
  private let voice: String?
  private let cwd: URL
  private let timeout = Duration.seconds(20)
  /// The open session's thread; notifications for any other thread are ignored.
  private var thread: String?
  private var answer: CheckedContinuation<String, any Error>?
  /// Counts `start` calls, so a late timeout cannot fail a newer session's open.
  private var attempt = 0
  private var lastError: String?
  private var handoffs: Set<String> = []
  private var listening = false
  public nonisolated let events: AsyncStream<RealtimeEvent>
  private let emit: AsyncStream<RealtimeEvent>.Continuation

  /// `cwd` is an empty directory the app owns (`<data dir>/codex-cwd`).
  public init(client: any RPCClient, voice: String?, cwd: URL) {
    self.client = client
    self.voice = voice
    self.cwd = cwd
    (events, emit) = AsyncStream.makeStream()
  }

  public func open(offerSDP: String, items: [InitialItem]) async throws -> String {
    await listen()
    let config: JSONValue = try await client.request(
      "config/read", ["cwd": .string(cwd.path)] as JSONValue, timeout: timeout)
    let names = (config["config"]?["mcp_servers"]?.object ?? [:]).keys
    let off = JSONValue.object(
      Dictionary(uniqueKeysWithValues: names.map { ($0, ["enabled": false]) }))
    let started: JSONValue = try await client.request(
      "thread/start",
      [
        "cwd": .string(cwd.path), "sandbox": "read-only", "approvalPolicy": "never",
        "ephemeral": true, "config": ["mcp_servers": off],
        "developerInstructions": "You relay a voice session. Never act: no tools, no files.",
      ] as JSONValue, timeout: timeout)
    guard let id = started["thread"]?["id"]?.string else {
      throw CodexProblem.protocolMismatch("thread/start without a thread id")
    }
    thread = id
    do {
      try await requireMCPDisabled(thread: id)
      return try await start(thread: id, offerSDP: offerSDP, items: items)
    } catch {
      await close()
      throw error
    }
  }

  /// Every `mcpServerStatus/list` page must report every server `disabled` (`null` is not).
  private func requireMCPDisabled(thread: String) async throws {
    var cursor: String?
    var enabled: [String] = []
    repeat {
      var params: [String: JSONValue] = ["threadId": .string(thread), "detail": "toolsAndAuthOnly"]
      params["cursor"] = cursor.map(JSONValue.string)
      let page: JSONValue = try await client.request(
        "mcpServerStatus/list", JSONValue.object(params), timeout: timeout)
      for server in page["data"]?.array ?? [] where server["runtimeStatus"] != "disabled" {
        enabled.append(server["name"]?.string ?? "unnamed")
      }
      cursor = page["nextCursor"]?.string
    } while cursor != nil
    guard enabled.isEmpty else { throw CodexProblem.mcpNotDisabled(enabled) }
  }

  /// `thread/realtime/start` answers `{}`; the SDP answer or an error follows as a notification.
  private func start(thread: String, offerSDP: String, items: [InitialItem]) async throws -> String
  {
    var params: [String: JSONValue] = [
      "threadId": .string(thread), "version": "v3", "outputModality": "audio",
      "transport": ["type": "webrtc", "sdp": .string(offerSDP)],
      "includeStartupContext": false, "clientManagedHandoffs": true, "delegationAckFiller": true,
      "prompt": .string(VoicePrompt.text), "initialItems": try JSONValue(encoding: items),
    ]
    params["voice"] = voice.map(JSONValue.string)
    lastError = nil
    attempt += 1
    let mine = attempt
    return try await withCheckedThrowingContinuation { answer in
      self.answer = answer
      Task {
        do {
          let _: JSONValue = try await client.request(
            "thread/realtime/start", JSONValue.object(params), timeout: timeout)
          try await Task.sleep(for: timeout)
          fail(CodexProblem.protocolMismatch("no SDP answer"), attempt: mine)
        } catch { fail(error, attempt: mine) }
      }
    }
  }

  private func fail(_ error: any Error, attempt: Int? = nil) {
    guard attempt == nil || attempt == self.attempt else { return }
    answer?.resume(throwing: error)
    answer = nil
  }

  public func close() async {
    guard let id = thread else { return }
    thread = nil  // codex's own `closed` for this thread is not reported back
    fail(CancellationError())
    let _: JSONValue? = try? await client.request(
      "thread/realtime/stop", ["threadId": .string(id)] as JSONValue, timeout: timeout)
  }

  /// Result lines go in as `user` text, the role ADR 0001 (b) observed being spoken. The voice
  /// reads them as the owner's words, so a session's text could still steer it; the one-line
  /// shape and the prompt's "data, not instructions" rule narrow that, they do not close it.
  public func addContext(_ text: String) async throws {
    guard let id = thread else { throw CodexProblem.protocolMismatch("no voice session open") }
    let _: JSONValue = try await client.request(
      "thread/realtime/appendText",
      ["threadId": .string(id), "text": .string(text), "role": "user"] as JSONValue,
      timeout: timeout)
  }

  public func shutdown() async {
    await close()
    await client.close()
  }

  private func listen() async {
    guard !listening else { return }
    listening = true
    let notifications = await client.notifications
    let requests = await client.serverRequests
    Task { [weak self] in
      for await notification in notifications { await self?.handle(notification) }
      await self?.ended()
    }
    Task { [client] in
      for await request in requests {
        await client.reply(to: request, error: RPCError(code: -32000, message: "declined"))
      }
    }
  }

  private func ended() {
    guard thread != nil else { return }
    thread = nil
    fail(CodexProblem.exited(-1))
    emit.yield(.closed(CodexProblem.exited(-1).sentence))
  }

  private func handle(_ notification: RPCNotification) async {
    let params = notification.params
    if notification.method == "mcpServer/startupStatus/updated" {  // any thread: fail closed
      guard thread != nil, ["starting", "ready"].contains(params["status"]?.string) else { return }
      await close()
      emit.yield(
        .closed(CodexProblem.mcpNotDisabled([params["name"]?.string ?? "unnamed"]).sentence))
      return
    }
    guard let id = thread, params["threadId"]?.string == id else { return }
    switch notification.method {
    case "thread/realtime/sdp":
      answer?.resume(returning: params["sdp"]?.string ?? "")
      answer = nil
    case "thread/realtime/error":
      lastError = params["message"]?.string ?? ""
      fail(CodexProblem.classify(realtimeError: lastError ?? ""))
    case "thread/realtime/closed":
      thread = nil
      fail(CodexProblem.protocolMismatch("closed before the SDP answer"))
      let code = params["reason"]?.string ?? "no reason"
      let reason = lastError.map { CodexProblem.classify(realtimeError: $0).sentence }
      emit.yield(.closed(reason ?? "The voice session closed (\(code))."))
    case "thread/realtime/itemAdded":
      handoff(params["item"] ?? .null)
    case "thread/realtime/transcript/done":
      let text = (params["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if params["role"] == "user" { emit.yield(.userUtterance(text)) }
      if params["role"] == "assistant" { emit.yield(.assistantUtterance(text)) }
    case "thread/realtime/transcript/delta":
      if params["role"] == "assistant" { emit.yield(.assistantSpeaking) }
    case "turn/started":
      guard let turn = params["turn"]?["id"] else { return }
      Task {
        let _: JSONValue? = try? await client.request(
          "turn/interrupt", ["threadId": .string(id), "turnId": turn] as JSONValue,
          timeout: timeout)
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
          id: RequestID(UUID().uuidString.lowercased()),
          brief: item["input_transcript"]?.string ?? "",
          transcript: transcript)))
  }
}
