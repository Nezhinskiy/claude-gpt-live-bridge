import Foundation
import Testing

@testable import BridgeCore

actor FakeVoice: RealtimeControlling {
  var opens: [[InitialItem]] = []
  var added: [String] = []
  var failure: CodexProblem?
  nonisolated let events: AsyncStream<RealtimeEvent>
  private let emitter: AsyncStream<RealtimeEvent>.Continuation

  init() { (events, emitter) = AsyncStream.makeStream() }

  func open(offerSDP: String, items: [InitialItem]) throws -> String {
    if let failure { throw failure }
    opens.append(items)
    return "answer"
  }
  func close() {}
  func addContext(_ text: String) { added.append(text) }
  func shutdown() {}
  func fail(with problem: CodexProblem?) { failure = problem }
  nonisolated func emit(_ event: RealtimeEvent) { emitter.yield(event) }
}

actor FakeAudio: AudioSide {
  var calls: [String] = []
  /// Connecting takes a second, which the meter must not count.
  let time: TestTime
  init(time: TestTime) { self.time = time }
  func startListening() { calls.append("startListening") }
  func stopListening() { calls.append("stopListening") }
  func makeOffer() -> String { "offer" }
  func applyAnswer(_ sdp: String) {
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
  let a = SessionID("00000000-0000-0000-0000-000000000001")
  let b = SessionID("11111111-0000-0000-0000-000000000002")

  init(realtime: (@Sendable () async throws -> any RealtimeControlling)? = nil) throws {
    let dir = try temporaryDirectory()
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
      HTTPRequest(method: "POST", path: path, query: [:], headers: [:], body: body))
  }

  func join(_ id: SessionID, _ title: String, autoContext: Bool = false) async throws {
    try await post("/v1/join", JoinBody(sessionId: id, title: title, autoContext: autoContext))
  }

  func request(_ n: Int) -> VoiceRequest {
    VoiceRequest(id: RequestID("request-\(n)"), brief: "Example request \(n)", transcript: [])
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

  func live() async {
    await bridge.perform(.start)
    await bridge.audioEvent(.speechStarted)
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
        InitialItem(role: .developer, text: "[TASK] Beta: Example request 1")
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
    #expect(await bridge.status.target == a)
    await bridge.setTarget(b)
    #expect(await bridge.status.target == b)
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
    #expect(await bridge.status.unheard == 0)
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
    await missing.bridge.perform(.start)
    #expect(await missing.bridge.status.call == .off)
    #expect(await missing.bridge.status.problem == CodexProblem.notInstalled.sentence)

    await voice.fail(with: .realtimeUnavailable)
    await live()
    #expect(await bridge.status.call == .listening)
    #expect(await bridge.status.problem == CodexProblem.realtimeUnavailable.sentence)
  }

  @Test func contextIsRedactedCappedAndShown() async throws {
    try await join(a, "Alpha")
    let summary =
      "The password: hunter2 is set. Key sk-\u{200B}abcdefghijklmnopqrst. "
      + String(repeating: "More detail here. ", count: 100)
    try await post("/v1/context", ContextBody(sessionId: a, summary: summary))
    let shown = try #require(await bridge.status.lastContext)
    #expect(!shown.contains("hunter2") && !shown.contains("abcdefghij"))
    #expect(shown.count <= 1500 && shown.hasSuffix("."))
    await live()
    #expect(
      await voice.opens.first?.first
        == InitialItem(role: .developer, text: "[CONTEXT] Alpha: \(shown)"))
  }

  @Test func autoContextOnTargetSwitch() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta", autoContext: true)
    try await post("/v1/target", TargetBody(sessionId: b))
    #expect(try await registry.poll(b) == .context)
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

  @Test func audioFailureSurfacesProblem() async throws {
    await live()
    await bridge.audioEvent(.failed("No microphone is connected."))
    #expect(await bridge.status.call == .off)
    #expect(await bridge.status.problem == "No microphone is connected.")
    #expect(await audio.calls.contains("stopListening"))
  }
}
