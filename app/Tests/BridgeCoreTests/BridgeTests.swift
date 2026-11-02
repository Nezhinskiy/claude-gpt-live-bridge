import Foundation
import Testing

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

  /// While set, the next open waits for `releaseOpen()`, as codex takes seconds to answer.
  var holdsOpen = false
  private var heldOpens: [CheckedContinuation<Void, Never>] = []
  var openWaiting: Int { heldOpens.count }
  func holdOpen() { holdsOpen = true }
  func releaseOpen() {
    for wait in heldOpens { wait.resume() }
    heldOpens = []
  }

  func open(offerSDP: String, items: [InitialItem]) async throws -> String {
    if holdsOpen {
      holdsOpen = false
      await withCheckedContinuation { heldOpens.append($0) }
    }
    if let failure { throw failure }
    opens.append(items)
    return "answer"
  }
  func close() { closes += 1 }
  func addContext(_ text: String) { added.append(text) }
  var spoken: [String] = []
  func speak(_ text: String) { spoken.append(text) }
  func shutdown() { shutdowns += 1 }
  func fail(with problem: CodexProblem?) { failure = problem }
  nonisolated func emit(_ event: RealtimeEvent) { emitter.yield(event) }
  /// codex exited or stopped answering: the events end.
  nonisolated func end() { emitter.finish() }
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
    for launch in launches { launch.resume() }
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

/// Records the notices the bridge posts.
actor FakeNotifier: ResultNotifying {
  var posted: [ResultNotice] = []
  func post(_ notice: ResultNotice) { posted.append(notice) }
}

@Suite(.timeLimit(.minutes(1)))
struct BridgeTests {
  let time: TestTime
  let voice = FakeVoice()
  let audio: FakeAudio
  let notifier = FakeNotifier()
  let registry: SessionRegistry
  let bridge: Bridge
  let dir: URL
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")

  /// `dir` and `time` are given to restart the app on another test's data.
  init(
    realtime: (@Sendable () async throws -> any RealtimeControlling)? = nil, dir: URL? = nil,
    time: TestTime = TestTime(), notifies: @escaping @Sendable () -> Bool = { true }
  ) throws {
    self.time = time
    self.dir = try dir ?? temporaryDirectory()
    registry = SessionRegistry(time: time)
    audio = FakeAudio(time: time)
    bridge = Bridge(
      registry: registry, realtime: realtime ?? { [voice] in voice }, audio: audio,
      meter: UsageMeterStore(file: self.dir.appending(path: "usage.json"), time: time),
      continuityFile: self.dir.appending(path: "continuity.json"), time: time,
      notifier: notifier, notifies: notifies)
  }

  @discardableResult
  func post(_ path: String, _ body: some Encodable) async throws -> HTTPResponse {
    let body = try JSONEncoder().encode(body)
    return await bridge.handle(
      HTTPRequest(method: "POST", path: path, query: [:], body: body))
  }

  func join(_ id: SessionID, _ title: String) async throws {
    try await post("/v1/join", JoinBody(sessionId: id, title: title))
  }

  func request(_ n: Int) -> VoiceRequest {
    VoiceRequest(
      id: RequestID(rawValue: "request-\(n)"), brief: "Example request \(n)", transcript: [])
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

  /// The target's conversation as the menu shows it, `Speaker: text`, oldest first.
  func lines() async -> [String] {
    await bridge.current.conversation.map { "\($0.speaker.name): \($0.text)" }
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

  /// A codex that ended (it exited, or stopped answering) is not used again: the next speech
  /// launches a fresh one.
  @Test func aCodexThatEndedIsReplacedAtTheNextSpeech() async throws {
    let voices = FakeVoices()
    let test = try BridgeTests { await voices.make() }
    await test.live()
    let first = try #require(await voices.made.first)
    first.emit(.closed(.codex(.exited(-1))))
    first.end()
    #expect(await eventually { await first.shutdowns == 1 })
    #expect(await test.bridge.status.call == .listening)
    await test.bridge.audioEvent(.speechStarted)
    #expect(await voices.made.count == 2)
    #expect(await test.bridge.status.call == .live)
  }

  /// A new target while the line is still opening cancels that opening: when codex's late
  /// answer comes, the line opened since with the new target's conversation is left alone.
  @Test func aLateOpenAfterATargetChangeLeavesTheNewLineAlone() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.perform(.start)
    await voice.holdOpen()
    let opening = Task { await bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await voice.openWaiting == 1 })
    await bridge.setTarget(b)
    #expect(await bridge.status.call == .listening)
    await bridge.audioEvent(.speechStarted)
    #expect(await bridge.status.call == .live)
    let closes = await voice.closes
    await voice.releaseOpen()
    await opening.value
    #expect(await voice.closes == closes)
    #expect(await bridge.status.call == .live)
    #expect(await audio.calls.filter { $0 == "applyAnswer" }.count == 1)
  }

  /// With no session there is nothing to talk to: Start (from the band or the socket) does
  /// nothing but say so, and the sentence goes once a session joins.
  @Test func startWithNoSessionDoesNothing() async throws {
    await bridge.perform(.start)
    #expect(await bridge.status.call == .off)
    #expect(await bridge.status.problem == Problem.noSession.sentence)
    #expect(await audio.calls.isEmpty)
    try await join(a, "Alpha")
    #expect(await bridge.status.problem == nil)
  }

  /// Removing a session from the menu answers its next poll, and any join but the owner's,
  /// with 410 and the wire's code.
  @Test func removedSessionsNextPollIsGone() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.remove(a)
    #expect(await bridge.status.sessions.map(\.sessionId) == [b])
    let reply = await bridge.handle(
      HTTPRequest(method: "GET", path: "/v1/next", query: ["sessionId": a.rawValue], body: Data()))
    #expect(reply.status == 410)
    #expect(try JSONDecoder().decode(ErrorReply.self, from: reply.body).code == .removed)
    let rejoin = try await post("/v1/join", JoinBody(sessionId: a, title: "Alpha renamed"))
    #expect(rejoin.status == 410)
    #expect(try JSONDecoder().decode(ErrorReply.self, from: rejoin.body).code == .removed)
    #expect(await bridge.status.sessions.map(\.sessionId) == [b])
    try await post("/v1/join", JoinBody(sessionId: a, title: "Alpha", owner: true))
    #expect(await bridge.status.sessions.map(\.sessionId) == [b, a])
  }

  @Test func handoffGoesToTarget() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await post("/v1/target", TargetBody(sessionId: b))
    await live()
    voice.emit(.handoff(request(1)))
    #expect(try await eventually { try await registry.poll(b) == .request(request(1)) })
    voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await bridge.status.call == .listening })
    await bridge.audioEvent(.speechStarted)  // the next session knows the task is open
    #expect(
      await voice.opens.last == [
        InitialItem(role: .user, text: "[TASK] Beta: Example request 1")
      ])
  }

  /// The menu's Load context asks only the target for its summary.
  @Test func loadContextAsksTheTarget() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await post("/v1/target", TargetBody(sessionId: b))
    _ = try await registry.poll(b)  // a fresh target may already owe a summary
    await bridge.loadContext()
    #expect(try await registry.poll(b) == .context)
    #expect(try await registry.poll(a) == nil)
  }

  /// A session's summary is announced to the menu, which stops waiting for it; one from a
  /// session that never joined is not.
  @Test func arrivingContextIsAnnounced() async throws {
    try await join(a, "Alpha")
    var arrivals = bridge.contextArrivals.makeAsyncIterator()
    try await post("/v1/context", ContextBody(sessionId: b, summary: "Not joined."))
    try await post("/v1/context", ContextBody(sessionId: a, summary: "Alpha's work."))
    #expect(await arrivals.next() == a)
  }

  @Test func theMenuSetsTheTarget() async throws {
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

  /// A question Claude asks mid-turn reaches the voice whole, and the owner's next handoff goes
  /// to that session as its reply, though another session is the target.
  @Test func replyToClaudesQuestionGoesToTheAskingSession() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await registry.enqueue(request(1), for: a)
    #expect(try await registry.poll(a) == .request(request(1)))
    try await post("/v1/target", TargetBody(sessionId: b))
    await live()
    let question = "Which name? Options: build (the default), out (shorter)."
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval, question: question))
    #expect(await voice.added == ["[ASKING] Alpha: \(question)"])
    voice.emit(.handoff(request(2)))
    #expect(try await eventually { try await registry.poll(a) == .reply(request(2)) })
  }

  /// A question answered in Claude Code is withdrawn from the voice and routes nothing.
  @Test func questionAnsweredInClaudeCodeIsWithdrawn() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.perform(.start)
    try await post("/v1/activity", ActivityBody(sessionId: b, state: .approval, question: "Which?"))
    #expect(await bridge.status.unheard == 1)
    try await post("/v1/activity", ActivityBody(sessionId: b, state: .working))
    #expect(await bridge.status.unheard == 0)
    await live()
    voice.emit(.handoff(request(1)))
    #expect(try await eventually { try await registry.poll(a) == .request(request(1)) })
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

  /// Each chime for a waiting result posts one notice, naming the sessions with results waiting.
  @Test func aWaitingResultChimesWithANotice() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.perform(.start)
    try await answer(request(1), from: a)
    #expect(await notifier.posted.map(\.body) == ["Alpha has a new result — speak to hear it."])
    try await answer(request(2), from: b)
    #expect(
      await notifier.posted.map(\.body).last
        == "2 sessions have new results — speak to hear them.")
    let chimes = await audio.calls.filter { $0 == "chime" }.count
    #expect(await notifier.posted.count == chimes)
  }

  /// A result the open line is given needs no notice.
  @Test func aResultOnTheOpenLinePostsNoNotice() async throws {
    await live()
    try await answer(request(1), from: a)
    #expect(await notifier.posted.isEmpty)
  }

  /// Settings' notifications are read at each chime.
  @Test func noticesCanBeTurnedOff() async throws {
    let settings = SettingsStore(file: nil)
    let test = try BridgeTests(notifies: { settings.current.notifyResults })
    settings.update { $0.notifyResults = false }
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    try await test.answer(request(1), from: a)
    #expect(await test.audio.calls.contains("chime"))
    #expect(await test.notifier.posted.isEmpty)
  }

  /// Hands `request(1)` to Alpha on the open line and lets Alpha take it.
  func handOff() async throws {
    voice.emit(.handoff(request(1)))
    #expect(try await eventually { try await registry.poll(a) == .request(request(1)) })
  }

  func answerFirstRequest() async throws {
    try await post(
      "/v1/answer",
      AnswerBody(sessionId: a, id: request(1).id, status: .ok, text: "Done.", reason: nil))
  }

  /// A result that comes while the line still waits for it is said at once, not only added.
  @Test func anEarlyResultIsSpokenOnTheOpenLine() async throws {
    await live()
    await bridge.audioEvent(.speechEnded)
    try await handOff()
    try await answerFirstRequest()
    #expect(await eventually { await voice.spoken == ["[RESULT] Alpha: Done."] })
    #expect(await voice.added.isEmpty)
  }

  /// While the owner speaks the result waits; it is said once they stop and the grace passes.
  @Test func aResultWaitsForSilenceAndTheGrace() async throws {
    await live()  // the owner is still speaking
    try await handOff()
    try await answerFirstRequest()
    await bridge.audioEvent(.speechEnded)
    #expect(await voice.spoken.isEmpty)
    #expect(await eventually { time.sleepers >= 6 })  // sweep, 3 silence timers, window, grace
    time.advance(by: .milliseconds(800))
    #expect(await eventually { await voice.spoken == ["[RESULT] Alpha: Done."] })
  }

  /// An approval notice while the line waits for a result is said, and the line still waits:
  /// silence does not close it while the owner approves, and the result is said when it comes.
  @Test func anApprovalNoticeKeepsTheLineWaitingForTheResult() async throws {
    await live()
    await bridge.audioEvent(.speechEnded)
    try await handOff()
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval))
    let notice = "[APPROVAL] Alpha: Claude is waiting for your approval"
    #expect(await eventually { await voice.spoken == [notice] })
    #expect(await eventually { time.sleepers >= 5 })  // sweep, 3 silence timers, window
    for _ in 0...CallMachine.silenceSeconds {
      time.advance(by: .seconds(1))
      _ = try await registry.poll(a)  // the session stays joined
    }
    #expect(await bridge.status.call == .live)
    try await answerFirstRequest()
    #expect(await eventually { await voice.spoken == [notice, "[RESULT] Alpha: Done."] })
  }

  /// A result held while the owner speaks is withdrawn like any unheard one when a newer
  /// request to its session supersedes it, so the grace does not say it.
  @Test func aSupersededHeldResultIsNotSaid() async throws {
    await live()  // the owner is still speaking
    try await handOff()
    try await answerFirstRequest()
    voice.emit(.handoff(request(2)))
    #expect(try await eventually { try await registry.poll(a) == .request(request(2)) })
    #expect(await bridge.status.unheard == 0)
    await bridge.audioEvent(.speechEnded)
    try await Task.sleep(for: .milliseconds(50))  // a grace timer, if any, is armed by now
    time.advance(by: .milliseconds(800))
    try await Task.sleep(for: .milliseconds(50))
    #expect(await voice.spoken.isEmpty)
  }

  /// Silence does not close a line that waits for a result; the window does, and a result after
  /// it chimes as before.
  @Test func anUnansweredHandoffClosesTheLineAfterTheWindow() async throws {
    await live()
    await bridge.audioEvent(.speechEnded)
    try await handOff()
    #expect(await eventually { time.sleepers >= 4 })  // sweep, 2 silence timers, window
    for second in 1..<CallMachine.resultWindowSeconds {
      time.advance(by: .seconds(1))
      _ = try await registry.poll(a)  // the session stays joined
      if second == CallMachine.silenceSeconds + 1 { #expect(await bridge.status.call == .live) }
    }
    #expect(await bridge.status.call == .live)
    time.advance(by: .seconds(1))
    #expect(await eventually { await bridge.status.call == .listening })
    try await answerFirstRequest()
    #expect(await audio.calls.contains("chime"))
    #expect(await voice.spoken.isEmpty)
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
      "The password: hunter2 is set. Key sk-abcdefghijklmnopqrst. "
      + String(repeating: "More detail here. ", count: 100)
    try await post("/v1/context", ContextBody(sessionId: a, summary: summary))
    let shown = try #require(await bridge.current.context)
    #expect(!shown.contains("hunter2") && !shown.contains("abcdefghij"))
    #expect(shown.count <= Bridge.maxContext && shown.hasSuffix("."))
    #expect(shown.hasPrefix("[CONTEXT] Alpha: The password"))
    await live()
    #expect(await voice.opens.first?.first == InitialItem(role: .user, text: shown))
    let restarted = try restart()
    try await restarted.join(a, "Alpha")
    #expect(await restarted.bridge.current.context == shown)
  }

  /// The same app data after the app restarted: a fresh bridge and registry.
  func restart() throws -> BridgeTests { try BridgeTests(dir: dir, time: time) }

  // MARK: One conversation per session

  /// Each session's conversation is its own: changing the target closes the open line, and the
  /// next speech opens it with the new target's conversation.
  @Test func targetChangeSwitchesTheConversation() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    voice.emit(.userUtterance("Remember the colour teal."))
    #expect(await eventually { await lines().count == 1 })
    await bridge.setTarget(b)
    #expect(await bridge.status.call == .listening)
    #expect(await voice.closes == 1)
    #expect(await lines().isEmpty)
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.opens.last == [])
    voice.emit(.userUtterance("Remember the colour red."))
    #expect(
      await eventually {
        await lines() == ["You: Remember the colour red."]
      })
    try await post("/v1/target", TargetBody(sessionId: a))  // the band's way
    #expect(await voice.closes == 2)
    #expect(await lines() == ["You: Remember the colour teal."])
    await bridge.audioEvent(.speechStarted)
    #expect(
      await voice.opens.last == [InitialItem(role: .user, text: "Remember the colour teal.")])
  }

  /// The menu gets the target's whole conversation, its context and this call's minutes; the
  /// status, which every joined session's poll carries, has none of them.
  @Test func onlyTheAppGetsTheTargetsConversation() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await post("/v1/context", ContextBody(sessionId: a, summary: "Alpha's work."))
    await live()
    let said = (1...5).map { "Remember line \($0)." }
    for line in said { voice.emit(.userUtterance(line)) }
    #expect(await eventually { await lines().count == 5 })
    #expect(await lines() == said.map { "You: \($0)" })
    var updates = bridge.updates.makeAsyncIterator()
    let update = await updates.next()
    #expect(update?.conversation.map(\.text) == said)
    #expect(update?.context == "[CONTEXT] Alpha: Alpha's work.")
    let reply = await bridge.handle(
      HTTPRequest(method: "GET", path: "/v1/next", query: ["sessionId": b.rawValue], body: Data()))
    let polled = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any]
    let status = try #require(polled?["status"] as? [String: Any])
    #expect(Set(status.keys) == ["call", "sessions", "minutesToday", "unheard"])
    await bridge.setTarget(b)
    #expect(await lines().isEmpty)
  }

  /// A line is seeded with its own session's open tasks only, not another session's.
  @Test func lineIsSeededOnlyWithItsSessionsTasks() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await registry.enqueue(request(1), for: b)
    await live()
    #expect(await voice.opens.last == [])
    await bridge.setTarget(b)
    await bridge.audioEvent(.speechStarted)
    #expect(
      await voice.opens.last == [InitialItem(role: .user, text: "[TASK] Beta: Example request 1")])
  }

  /// While the line is closed, a new target changes nothing until the next speech opens it.
  @Test func targetChangeWhileClosedOpensTheNewConversation() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    voice.emit(.userUtterance("Remember the colour teal."))
    #expect(await eventually { await lines().count == 1 })
    voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await bridge.status.call == .listening })
    await bridge.setTarget(b)
    #expect(await voice.closes == 0)
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.opens.last == [])
  }

  /// The target leaving is a target change too.
  @Test func targetLeavingClosesTheLine() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await post("/v1/target", TargetBody(sessionId: b))
    await live()
    try await post("/v1/leave", LeaveBody(sessionId: b))
    #expect(await bridge.status.call == .listening)
    #expect(await voice.closes == 1)
  }

  /// A result from another session is spoken in the open line and kept in its own session's
  /// conversation, not the target's.
  @Test func resultIsKeptInItsSessionsConversation() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    try await answer(request(1), from: b)
    #expect(await voice.added == ["[RESULT] Beta: Done."])
    voice.emit(.assistantSpeaking)
    voice.emit(.assistantUtterance("Beta is done."))
    #expect(await eventually { await bridge.status.unheard == 0 })
    #expect(await lines() == ["Voice: Beta is done."])
    await bridge.setTarget(b)
    #expect(await lines() == ["Claude: [RESULT] Beta: Done."])
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.opens.last == [InitialItem(role: .user, text: "[RESULT] Beta: Done.")])
  }

  /// A result not heard yet is given to the line once it opens, so it is not seeded too.
  @Test func unheardResultIsNotSeededTwice() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    try await answer(request(1), from: a)
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval))
    #expect(
      await lines() == [
        "Claude: [RESULT] Alpha: Done.",
        "Claude: [APPROVAL] Alpha: Claude is waiting for your approval",
      ])
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.opens.last == [])
    #expect(await voice.added.count == 2)
  }

  /// Each session keeps its own context line; one from a session other than the open line's
  /// waits for that session's next line.
  @Test func contextIsKeptPerSession() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    try await post("/v1/context", ContextBody(sessionId: b, summary: "Beta's work."))
    #expect(await voice.added.isEmpty)
    #expect(await bridge.current.context == nil)
    try await post("/v1/context", ContextBody(sessionId: a, summary: "Alpha's work."))
    #expect(await voice.added == ["[CONTEXT] Alpha: Alpha's work."])
    #expect(await bridge.current.context == "[CONTEXT] Alpha: Alpha's work.")
    await bridge.setTarget(b)
    #expect(await bridge.current.context == "[CONTEXT] Beta: Beta's work.")
    await bridge.audioEvent(.speechStarted)
    #expect(
      await voice.opens.last == [InitialItem(role: .user, text: "[CONTEXT] Beta: Beta's work.")])
  }

  @Test func newConversationClearsOnlyTheTargets() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await post("/v1/context", ContextBody(sessionId: a, summary: "Alpha's work."))
    try await post("/v1/context", ContextBody(sessionId: b, summary: "Beta's work."))
    await bridge.newConversation()
    #expect(await bridge.current.context == nil)
    await bridge.setTarget(b)
    #expect(await bridge.current.context == "[CONTEXT] Beta: Beta's work.")
  }

  /// A session removed from the app (the menu's ×) loses its conversation, on disk too.
  @Test func removedSessionLosesItsConversation() async throws {
    try await join(a, "Alpha")
    try await post("/v1/context", ContextBody(sessionId: a, summary: "Alpha's work."))
    await bridge.remove(a)
    #expect(await bridge.current.context == nil)
    let restarted = try restart()
    try await restarted.join(a, "Alpha")
    #expect(await restarted.bridge.current.context == nil)
  }

  /// After `/clear` the session's new id keeps its conversation, and the open line stays open.
  @Test func clearedSessionKeepsItsConversation() async throws {
    let cleared = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")
    await live()
    voice.emit(.userUtterance("Remember the colour teal."))
    #expect(await eventually { await lines().count == 1 })
    try await post(
      "/v1/join", JoinBody(sessionId: cleared, title: "Alpha", replaces: a))
    #expect(await bridge.status.call == .live)
    #expect(await lines() == ["You: Remember the colour teal."])
    voice.emit(.userUtterance("And blue."))
    #expect(await eventually { await lines().count == 2 })
  }

  /// A conversation file that does not decode starts empty instead of failing the bridge.
  @Test func anUnreadableConversationFileStartsEmpty() async throws {
    try Data("not json".utf8).write(to: dir.appending(path: "continuity.json"))
    let restarted = try restart()
    try await restarted.join(a, "Alpha")
    #expect(await restarted.bridge.current.context == nil)
    #expect(await restarted.lines().isEmpty)
  }

  @Test func stopThenStartResumesConversation() async throws {
    await live()
    voice.emit(.userUtterance("Remember the colour teal."))
    #expect(
      await eventually {
        await lines() == ["You: Remember the colour teal."]
      })
    await bridge.perform(.stop)
    await live()
    #expect(await voice.opens.last == [InitialItem(role: .user, text: "Remember the colour teal.")])
  }

  @Test func newConversationClearsContinuity() async throws {
    await live()
    voice.emit(.userUtterance("Remember the colour teal."))
    #expect(await eventually { await !lines().isEmpty })
    await bridge.perform(.stop)
    await bridge.newConversation()
    await live()
    #expect(await voice.opens.last == [])
    #expect(await lines().isEmpty)
  }

  @Test func meterCountsOnlyLiveIntervals() async throws {
    await live()
    time.advance(by: .seconds(3))
    voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await bridge.status.call == .listening })
    time.advance(by: .seconds(10))  // listening is not metered
    await bridge.audioEvent(.speechStarted)
    time.advance(by: .seconds(2))
    voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await bridge.status.call == .listening })
    #expect(await bridge.current.minutesThisCall == 5.0 / 60)
    await bridge.perform(.stop)
    await bridge.perform(.start)
    #expect(await bridge.current.minutesThisCall == 0)
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
    await bridge.audioEvent(.failed(.other("No microphone is connected.")))
    #expect(await bridge.status.call == .off)
    #expect(await bridge.status.problem == "No microphone is connected.")
    #expect(await audio.calls.contains("stopListening"))
  }
}
