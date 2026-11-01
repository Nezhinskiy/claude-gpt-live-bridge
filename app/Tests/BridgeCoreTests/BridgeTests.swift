import Foundation
import Testing
import os

@testable import BridgeCore

actor FakeVoice: RealtimeControlling {
  var opens: [[InitialItem]] = []
  var added: [String] = []
  var failure: CodexProblem?
  var closes = 0
  var shutdowns = 0
  nonisolated let events: AsyncStream<RealtimeEvent>
  private let emitter: AsyncStream<RealtimeEvent>.Continuation

  init() { (events, emitter) = AsyncStream.makeStream() }

  func open(offerSDP: String, items: [InitialItem]) throws -> String {
    if let failure { throw failure }
    opens.append(items)
    return "answer"
  }
  func close() { closes += 1 }
  func addContext(_ text: String) { added.append(text) }
  func shutdown() { shutdowns += 1 }
  func fail(with problem: CodexProblem?) { failure = problem }
  nonisolated func emit(_ event: RealtimeEvent) { emitter.yield(event) }
}

/// A fresh voice for each controller, as the app makes after Stop. While `slow`, each launch
/// waits for `finishLaunch()`, as codex takes seconds to start.
actor FakeVoices {
  private(set) var made: [FakeVoice] = []
  var slow = false
  private var launches: [CheckedContinuation<Void, Never>] = []
  func make() async -> FakeVoice {
    if slow { await withCheckedContinuation { launches.append($0) } }
    made.append(FakeVoice())
    return made[made.count - 1]
  }
  func setSlow() { slow = true }
  var waiting: Int { launches.count }
  func finishLaunch() {
    slow = false
    launches.forEach { $0.resume() }
    launches = []
  }
}

actor FakeAudio: AudioSide {
  var calls: [String] = []
  /// Connecting takes a second, which the meter must not count.
  let time: TestTime
  var answerFails = false
  init(time: TestTime) { self.time = time }
  func failAnswers() { answerFails = true }
  func startListening() { calls.append("startListening") }
  func stopListening() { calls.append("stopListening") }
  func makeOffer() -> String { "offer" }
  func applyAnswer(_ sdp: String) throws {
    if answerFails { throw CodexProblem.protocolMismatch("no session.started") }
    calls.append("applyAnswer")
    time.advance(by: .seconds(1))
  }
  func flushPreroll() { calls.append("flushPreroll") }
  func closePeer() { calls.append("closePeer") }
  func chime() { calls.append("chime") }
}

@Suite(.timeLimit(.minutes(1)))
struct BridgeTests {
  let time = TestTime()
  let voice = FakeVoice()
  let audio: FakeAudio
  let registry: SessionRegistry
  let bridge: Bridge
  let dir: URL
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")

  init(realtime: (@Sendable () async throws -> any RealtimeControlling)? = nil) throws {
    dir = try temporaryDirectory()
    registry = SessionRegistry(time: time)
    audio = FakeAudio(time: time)
    bridge = Bridge(
      registry: registry, realtime: realtime ?? { [voice] in voice }, audio: audio,
      meter: UsageMeterStore(file: dir.appending(path: "usage.json"), time: time),
      continuityFile: dir.appending(path: "continuity.json"), time: time)
  }

  @discardableResult
  func post(_ path: String, _ body: some Encodable) async throws -> HTTPResponse {
    let body = try JSONEncoder().encode(body)
    return await bridge.handle(
      HTTPRequest(method: "POST", path: path, query: [:], body: body))
  }

  func join(_ id: SessionID, _ title: String, autoContext: Bool = false) async throws {
    try await post("/v1/join", JoinBody(sessionId: id, title: title, autoContext: autoContext))
  }

  func request(_ n: Int) -> VoiceRequest {
    VoiceRequest(id: RequestID(rawValue: "request-\(n)"), brief: "Example request \(n)", transcript: [])
  }

  /// Hands `request` to `session` and posts its answer.
  func answer(
    _ request: VoiceRequest, from session: SessionID, _ status: AnswerStatus = .ok,
    _ text: String = "Done."
  ) async throws {
    try await registry.enqueue(request, for: session)
    _ = try await registry.poll(session)
    try await post(
      "/v1/answer",
      AnswerBody(sessionId: session, id: request.id, status: status, text: text, reason: nil))
  }

  /// Starts the call, with `Alpha` joined if no session is, and opens the line.
  func live() async {
    if await registry.target == nil { try? await join(a, "Alpha") }
    await bridge.perform(.start)
    await bridge.audioEvent(.speechStarted)
  }

  /// A second Start while codex is still launching does not launch a second codex, and a
  /// Stop meanwhile wins: the launched codex is ended and the microphone stays off.
  @Test func oneStartAtATimeAndStopDuringStartWins() async throws {
    let voices = FakeVoices()
    let test = try BridgeTests { await voices.make() }
    try await test.join(a, "Alpha")
    await voices.setSlow()
    async let first: Void = test.bridge.perform(.start)
    #expect(await eventually { await voices.waiting == 1 })
    async let second: Void = test.bridge.perform(.start)
    try? await Task.sleep(for: .milliseconds(100))
    await test.bridge.perform(.stop)
    await voices.finishLaunch()
    _ = await (first, second)
    #expect(await voices.made.count == 1)
    #expect(await voices.made.first?.shutdowns == 1)
    #expect(await test.bridge.status.call == .off)
    #expect(await !test.audio.calls.contains("startListening"))
    await test.bridge.perform(.start)  // the next Start launches a fresh codex
    #expect(await test.bridge.status.call == .listening)
    #expect(await voices.made.count == 2)
  }

  /// With no session there is nothing to talk to: Start (from the band or the socket) does
  /// nothing but say so, and the sentence goes once a session joins.
  @Test func startWithNoSessionDoesNothing() async throws {
    await bridge.perform(.start)
    #expect(await bridge.status.call == .off)
    #expect(await bridge.status.problem == Bridge.noSession)
    #expect(await audio.calls.isEmpty)
    try await join(a, "Alpha")
    #expect(await bridge.status.problem == nil)
  }

  /// The sentence of a failed Start goes once a Start succeeds.
  @Test func startThatSucceedsClearsTheProblem() async throws {
    let fails = OSAllocatedUnfairLock(initialState: true)
    let test = try BridgeTests { [voice] in
      if fails.withLock({ $0 }) { throw CodexProblem.protocolMismatch("no reply to initialize") }
      return voice
    }
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    #expect(await test.bridge.status.problem != nil)
    fails.withLock { $0 = false }
    await test.bridge.perform(.start)
    #expect(await test.bridge.status.call == .listening)
    #expect(await test.bridge.status.problem == nil)
  }

  @Test func handoffGoesToTarget() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await post("/v1/target", TargetBody(sessionId: b))
    await live()
    voice.emit(.handoff(request(1)))
    #expect(try await eventually { try await registry.poll(b) == .request(request(1)) })
    voice.emit(.closed("The voice session closed (example)."))
    #expect(await eventually { await bridge.status.call == .listening })
    await bridge.audioEvent(.speechStarted)  // the next session knows the task is open
    #expect(
      await voice.opens.last == [
        InitialItem(role: .user, text: "[TASK] Beta: Example request 1")
      ])
  }

  /// The popover's Load context asks only the target for its summary.
  @Test func loadContextAsksTheTarget() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await post("/v1/target", TargetBody(sessionId: b))
    _ = try await registry.poll(b)  // a fresh target may already owe a summary
    await bridge.loadContext()
    #expect(try await registry.poll(b) == .context)
    #expect(try await registry.poll(a) == nil)
  }

  @Test func popoverSetsTheTarget() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    #expect(await registry.target == a)
    await bridge.setTarget(b)
    #expect(await bridge.status.sessions.map(\.isTarget) == [false, true])
  }

  @Test func questionReplyGoesToAskingSession() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    try await answer(request(1), from: b, .question, "Which branch?")
    #expect(await voice.added == ["[QUESTION] Beta: Which branch?"])
    voice.emit(.handoff(request(2)))
    #expect(try await eventually { try await registry.poll(b) == .request(request(2)) })
    voice.emit(.handoff(request(3)))  // the route is used once
    #expect(try await eventually { try await registry.poll(a) == .request(request(3)) })
  }

  /// A question asked before Stop, or before the owner picked a target, routes nothing later.
  @Test func questionRouteEndsWithTheCallAndATargetChoice() async throws {
    let voices = FakeVoices()
    let test = try BridgeTests { await voices.make() }
    try await test.join(a, "Alpha")
    try await test.join(b, "Beta")
    await test.live()
    try await test.answer(request(1), from: b, .question, "Which branch?")
    await test.bridge.perform(.stop)
    await test.live()
    await voices.made.last?.emit(.handoff(request(2)))
    #expect(try await eventually { try await test.registry.poll(a) == .request(request(2)) })
    try await test.answer(request(3), from: b, .question, "Which file?")
    await test.bridge.setTarget(a)
    await voices.made.last?.emit(.handoff(request(4)))
    let task = "[TASK] Alpha: Example request 4"
    #expect(await eventually { await test.registry.openTasks().contains(task) })
  }

  /// A question the owner never heard, because the call was off, routes nothing.
  @Test func questionWhileOffRoutesNothing() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await answer(request(1), from: b, .question, "Which branch?")
    await live()
    voice.emit(.handoff(request(2)))
    #expect(try await eventually { try await registry.poll(a) == .request(request(2)) })
  }

  @Test func deliveryWhileLiveIsAddedAsContext() async throws {
    try await join(a, "Alpha")
    await live()
    try await answer(request(1), from: a)
    #expect(await voice.added == ["[RESULT] Alpha: Done."])
    #expect(await !audio.calls.contains("chime"))
  }

  @Test func deliveryWhileListeningChimesThenAddsOnSpeech() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    try await answer(request(1), from: a)
    #expect(await audio.calls.contains("chime"))
    #expect(await voice.added.isEmpty)
    #expect(await bridge.status.unheard == 1)
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.added == ["[RESULT] Alpha: Done."])
    #expect(await bridge.status.unheard == 1)  // until the voice has said it
    voice.emit(.assistantSpeaking)
    voice.emit(.assistantUtterance("I"))  // cut off by the owner
    voice.emit(.assistantSpeaking)
    voice.emit(.assistantUtterance("Alpha is done."))
    #expect(await eventually { await bridge.status.unheard == 0 })
  }

  /// With no session joined, the failure arrives with the handoff; the ack must not hang up on it.
  @Test func failureWithNoSessionIsHeard() async throws {
    await live()
    try await post("/v1/leave", LeaveBody(sessionId: a))
    await bridge.audioEvent(.speechEnded)
    voice.emit(.handoff(request(1)))
    voice.emit(.assistantUtterance("On it."))
    #expect(await eventually { await bridge.status.unheard == 1 })
    #expect(await voice.added == ["[FAILED] LiveBridge: no Claude Code session is joined."])
    #expect(await bridge.status.call == .live)
  }

  @Test func newerRequestSupersedesAnUnheardResult() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    try await answer(request(1), from: a)
    voice.emit(.handoff(request(2)))  // a handoff that lands as the voice hangs up
    #expect(await eventually { await bridge.status.unheard == 0 })
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.added.isEmpty)
  }

  /// A request that timed out is unheard like any other failure, so a newer request to the
  /// same session withdraws it.
  @Test func newerRequestSupersedesATimedOutRequest() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    for _ in 0...600 {  // the sweep runs each second; the session keeps polling
      #expect(await eventually { time.sleepers == 1 })
      time.advance(by: .seconds(1))
      _ = try await registry.poll(a)
    }
    #expect(await eventually { await bridge.status.unheard == 1 })
    voice.emit(.handoff(request(2)))
    #expect(await eventually { await bridge.status.unheard == 0 })
  }

  /// An approval notice the owner has not heard goes once the approval is settled.
  @Test func settledApprovalWithdrawsItsNotice() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval))
    #expect(await bridge.status.unheard == 1)
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .working))
    #expect(await bridge.status.unheard == 0)
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.added.isEmpty)
  }

  @Test func updateWhileClosedChimes() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    try await answer(request(1), from: a, .update, "Tests pass.")
    #expect(await audio.calls.filter { $0 == "chime" }.count == 1)
  }

  @Test func approvalActivityCallsBackWithNotice() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval))
    #expect(await audio.calls.contains("chime"))
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.added == ["[APPROVAL] Alpha: Claude is waiting for your approval"])
  }

  @Test func realtimeFailureSurfacesProblemSentence() async throws {
    let missing = try BridgeTests { throw CodexProblem.notInstalled }
    try await missing.join(a, "Alpha")
    await missing.bridge.perform(.start)
    #expect(await missing.bridge.status.call == .off)
    #expect(await missing.bridge.status.problem == CodexProblem.notInstalled.sentence)

    await voice.fail(with: .realtimeError("Realtime is not available on your plan"))
    await live()
    #expect(await bridge.status.call == .listening)
    #expect(await bridge.status.problem?.contains("ChatGPT plan") == true)
  }

  /// The context line is shown exactly as the voice gets it, also after the app restarts.
  @Test func contextIsRedactedCappedAndShown() async throws {
    try await join(a, "Alpha")
    let summary =
      "The password: hunter2 is set. Key sk-\u{200B}abcdefghijklmnopqrst. "
      + String(repeating: "More detail here. ", count: 100)
    try await post("/v1/context", ContextBody(sessionId: a, summary: summary))
    let shown = try #require(await bridge.status.lastContext)
    #expect(!shown.contains("hunter2") && !shown.contains("abcdefghij"))
    #expect(shown.count <= Bridge.maxContext && shown.hasSuffix("."))
    #expect(shown.hasPrefix("[CONTEXT] Alpha: The password"))
    await live()
    #expect(await voice.opens.first?.first == InitialItem(role: .user, text: shown))
    let restarted = Bridge(
      registry: SessionRegistry(time: time), realtime: { [voice] in voice }, audio: audio,
      meter: UsageMeterStore(file: dir.appending(path: "usage.json"), time: time),
      continuityFile: dir.appending(path: "continuity.json"), time: time)
    #expect(await restarted.status.lastContext == shown)
  }

  @Test func stopThenStartResumesConversation() async throws {
    await live()
    voice.emit(.userUtterance("Remember the colour teal."))
    #expect(
      await eventually {
        await bridge.status.recentTranscript == ["You: Remember the colour teal."]
      })
    await bridge.perform(.stop)
    await live()
    #expect(await voice.opens.last == [InitialItem(role: .user, text: "Remember the colour teal.")])
  }

  @Test func newConversationClearsContinuity() async throws {
    await live()
    voice.emit(.userUtterance("Remember the colour teal."))
    #expect(await eventually { await !bridge.status.recentTranscript.isEmpty })
    await bridge.perform(.stop)
    await bridge.newConversation()
    await live()
    #expect(await voice.opens.last == [])
    #expect(await bridge.status.recentTranscript.isEmpty)
  }

  @Test func meterCountsOnlyLiveIntervals() async throws {
    await live()
    time.advance(by: .seconds(3))
    voice.emit(.closed("The voice session closed (example)."))
    #expect(await eventually { await bridge.status.call == .listening })
    time.advance(by: .seconds(10))  // listening is not metered
    await bridge.audioEvent(.speechStarted)
    time.advance(by: .seconds(2))
    voice.emit(.closed("The voice session closed (example)."))
    #expect(await eventually { await bridge.status.call == .listening })
    #expect(await bridge.status.minutesThisCall == 5.0 / 60)
    await bridge.perform(.stop)
    await bridge.perform(.start)
    #expect(await bridge.status.minutesThisCall == 0)
    #expect(await bridge.status.minutesToday == 5.0 / 60)
  }

  /// A connect that fails after codex answered closes codex's session too, so none stays open.
  @Test func failedConnectClosesTheVoiceSession() async throws {
    await audio.failAnswers()
    await live()
    #expect(await bridge.status.call == .listening)
    #expect(await voice.closes == 1)
  }

  @Test func audioFailureSurfacesProblem() async throws {
    await live()
    await bridge.audioEvent(.failed("No microphone is connected."))
    #expect(await bridge.status.call == .off)
    #expect(await bridge.status.problem == "No microphone is connected.")
    #expect(await audio.calls.contains("stopListening"))
  }
}
