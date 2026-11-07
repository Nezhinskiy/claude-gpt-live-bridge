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
  /// macOS's answer for the microphone. While `holdsPrompt`, each ask waits for
  /// `answerPrompt(_:)`, as macOS's first-run prompt waits for the owner.
  var refusal: Problem?
  var holdsPrompt = false
  private var prompts: [CheckedContinuation<Problem?, Never>] = []
  var promptWaiting: Int { prompts.count }
  func refuse(_ problem: Problem) { refusal = problem }
  func holdPrompt() { holdsPrompt = true }
  func answerPrompt(_ problem: Problem? = nil) {
    holdsPrompt = false
    for prompt in prompts { prompt.resume(returning: problem) }
    prompts = []
  }
  func microphoneProblem() async -> Problem? {
    guard holdsPrompt else { return refusal }
    return await withCheckedContinuation { prompts.append($0) }
  }
  /// The microphone calls, in order.
  var microphone: [String] {
    calls.filter { ["startListening", "muteMicrophone", "unmuteMicrophone"].contains($0) }
  }
  func startListening() { calls.append("startListening") }
  func stopListening() { calls.append("stopListening") }
  /// While set, the next offer waits for `releaseOffer()`, as the page takes a moment to make one.
  var holdsOffer = false
  private var heldOffers: [CheckedContinuation<Void, Never>] = []
  var offerWaiting: Int { heldOffers.count }
  func holdOffer() { holdsOffer = true }
  func releaseOffer() {
    for wait in heldOffers { wait.resume() }
    heldOffers = []
  }
  /// Whether each offer carried the pre-roll.
  var offers: [Bool] = []
  func makeOffer(preroll: Bool) async -> String {
    if holdsOffer {
      holdsOffer = false
      await withCheckedContinuation { heldOffers.append($0) }
    }
    offers.append(preroll)
    return "offer"
  }
  func applyAnswer(_ sdp: String) throws {
    if answerFails { throw CodexProblem.protocolMismatch("no session.started") }
    calls.append("applyAnswer")
    time.advance(by: .seconds(1))
  }
  func flushPreroll() { calls.append("flushPreroll") }
  func closePeer() { calls.append("closePeer") }
  func chime() { calls.append("chime") }
  /// While set, the next answer's sound waits for `releaseSound()`, as a hop to the main actor
  /// lets others in.
  var holdsSound = false
  private var heldSounds: [CheckedContinuation<Void, Never>] = []
  var soundWaiting: Int { heldSounds.count }
  func holdSound() { holdsSound = true }
  func releaseSound() {
    for wait in heldSounds { wait.resume() }
    heldSounds = []
  }
  func confirmAnswer() async {
    calls.append("confirmAnswer")
    guard holdsSound else { return }
    holdsSound = false
    await withCheckedContinuation { heldSounds.append($0) }
  }
  func confirmHandoff() { calls.append("confirmHandoff") }
  func muteMicrophone() { calls.append("muteMicrophone") }
  func unmuteMicrophone() { calls.append("unmuteMicrophone") }
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
  /// Settings' pause, which a test may flip.
  let pause: OSAllocatedUnfairLock<Bool>
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")

  /// `dir` and `time` are given to restart the app on another test's data.
  init(
    realtime: (@Sendable () async throws -> any RealtimeControlling)? = nil, dir: URL? = nil,
    time: TestTime = TestTime(), notifies: @escaping @Sendable () -> Bool = { true },
    confirmsWithSound: @escaping @Sendable () -> Bool = { true }, pausesSync: Bool = false,
    appVersion: AppVersion? = nil
  ) throws {
    self.time = time
    let pause = OSAllocatedUnfairLock(initialState: pausesSync)
    self.pause = pause
    self.dir = try dir ?? temporaryDirectory()
    registry = SessionRegistry(time: time)
    audio = FakeAudio(time: time)
    bridge = Bridge(
      registry: registry, realtime: realtime ?? { [voice] in voice }, audio: audio,
      meter: UsageMeterStore(file: self.dir.appending(path: "usage.json"), time: time),
      continuityFile: self.dir.appending(path: "continuity.json"), time: time,
      notifier: notifier, notifies: notifies, confirmsWithSound: confirmsWithSound,
      pausesSync: { pause.withLock { $0 } }, appVersion: appVersion)
  }

  @discardableResult
  func post(_ path: String, _ body: some Encodable) async throws -> HTTPResponse {
    let body = try JSONEncoder().encode(body)
    return await bridge.handle(
      HTTPRequest(method: "POST", path: path, query: [:], body: body))
  }

  func join(
    _ id: SessionID, _ title: String, modVersion: String? = nil, owner: Bool? = nil,
    syncs: Bool? = true, missed: Bool? = nil
  ) async throws {
    try await post(
      "/v1/join",
      JoinBody(
        sessionId: id, title: title, owner: owner, modVersion: modVersion, syncs: syncs,
        missed: missed))
  }

  func setPause(_ on: Bool) { pause.withLock { $0 = on } }

  /// A line of a turn, as the mod posts it.
  @discardableResult
  func sync(
    _ id: SessionID, turn: String = "turn-1", request: RequestID? = nil, kind: SyncKind = .typed,
    _ text: String? = nil
  ) async throws -> HTTPResponse {
    try await post(
      "/v1/sync",
      SyncBody(
        sessionId: id, turn: TurnRef(id: turn, request: request), kind: kind, text: text))
  }

  /// The conversations as saved, which a restarted app reads.
  func saved() throws -> Continuity {
    try JSONDecoder().decode(
      Continuity.self, from: Data(contentsOf: dir.appending(path: "continuity.json")))
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

  @Test func muteReachesTheAudioSide() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    try await test.post("/v1/call", CallBody(action: .mute))
    #expect(await test.audio.calls.last == "muteMicrophone")
    #expect(await test.bridge.status.isMuted)
  }

  @Test func unmuteReachesTheAudioSide() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    try await test.post("/v1/call", CallBody(action: .mute))
    try await test.post("/v1/call", CallBody(action: .unmute))
    #expect(await test.audio.calls.last == "unmuteMicrophone")
    #expect(await !test.bridge.status.isMuted)
  }

  @Test func stopWhileMutedThenStartListensUnmuted() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    try await test.post("/v1/call", CallBody(action: .mute))
    await test.bridge.perform(.stop)
    await test.bridge.perform(.start)
    #expect(await test.audio.calls.last == "startListening")
    #expect(await !test.bridge.status.isMuted)
  }

  /// macOS's first-run prompt can stay up while the owner presses Stop: the Start waiting on
  /// it does not open the microphone after the call ended.
  @Test func aStopDuringStartsPromptOpensNoMicrophone() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.audio.holdPrompt()
    async let start: Void = test.bridge.perform(.start)
    #expect(await eventually { await test.audio.promptWaiting == 1 })
    await test.bridge.perform(.stop)
    await test.audio.answerPrompt()
    _ = await start
    #expect(await test.audio.microphone == [])
  }

  /// A Mute while Start's prompt is up does not cancel the Start: the page records the mute
  /// first, so the listen that follows takes nothing.
  @Test func aMuteDuringStartsPromptListensAfterTheMute() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.audio.holdPrompt()
    async let start: Void = test.bridge.perform(.start)
    #expect(await eventually { await test.audio.promptWaiting == 1 })
    await test.bridge.perform(.mute)
    await test.audio.answerPrompt()
    _ = await start
    #expect(await test.audio.microphone == ["muteMicrophone", "startListening"])
  }

  /// A Mute while Unmute's prompt is up wins over the Unmute, which then takes nothing.
  @Test func aMuteDuringUnmutesPromptTakesNoMicrophone() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    await test.bridge.perform(.mute)
    await test.audio.holdPrompt()
    async let unmute: Void = test.bridge.perform(.unmute)
    #expect(await eventually { await test.audio.promptWaiting == 1 })
    await test.bridge.perform(.mute)
    await test.audio.answerPrompt()
    _ = await unmute
    #expect(await !test.audio.microphone.contains("unmuteMicrophone"))
  }

  /// A Stop while Unmute's prompt is up wins over the Unmute, which then takes nothing.
  @Test func aStopDuringUnmutesPromptTakesNoMicrophone() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    await test.bridge.perform(.mute)
    await test.audio.holdPrompt()
    async let unmute: Void = test.bridge.perform(.unmute)
    #expect(await eventually { await test.audio.promptWaiting == 1 })
    await test.bridge.perform(.stop)
    await test.audio.answerPrompt()
    _ = await unmute
    #expect(await !test.audio.microphone.contains("unmuteMicrophone"))
  }

  /// macOS refusing an Unmute the owner already undid with a Mute leaves the muted call as it
  /// is: nothing was going to take the microphone.
  @Test func aRefusalForAnUnmuteAMuteUndidIsNotReported() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    await test.bridge.perform(.mute)
    await test.audio.holdPrompt()
    async let unmute: Void = test.bridge.perform(.unmute)
    #expect(await eventually { await test.audio.promptWaiting == 1 })
    await test.bridge.perform(.mute)
    await test.audio.answerPrompt(.microphoneDenied)
    _ = await unmute
    #expect(await test.bridge.status.call == .listening)
    #expect(await test.bridge.status.problem == nil)
  }

  /// macOS refusing a Start the owner already stopped shows nothing: the owner ended the call.
  @Test func aRefusalForAStoppedStartIsNotReported() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.audio.holdPrompt()
    async let start: Void = test.bridge.perform(.start)
    #expect(await eventually { await test.audio.promptWaiting == 1 })
    await test.bridge.perform(.stop)
    await test.audio.answerPrompt(.microphoneDenied)
    _ = await start
    #expect(await test.bridge.status.problem == nil)
  }

  @Test func aRefusedStartEndsTheCallWithTheRefusal() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.audio.refuse(.microphoneDenied)
    await test.bridge.perform(.start)
    #expect(await test.bridge.status.call == .off)
    #expect(await test.bridge.status.problem == Problem.microphoneDenied.sentence)
  }

  @Test func aRefusedUnmuteEndsTheCallWithTheRefusal() async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    await test.bridge.perform(.mute)
    await test.audio.refuse(.microphoneDenied)
    await test.bridge.perform(.unmute)
    #expect(await test.bridge.status.call == .off)
    #expect(await test.bridge.status.problem == Problem.microphoneDenied.sentence)
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

  /// The only session leaving while codex is still launching stops the Start there, as a Stop
  /// then would: it says why at once, the launched codex is ended and the microphone stays off.
  @Test func lastSessionLeavingDuringStartLeavesTheCallOff() async throws {
    let voices = FakeVoices()
    let test = try BridgeTests { await voices.make() }
    try await test.join(a, "Alpha")
    await voices.setSlow()
    async let start: Void = test.bridge.perform(.start)
    #expect(await eventually { await voices.waiting == 1 })
    try await test.post("/v1/leave", LeaveBody(sessionId: a))
    #expect(await test.bridge.status.problem == Problem.noSession.sentence)
    await voices.finishLaunch()
    _ = await start
    #expect(await test.bridge.status.call == .off)
    #expect(await voices.made.first?.shutdowns == 1)
    #expect(await !test.audio.calls.contains("startListening"))
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
  /// What Claude wrote before asking rides in the question's line, its code and tables removed
  /// as from a result.
  @Test func aQuestionsLineHasNoCodeOrTables() async throws {
    try await join(a, "Alpha")
    try await registry.enqueue(request(1), for: a)
    #expect(try await registry.poll(a) == .request(request(1)))
    await live()
    await bridge.audioEvent(.speechEnded)
    let question = "Which name? Options: out."
    let text = "Two folders.\n```\nrm -rf build\n```\n| a | b |\nPick one."
    try await post(
      "/v1/activity", ActivityBody(sessionId: a, state: .approval, question: question, text: text))
    let said = "Which name? Options: out. Claude wrote just before asking: Two folders. Pick one."
    #expect(await voice.spoken == ["[ASKING] Alpha: \(said)"])
  }

  /// What Claude wrote in the step that asked for a permission follows the approval notice,
  /// its code and tables removed as from a result.
  @Test func anApprovalsLineCarriesTheStepsProse() async throws {
    try await join(a, "Alpha")
    await live()
    await bridge.audioEvent(.speechEnded)
    let text = "Deleting build.\n```\nrm -rf build\n```\n| a | b |\nThen test."
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval, text: text))
    let notice = "Claude is waiting for your approval"
    let said = "\(notice). Claude wrote just before asking: Deleting build. Then test."
    #expect(await voice.spoken == ["[APPROVAL] Alpha: \(said)"])
  }

  /// A step that wrote only code or a table adds nothing to the notice.
  @Test func anApprovalAfterACodeOnlyStepIsTheNoticeAlone() async throws {
    try await join(a, "Alpha")
    await live()
    await bridge.audioEvent(.speechEnded)
    let text = "```\nrm -rf build\n```\n| a | b |"
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval, text: text))
    #expect(await voice.spoken == ["[APPROVAL] Alpha: Claude is waiting for your approval"])
  }

  /// What the app shows lists the joined sessions whose mod is older than the app.
  @Test func theAppListsSessionsOnAnOlderMod() async throws {
    let test = try BridgeTests(appVersion: AppVersion("0.3.1"))
    try await test.join(a, "Alpha", modVersion: "0.3.0")
    try await test.join(b, "Beta", modVersion: "0.3.1")
    #expect(await test.bridge.current.labelsOnAnOlderMod == ["Alpha"])
  }

  /// An app whose own version does not read lists nobody.
  @Test func anAppWithNoVersionListsNoOldMods() async throws {
    let test = try BridgeTests(appVersion: nil)
    try await test.join(a, "Alpha", modVersion: "0.3.0")
    #expect(await test.bridge.current.labelsOnAnOlderMod == [])
  }

  /// On a live line a typed turn's question is given to say, as a voice turn's is.
  @Test func aTypedTurnsQuestionIsSaidOnItsOwnLine() async throws {
    try await join(a, "Alpha")
    await live()
    await bridge.audioEvent(.speechEnded)
    try await sync(a, "Rename it.")
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    #expect(await voice.spoken == ["[ASKING] Alpha: Which name?"])
  }

  /// A step's text longer than a line is cut, and the notice before it stays whole.
  @Test func aLongStepTextNeverCutsTheNotice() async throws {
    try await join(a, "Alpha")
    await live()
    await bridge.audioEvent(.speechEnded)
    let text = String(repeating: "Deleting build. ", count: 200)
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval, text: text))
    let line = try #require(await voice.spoken.first)
    #expect(line.hasPrefix("[APPROVAL] Alpha: Claude is waiting for your approval. Claude wrote"))
    #expect(line.count <= AnswerShaper.maxCharacters)
  }

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
    let reply = Work.reply(request(2), forRequest: request(1).id)
    #expect(try await eventually { try await registry.poll(a) == reply })
  }

  /// A handoff queued for a session is confirmed by a sound, so the owner can tell a request
  /// that went to Claude from a voice that only said it would look (BR-001).
  @Test func handoffToASessionIsConfirmedBySound() async throws {
    try await join(a, "Alpha")
    await live()
    voice.emit(.handoff(request(1)))
    #expect(try await eventually { try await registry.poll(a) == .request(request(1)) })
    #expect(await eventually { await audio.calls.filter { $0 == "confirmHandoff" }.count == 1 })
  }

  /// What the voice handed off shows in the conversation of the session it went to: here the
  /// one that asked, not the target.
  @Test func handoffIsShownInTheSessionItWentTo() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    try await answer(request(1), from: b, .question, "Which branch?")
    voice.emit(.handoff(request(2)))
    #expect(try await eventually { try await registry.poll(b) == .request(request(2)) })
    #expect(await lines().isEmpty)
    await bridge.setTarget(b)
    #expect(
      await lines() == ["Claude: [QUESTION] Beta: Which branch?", "Task: Example request 2"])
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

  /// A question asked before Stop, or said before the owner picked a target, routes nothing later.
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
    await voices.made.last?.emit(.assistantUtterance("On it."))  // the handoff's acknowledgement
    try await test.answer(request(3), from: b, .question, "Which file?")
    await voices.made.last?.emit(.assistantSpeaking("Hello"))
    await voices.made.last?.emit(.assistantUtterance("Beta asks which file."))
    #expect(await eventually { await test.bridge.status.unheard == 0 })
    await test.bridge.setTarget(a)
    await voices.made.last?.emit(.handoff(request(4)))
    let task = "[TASK] Alpha: Example request 4"
    #expect(await eventually { await test.registry.openTasks().contains(task) })
  }

  /// A failed microphone ends the call as Stop does, and the route with it.
  @Test func aFailedMicrophoneEndsTheRoute() async throws {
    let voices = FakeVoices()
    let test = try BridgeTests { await voices.make() }
    try await test.join(a, "Alpha")
    try await test.join(b, "Beta")
    await test.live()
    try await test.answer(request(1), from: b, .question, "Which branch?")
    await test.bridge.audioEvent(.failed(.other("The microphone failed.")))
    #expect(await test.bridge.status.call == .off)
    await test.live()
    await voices.made.last?.emit(.handoff(request(2)))
    #expect(try await eventually { try await test.registry.poll(a) == .request(request(2)) })
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
    voice.emit(.assistantSpeaking("Hello"))
    voice.emit(.assistantUtterance("I"))  // cut off by the owner
    voice.emit(.assistantSpeaking("Hello"))
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

  /// Settings' handoff sound is read at each handoff; off, the request still goes.
  @Test func handoffSoundCanBeTurnedOff() async throws {
    let settings = SettingsStore(file: nil)
    let test = try BridgeTests(confirmsWithSound: { settings.current.confirmHandoffs })
    settings.update { $0.confirmHandoffs = false }
    try await test.join(a, "Alpha")
    await test.live()
    test.voice.emit(.handoff(request(1)))
    #expect(try await eventually { try await test.registry.poll(a) == .request(request(1)) })
    #expect(await !test.audio.calls.contains("confirmHandoff"))
  }

  /// The same setting holds the sound for an answer that does not wait; on, it posts no notice.
  @Test func answerSoundFollowsTheSoundSetting() async throws {
    let settings = SettingsStore(file: nil)
    let test = try BridgeTests(confirmsWithSound: { settings.current.confirmHandoffs })
    try await test.join(a, "Alpha")
    await test.live()
    #expect(await eventually { await test.bridge.status.call == .live })
    await test.bridge.audioEvent(.speechEnded)
    try await test.answer(request(1), from: a)
    #expect(await test.audio.calls.contains("confirmAnswer"))
    #expect(await test.notifier.posted.isEmpty)
    settings.update { $0.confirmHandoffs = false }
    try await test.answer(request(2), from: a)
    #expect(await test.voice.added.count == 2)
    #expect(await test.audio.calls.filter { $0 == "confirmAnswer" }.count == 1)
  }

  /// The waiting chime is the only sign of that result, so the sound setting leaves it on.
  @Test func theChimeDoesNotFollowTheSoundSetting() async throws {
    let test = try BridgeTests(confirmsWithSound: { false })
    try await test.join(a, "Alpha")
    await test.bridge.perform(.start)
    try await test.answer(request(1), from: a)
    #expect(await test.audio.calls.contains("chime"))
  }

  /// The attempt exists before the answer's sound, so a Stop while it plays ends it.
  @Test func noLineOpensAfterAStopWhileAnOpeningAnswerSounds() async throws {
    try await closedAfterARequest()
    await audio.holdSound()
    let answering = Task { try await answerFirstRequest() }
    #expect(await eventually { await audio.soundWaiting == 1 })
    await bridge.perform(.stop)
    let opens = await voice.opens.count
    await audio.releaseSound()
    try await answering.value
    #expect(await bridge.status.call == .off)
    try await Task.sleep(for: .milliseconds(100))  // a line opened late would be there by now
    #expect(await voice.opens.count == opens)
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

  /// Silence does not close a line that waits for a result; the window does, and the result
  /// after it opens the line again, without the pre-roll, to be said.
  @Test func anUnansweredHandoffClosesTheLineAfterTheWindow() async throws {
    await live()
    await bridge.audioEvent(.speechEnded)
    voice.emit(.userUtterance("Example request 1"))
    try await handOff()
    // the window's own timer, armed before the clock moves: a count of sleepers can be made up
    // of silence timers while the handoff still waits to be handled
    let window = time.now + Double(CallMachine.resultWindowSeconds)
    #expect(await eventually { time.deadlines.contains(window) })
    for second in 1..<CallMachine.resultWindowSeconds {
      time.advance(by: .seconds(1))
      _ = try await registry.poll(a)  // the session stays joined
      if second == CallMachine.silenceSeconds + 1 { #expect(await bridge.status.call == .live) }
    }
    #expect(await bridge.status.call == .live)
    time.advance(by: .seconds(1))
    #expect(await eventually { await bridge.status.call == .listening })
    try await answerFirstRequest()
    #expect(await eventually { await voice.opens.count == 2 })
    #expect(await audio.offers == [true, false])
    #expect(await !audio.calls.contains("chime"))
  }

  /// The owner asked Alpha, the target, for something, and the line has since closed.
  func closedAfterARequest() async throws {
    await live()
    await bridge.audioEvent(.speechEnded)
    voice.emit(.userUtterance("Example request 1"))
    try await handOff()
    voice.emit(.closed(.other("closed")))
    #expect(await eventually { await bridge.status.call == .listening })
  }

  /// The answer opens the line without holding the mod's request while it connects.
  @Test func anOpeningAnswerDoesNotWaitForTheConnect() async throws {
    try await closedAfterARequest()
    await voice.holdOpen()
    try await answerFirstRequest()
    #expect(await eventually { await voice.openWaiting == 1 })
    await voice.releaseOpen()
    #expect(await eventually { await bridge.status.call == .live })
  }

  /// An answer for a session that is not the target only chimes: the owner switches to it.
  @Test func anAnswerForASessionNotTheTargetOnlyChimes() async throws {
    try await closedAfterARequest()
    try await join(b, "Beta")
    try await post("/v1/target", TargetBody(sessionId: b))
    try await answerFirstRequest()
    #expect(await eventually { await audio.calls.contains("chime") })
    #expect(await voice.opens.count == 1)
  }

  /// Once its session is the target again, an answer opens the line.
  @Test func anAnswerOpensTheLineWhenItsSessionIsTheTargetAgain() async throws {
    try await closedAfterARequest()
    try await join(b, "Beta")
    try await post("/v1/target", TargetBody(sessionId: b))
    try await post("/v1/target", TargetBody(sessionId: a))
    try await answerFirstRequest()
    #expect(await eventually { await voice.opens.count == 2 })
    #expect(await !audio.calls.contains("chime"))
  }

  /// With the target's conversation erased, a new line would hold no request of the owner's and
  /// stay silent (ADR 0001 (b)), so the answer only chimes.
  @Test func anAnswerAfterNewConversationOnlyChimes() async throws {
    try await closedAfterARequest()
    await bridge.newConversation()
    try await answerFirstRequest()
    #expect(await eventually { await audio.calls.contains("chime") })
    #expect(await voice.opens.count == 1)
  }

  /// After the answer, an update only chimes; an approval notice and a question Claude asks open
  /// the line.
  @Test func anApprovalAndAQuestionOpenTheLineAnUpdateChimes() async throws {
    try await closedAfterARequest()
    try await answerFirstRequest()
    #expect(await eventually { await voice.opens.count == 2 })
    voice.emit(.closed(.other("closed")))
    #expect(await eventually { await bridge.status.call == .listening })
    let chimes = { await audio.calls.filter { $0 == "chime" }.count }
    let before = await chimes()
    try await post(
      "/v1/answer",
      AnswerBody(sessionId: a, id: request(1).id, status: .update, text: "Tests pass.", reason: nil)
    )
    #expect(await chimes() == before + 1)
    #expect(await voice.opens.count == 2)
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval))
    #expect(await eventually { await voice.opens.count == 3 })
    voice.emit(.closed(.other("closed")))
    #expect(await eventually { await bridge.status.call == .listening })
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .working))
    try await post(
      "/v1/activity", ActivityBody(sessionId: a, state: .approval, question: "Which branch?"))
    #expect(await eventually { await voice.opens.count == 4 })
  }

  /// The last session leaving stops the call, as Start with none refuses: nobody is left to
  /// talk to.
  @Test func lastSessionLeavingStopsTheCall() async throws {
    await live()
    try await post("/v1/leave", LeaveBody(sessionId: a))
    #expect(await bridge.status.call == .off)
    #expect(await bridge.status.problem == Problem.noSession.sentence)
    #expect(await voice.shutdowns == 1)
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

  /// The voice cannot open a line until the limit resets, so words must not open failing lines.
  @Test func aUsageLimitAtOpenEndsTheCall() async throws {
    try await join(a, "Alpha")
    await voice.fail(with: .realtimeError("You’ve hit your usage limit. Try again later."))
    await live()
    #expect(await bridge.status.call == .off)
    #expect(await bridge.status.problem?.contains("usage limit is reached") == true)
    #expect(await voice.shutdowns == 1)
    #expect(await audio.calls.contains("stopListening"))
  }

  @Test func aUsageLimitInCodexsClosedEndsTheCall() async throws {
    try await join(a, "Alpha")
    await live()
    voice.emit(.closed(.codex(.realtimeError("You’ve hit your usage limit. Try again later."))))
    #expect(await eventually { await bridge.status.call == .off })
    #expect(await eventually { await voice.shutdowns == 1 })
  }

  @Test func theServiceRefusingEndsTheCall() async throws {
    try await join(a, "Alpha")
    await live()
    await bridge.audioEvent(
      .lineError(code: "usage_check_failed", message: "Unable to verify usage availability."))
    #expect(await bridge.status.call == .off)
    let problem = try #require(await bridge.status.problem)
    #expect(problem.contains("Unable to verify usage availability."))
    #expect(await audio.calls.contains("closePeer"))
    #expect(await voice.shutdowns == 1)
  }

  /// An error before `session.started` comes while the line is still connecting.
  @Test func theServiceRefusingEndsAConnectingLine() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    await voice.holdOpen()
    let opening = Task { await bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await voice.openWaiting == 1 })
    await bridge.audioEvent(.lineError(code: "usage_check_failed", message: "No."))
    await voice.releaseOpen()
    await opening.value
    #expect(await bridge.status.call == .off)
    #expect(await bridge.status.problem?.contains("No.") == true)
  }

  /// The voice may have closed first: the line that said so is gone, and the limit still holds.
  @Test func theServiceRefusingAfterTheLineClosedEndsTheCall() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    await bridge.audioEvent(.lineError(code: "usage_limit_reached", message: "No."))
    #expect(await bridge.status.call == .off)
  }

  @Test func anotherDataChannelErrorLeavesTheLineOpen() async throws {
    try await join(a, "Alpha")
    await live()
    await bridge.audioEvent(.lineError(code: "invalid_request", message: "Unknown event."))
    #expect(await bridge.status.call == .live)
    #expect(await bridge.status.problem == nil)
  }

  /// A kept question still answers to its session, and the reply must not go to the target.
  @Test func aKeptQuestionKeepsItsRoute() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    try await post("/v1/activity", ActivityBody(sessionId: b, state: .approval, question: "Which?"))
    voice.emit(.closed(.codex(.realtimeError("You’ve hit your usage limit."))))
    #expect(await eventually { await bridge.status.call == .off })
    await bridge.perform(.start)
    await live()
    voice.emit(.handoff(request(2)))
    #expect(await eventually { (try? await registry.poll(b)) != nil })
  }

  /// A question the voice has said is no longer kept, and an unrelated handoff must not follow it.
  @Test func aQuestionAlreadySaidLeavesNoRoute() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    try await post(
      "/v1/activity", ActivityBody(sessionId: b, state: .approval, question: "Deploy which branch?")
    )
    voice.emit(.assistantSpeaking("Hello"))
    voice.emit(.assistantUtterance("Beta asks: deploy which branch?"))
    #expect(await eventually { await bridge.status.unheard == 0 })
    voice.emit(.closed(.codex(.realtimeError("You’ve hit your usage limit."))))
    #expect(await eventually { await bridge.status.call == .off })
    await bridge.perform(.start)
    await live()
    voice.emit(.handoff(request(2)))
    #expect(try await eventually { try await registry.poll(a) == .request(request(2)) })
    #expect(try await registry.poll(b) == nil)
  }

  /// The pause keeps lines, so a question that arrives during it routes as on a live call.
  @Test func aQuestionDuringThePauseKeepsItsRoute() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    voice.emit(.closed(.codex(.realtimeError("You’ve hit your usage limit."))))
    #expect(await eventually { await bridge.status.call == .off })
    try await post("/v1/activity", ActivityBody(sessionId: b, state: .approval, question: "Which?"))
    #expect(await bridge.status.unheard == 1)
    await bridge.perform(.start)
    await live()
    voice.emit(.handoff(request(2)))
    #expect(await eventually { (try? await registry.poll(b)) != nil })
  }

  @Test func aLinePausedAtALimitNotifiesToStartFirst() async throws {
    try await join(a, "Alpha")
    await live()
    voice.emit(.closed(.codex(.realtimeError("You’ve hit your usage limit."))))
    #expect(await eventually { await bridge.status.call == .off })
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval, question: "Which?"))
    #expect(
      await eventually { await notifier.posted.last?.body.contains("start the call") == true })
  }

  /// The ask dates the summary, so it outlives a restart, or the summary clears a gap it missed.
  @Test func aSummaryAskedForBeforeARestartClearsNoLaterPause() async throws {
    let test = try BridgeTests()
    try await test.join(test.a, "Alpha")
    await test.bridge.loadContext()
    let restarted = try test.restart()
    restarted.setPause(true)
    try await restarted.join(test.a, "Alpha")
    try await restarted.sync(test.a, kind: .start)  // refused, so the session is paused
    try await restarted.post("/v1/context", ContextBody(sessionId: test.a, summary: "Old."))
    #expect(await restarted.bridge.current.needsContext)
  }

  /// A summary asked for before a refused turn does not hold that turn, so the session stays out
  /// of sync and the voice keeps what it had.
  @Test func aSummaryAskedForBeforeAPausedTurnClearsNothing() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(a, "Alpha")
    try await test.post("/v1/context", ContextBody(sessionId: a, summary: "Old."))
    await test.live()
    await test.bridge.loadContext()
    #expect(try await test.registry.poll(a) == .context)
    await test.bridge.perform(.stop)
    try await test.sync(a, turn: "turn-2", "Private thing.")
    try await test.post("/v1/context", ContextBody(sessionId: a, summary: "From before."))
    #expect(try test.saved()[a].outOfSync == .paused)
    #expect(await test.bridge.current.needsContext)
    #expect(await test.bridge.current.context == "[CONTEXT] Alpha: Old.")
  }

  /// A summary on its way when the owner presses New conversation does not bring back what was
  /// just forgotten.
  @Test func aSummaryAskedForBeforeNewConversationIsIgnored() async throws {
    try await join(a, "Alpha")
    await bridge.loadContext()
    #expect(try await registry.poll(a) == .context)
    await bridge.newConversation()
    try await post("/v1/context", ContextBody(sessionId: a, summary: "Everything from before."))
    #expect(await bridge.current.context == nil)
  }

  /// The menu's press stays pending for an ignored summary: nothing loaded.
  @Test func anIgnoredSummaryIsNotAnnounced() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    var arrivals = bridge.contextArrivals.makeAsyncIterator()
    await bridge.loadContext()
    await bridge.newConversation()
    try await post("/v1/context", ContextBody(sessionId: a, summary: "Everything from before."))
    try await post("/v1/context", ContextBody(sessionId: b, summary: "Beta's work."))
    #expect(await arrivals.next() == b)
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

  // MARK: Context when a line opens

  let summary = "[CONTEXT] Alpha: Alpha's work."
  func context(_ summary: String = "Alpha's work.") -> ContextBody {
    ContextBody(sessionId: a, summary: summary)
  }

  /// An empty summary keeps the stored context and reaches no line. The mod never sends one; the
  /// guard is against another socket peer, not a control.
  @Test func anEmptySummaryKeepsTheStoredContext() async throws {
    try await join(a, "Alpha")
    try await post("/v1/context", context())
    await live()
    try await post("/v1/context", context(" "))
    #expect(await bridge.current.context == summary)
    #expect(await voice.added.isEmpty)
  }

  /// The first line a Start opens asks a target with no context for one; Claude gets no request.
  @Test func aLineWithNoContextAsksForASummary() async throws {
    let test = try BridgeTests()
    await test.live()
    #expect(try await test.registry.poll(test.a) == .context)
    #expect(try await test.registry.poll(test.a) == nil)
  }

  /// A line reopened after the voice closed it asks again.
  @Test func reopeningALineAsksForContext() async throws {
    let test = try BridgeTests()
    await test.live()
    _ = try await test.registry.poll(test.a)
    test.voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await test.bridge.status.call == .listening })
    await test.bridge.audioEvent(.speechStarted)
    #expect(try await test.registry.poll(test.a) == .context)
  }

  /// The line after a target switch asks the new target, and the old target is not asked.
  @Test func theLineAfterATargetSwitchAsksTheNewTarget() async throws {
    let test = try BridgeTests()
    try await test.join(test.a, "Alpha")
    try await test.join(test.b, "Beta")
    await test.live()
    _ = try await test.registry.poll(test.a)
    await test.bridge.setTarget(test.b)
    #expect(try await test.registry.poll(test.b) == nil)  // switching asks for nothing
    await test.bridge.audioEvent(.speechStarted)
    #expect(try await test.registry.poll(test.b) == .context)
    #expect(try await test.registry.poll(test.a) == nil)
  }

  /// A session whose summary the voice holds in full is asked for nothing.
  @Test func aCurrentLineAsksForNothing() async throws {
    try await join(a, "Alpha")
    try await post("/v1/context", context())
    try await sync(a, "Fix the build.")
    await live()
    #expect(try await registry.poll(a) == nil)
  }

  @Test func aMissedLineAsksForASummary() async throws {
    try await join(a, "Alpha")
    try await post("/v1/context", context())
    try await join(a, "Alpha", missed: true)
    await live()
    #expect(try await registry.poll(a) == .context)
  }

  /// A paused mark outlasts the setting: the owner decides with Load context. Also with no
  /// context at all.
  @Test func aPausedLineAsksForNothing() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    test.setPause(false)
    await test.live()
    #expect(try await test.registry.poll(test.a) == nil)
  }

  /// With the setting on no line asks, whatever the reason it would: no context, a missed turn,
  /// a mod that does not sync. Load context still asks.
  @Test(arguments: [(false, true), (true, true), (false, false)])
  func thePauseSettingStopsEverySummary(missed: Bool, syncs: Bool) async throws {
    let test = try BridgeTests()
    try await test.join(test.a, "Alpha", syncs: syncs)
    if missed || !syncs { try await test.post("/v1/context", test.context()) }
    // missed with the setting off: only the setting itself keeps the summary away
    if missed { try await test.join(test.a, "Alpha", missed: true) }
    test.setPause(true)
    await test.live()
    #expect(try await test.registry.poll(test.a) == nil)
    await test.bridge.loadContext()
    #expect(try await test.registry.poll(test.a) == .context)
  }

  /// The menu's Load context follows `needsContext`, for each cause and for a current voice.
  @Test func needsContextHoldsForEachCause() async throws {
    try await join(a, "Alpha")
    #expect(await bridge.current.contextNeed == .withTheLine)  // no context, nothing lost
    try await post("/v1/context", context())
    #expect(await bridge.current.contextNeed == .none)  // current
    try await join(a, "Alpha", missed: true)
    #expect(await bridge.current.needsContext)  // missed
    try await post("/v1/context", context())
    #expect(await !bridge.current.needsContext)
    try await join(a, "Alpha", syncs: nil)
    #expect(await bridge.current.needsContext)  // a mod that does not sync
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.post("/v1/context", test.context())
    try await test.sync(test.a, "Private thing.")
    #expect(await test.bridge.current.needsContext)  // paused
  }

  /// No line loads a summary while the pause setting is on, so only a press can.
  @Test func withThePauseSettingOnASessionWithNoSummaryNeedsAPress() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    #expect(await test.bridge.current.contextNeed == .load)
  }

  /// More lines than the seed carries are lost to the voice, summary or none.
  @Test func linesTheSeedCannotCarryNeedAPress() async throws {
    try await join(a, "Alpha")
    try await sync(a, "Hello.")
    #expect(await bridge.current.contextNeed == .withTheLine)
    for n in 0..<70 { try await sync(a, turn: "t\(n)", "Line \(n).") }
    #expect(await bridge.current.contextNeed == .load)
  }

  /// A gap keeps the item enabled, even with no summary yet: a press need not wait for a line.
  @Test func aGapWithNoSummaryNeedsAPress() async throws {
    try await join(a, "Alpha", missed: true)
    #expect(await bridge.current.contextNeed == .load)
  }

  /// A mod that does not sync loses turns, so a summary with the line does not cover it.
  @Test func aModThatDoesNotSyncNeedsAPress() async throws {
    try await join(a, "Alpha", syncs: nil)
    #expect(await bridge.current.contextNeed == .load)
  }

  /// Review Focus 3: New conversation keeps the mark, so the next line asks for no summary of
  /// the transcript the paused text is in.
  @Test func aPauseSurvivesNewConversation() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    await test.bridge.newConversation()
    test.setPause(false)
    await test.live()
    #expect(try await test.registry.poll(test.a) == nil)
  }

  @Test func aPauseSurvivesRemovingTheSession() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    await test.bridge.remove(test.a)
    test.setPause(false)
    try await test.join(test.a, "Alpha", owner: true)  // /live on
    await test.live()
    #expect(try await test.registry.poll(test.a) == nil)
  }

  /// A mod that does not sync leaves its session out of sync for good: every line asks, as it
  /// did before sync.
  @Test func aModBeforeSyncAlwaysAsks() async throws {
    try await join(a, "Alpha", syncs: nil)
    try await post("/v1/context", context())
    await live()
    #expect(try await registry.poll(a) == .context)
    try await post("/v1/context", context())
    voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await bridge.status.call == .listening })
    await bridge.audioEvent(.speechStarted)
    #expect(try await registry.poll(a) == .context)
  }

  /// A summary the same as the stored one still means the voice is current again.
  @Test func anEqualSummaryStillClearsOutOfSync() async throws {
    try await join(a, "Alpha")
    try await post("/v1/context", context())
    try await join(a, "Alpha", missed: true)
    #expect(await bridge.current.needsContext)
    await live()
    try await post("/v1/context", context())
    #expect(await !bridge.current.needsContext)
    #expect(try saved()[a].outOfSync == nil)
    #expect(await voice.added.isEmpty)
  }

  @Test func aSummaryClearsPaused() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    #expect(try test.saved()[test.a].outOfSync == .paused)
    try await test.post("/v1/context", test.context())
    #expect(try test.saved()[test.a].outOfSync == nil)
  }

  /// A summary that comes while the line connects is added once the line is connected.
  @Test func contextThatArrivesWhileConnectingReachesTheLine() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    await voice.holdOpen()
    let opening = Task { await bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await voice.openWaiting == 1 })
    try await post("/v1/context", context())
    #expect(await voice.added.isEmpty)
    await voice.releaseOpen()
    await opening.value
    #expect(await voice.added == [summary])
  }

  /// A summary that came before the line's items were built is in them already: once connected,
  /// the line is not given it again. Here the line waits for a fresh codex to launch, so the
  /// summary lands before the items are built.
  @Test func aSeededContextIsNotAddedAgainOnceTheLineConnects() async throws {
    let voices = FakeVoices()
    let test = try BridgeTests { await voices.make() }
    await test.live()
    let first = try #require(await voices.made.first)
    first.emit(.closed(.codex(.exited(-1))))
    first.end()
    #expect(await eventually { await first.shutdowns == 1 })
    await voices.setSlow()
    let opening = Task { await test.bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await voices.waiting == 1 })
    try await test.post("/v1/context", test.context())
    await voices.finishLaunch()
    await opening.value
    let second = try #require(await voices.made.last)
    #expect(await second.opens.last?.map(\.text).contains(test.summary) == true)
    #expect(await second.added.isEmpty)
  }

  /// A summary for another session than the one the line is connecting to is not added to it.
  @Test func contextForAnotherSessionDoesNotReachAConnectingLine() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.perform(.start)
    await voice.holdOpen()
    let opening = Task { await bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await voice.openWaiting == 1 })
    try await post("/v1/context", ContextBody(sessionId: b, summary: "Beta's work."))
    await voice.releaseOpen()
    await opening.value
    #expect(await voice.added.isEmpty)
  }

  /// The same summary again is not added to the line a second time.
  @Test func anUnchangedContextIsNotAddedAgain() async throws {
    await live()
    try await post("/v1/context", context())
    try await post("/v1/context", context())
    #expect(await voice.added == [summary])
  }

  /// A summary that differs from the stored one is added.
  @Test func aChangedContextIsAdded() async throws {
    await live()
    try await post("/v1/context", context())
    try await post("/v1/context", context("Alpha's other work."))
    #expect(await voice.added == [summary, "[CONTEXT] Alpha: Alpha's other work."])
  }

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
    #expect(await eventually { await lines().count == 6 })
    let summary = "Loaded context: [CONTEXT] Alpha: Alpha's work."
    #expect(await lines() == [summary] + said.map { "You: \($0)" })
    var updates = bridge.updates.makeAsyncIterator()
    let update = await updates.next()
    #expect(update?.conversation.suffix(5).map(\.text) == said)
    #expect(update?.context == "[CONTEXT] Alpha: Alpha's work.")
    let reply = await bridge.handle(
      HTTPRequest(method: "GET", path: "/v1/next", query: ["sessionId": b.rawValue], body: Data()))
    let polled = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any]
    let status = try #require(polled?["status"] as? [String: Any])
    #expect(Set(status.keys) == ["call", "sessions", "minutesToday", "unheard", "isMuted"])
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
    voice.emit(.assistantSpeaking("Hello"))
    voice.emit(.assistantUtterance("Beta is done."))
    #expect(await eventually { await bridge.status.unheard == 0 })
    #expect(await lines() == ["Voice: Beta is done."])
    await bridge.setTarget(b)
    #expect(await lines() == ["Claude: [RESULT] Beta: Done."])
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.opens.last == [InitialItem(role: .user, text: "[RESULT] Beta: Done.")])
  }

  /// An answer under a request a newer one superseded, posted as `status`. The mod is told 200,
  /// so nothing else would say it reached nobody.
  func superseded(_ status: AnswerStatus = .ok, _ text: String = "Done.") async throws {
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    try await registry.enqueue(request(2), for: a)
    try await post(
      "/v1/answer",
      AnswerBody(sessionId: a, id: request(1).id, status: status, text: text, reason: nil))
  }

  /// Superseded, it is not said; the voice has it as context, and the conversation keeps it.
  @Test func aSupersededAnswerGoesToTheOpenLineUnsaid() async throws {
    await live()
    try await superseded()
    #expect(await lines() == ["Claude: [CLAUDE] Alpha: Done."])
    #expect(await voice.added == ["[CLAUDE] Alpha: Done."])
    #expect(await voice.spoken.isEmpty)
    #expect(await bridge.status.unheard == 0)
  }

  /// With no line open, the next line is seeded with it.
  @Test func aSupersededAnswerIsSeeded() async throws {
    try await join(a, "Alpha")
    try await superseded()
    await bridge.perform(.start)
    await bridge.audioEvent(.speechStarted)
    let seed = await voice.opens.last ?? []
    #expect(seed.contains(InitialItem(role: .user, text: "[CLAUDE] Alpha: Done.")))
  }

  /// An update under a request still in flight, with a newer one queued behind it.
  @Test func aSupersededUpdateIsKept() async throws {
    await live()
    try await superseded(.update, "The build passed.")
    #expect(await voice.added == ["[CLAUDE] Alpha: The build passed."])
  }

  /// A question ends a turn as an answer does: what it holds would reach nobody either.
  @Test func aSupersededQuestionIsKept() async throws {
    await live()
    try await superseded(.question, "Which name?")
    #expect(await lines() == ["Claude: [CLAUDE] Alpha: Which name?"])
  }

  @Test func aSupersededFailureRecordsNothing() async throws {
    await live()
    try await superseded(.failed, "the turn was interrupted")
    #expect(await lines().isEmpty)
    #expect(await voice.added.isEmpty)
  }

  @Test func aSupersededAnswerWithNoTextRecordsNothing() async throws {
    await live()
    try await superseded(.ok, "")
    #expect(await lines().isEmpty)
  }

  /// Stop with the pause on and nobody typing: its turn started before Stop, so it keeps its
  /// answer, as the decision rule says.
  @Test func aSupersededAnswerAfterStopIsKept() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.superseded()
    #expect(await test.lines() == ["Claude: [CLAUDE] Alpha: Done."])
    #expect(try test.saved()[test.a].outOfSync == nil)
  }

  /// With the pause on and the call off: a voice turn runs, and the owner types into it.
  func typedIntoAVoiceTurn() async throws {
    try await voiceTurn()
    try await sync(a, request: request(1).id, "Private thing.")
  }

  /// Alpha's request 1 in flight, and its turn started.
  func voiceTurn() async throws {
    try await join(a, "Alpha")
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    try await sync(a, request: request(1).id, kind: .start)
  }

  /// An approval in the voice turn of request 1.
  func voiceApproval(question: String? = nil, text: String? = nil) async throws {
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: question, text: text,
        turn: TurnRef(id: "turn-1", request: request(1).id)))
  }

  /// The voice turn's answer, which may repeat what was typed.
  func voiceAnswer(_ id: Int = 1, _ status: AnswerStatus = .ok) async throws {
    try await post(
      "/v1/answer",
      AnswerBody(
        sessionId: a, id: request(id).id, status: status, text: "It repeats the private thing.",
        reason: nil))
  }

  /// The answer may repeat what was typed: it reaches neither the conversation nor the next seed.
  @Test func theOwnerTypingIntoAVoiceTurnWithholdsItsAnswer() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.typedIntoAVoiceTurn()
    try await test.voiceAnswer()
    #expect(await !test.lines().contains { $0.contains("private thing") })
    #expect(try test.saved()[test.a].outOfSync == .paused)
    await test.bridge.perform(.start)
    await test.bridge.audioEvent(.speechStarted)
    let seed = await test.voice.opens.last?.map(\.text) ?? []
    #expect(!seed.contains { $0.contains("private thing") })
  }

  /// Start pressed before the answer: a plain failure goes to the line, and none of the text.
  @Test func aWithheldAnswerOnAnOpenLineIsAFailure() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.typedIntoAVoiceTurn()
    await test.live()
    try await test.voiceAnswer()
    let added = await test.voice.added
    #expect(added.count == 1)
    #expect(added.first?.hasPrefix("[FAILED] Alpha:") == true)
    #expect(!added.contains { $0.contains("private thing") })
    #expect(await test.voice.spoken.isEmpty)
  }

  /// A line waiting for that request's result is told at once, which ends its wait: only an
  /// awaited line is spoken to, and an unawaited one is added to.
  @Test func aWithheldAnswerEndsTheLinesWait() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")  // refused: the turn stays so
    await test.live()
    await test.bridge.audioEvent(.speechEnded)
    try await test.handOff()
    try await test.sync(test.a, request: test.request(1).id, "More of it.")
    try await test.voiceAnswer()
    #expect(await eventually { await test.voice.spoken.count == 1 })
    #expect(await test.voice.spoken.first?.hasPrefix("[FAILED] Alpha:") == true)
    #expect(await !test.lines().contains { $0.contains("private thing") })
  }

  /// What Claude wrote and asked in a withheld turn is the text its answer may not carry out.
  @Test func aQuestionInAWithheldTurnStaysOut() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.typedIntoAVoiceTurn()
    try await test.voiceApproval(question: "Which private thing?", text: "The private thing.")
    #expect(await test.lines().isEmpty)
    try await test.registry.enqueue(test.request(2), for: test.a)
    #expect(try await test.registry.poll(test.a) == nil)  // no question: no reply goes out
  }

  @Test func aPermissionPromptInAWithheldTurnStaysOut() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.typedIntoAVoiceTurn()
    await test.live()
    try await test.voiceApproval(text: "The private thing.")
    #expect(await test.lines().isEmpty)
    #expect(await test.voice.added.isEmpty)
    #expect(await test.voice.spoken.isEmpty)
  }

  /// Said before the owner typed: `working` must still reach the settle, which withdraws it.
  @Test func aQuestionSaidBeforeTheMarkIsStillWithdrawn() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")  // refused: the turn stays so
    await test.live()
    try await test.handOff()
    try await test.post(
      "/v1/activity", ActivityBody(sessionId: test.a, state: .approval, question: "Which name?"))
    #expect(await eventually { await test.bridge.status.unheard == 1 })
    try await test.sync(test.a, request: test.request(1).id, "More of it.")
    try await test.post("/v1/activity", ActivityBody(sessionId: test.a, state: .working))
    #expect(await eventually { await test.bridge.status.unheard == 0 })
  }

  /// A later background turn's update under the withheld request: refused, so the mod notes a gap.
  @Test func anUpdateAfterAWithheldAnswerIsRefused() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.typedIntoAVoiceTurn()
    try await test.voiceAnswer()
    let lines = await test.lines()
    let reply = try await test.post(
      "/v1/answer",
      AnswerBody(
        sessionId: test.a, id: test.request(1).id, status: .update,
        text: "It repeats the private thing.", reason: nil))
    #expect(reply.status == 409)
    #expect(await test.lines() == lines)
  }

  /// The owner types into a background turn in the follow-up window: nothing is in flight to mark.
  @Test func anUpdateFromABackgroundTurnTypedIntoIsRefused() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.answer(test.request(1), from: test.a)
    let lines = await test.lines()
    try await test.sync(
      test.a, turn: "background-turn", request: test.request(1).id, "Private thing.")
    let reply = try await test.post(
      "/v1/answer",
      AnswerBody(
        sessionId: test.a, id: test.request(1).id, status: .update,
        text: "It repeats the private thing.", reason: nil))
    #expect(reply.status == 409)
    #expect(await test.lines() == lines)
  }

  /// Under the pause a voice turn nobody typed into keeps its answer.
  @Test func aVoiceTurnNobodyTypedIntoKeepsItsAnswer() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.voiceTurn()
    try await test.voiceAnswer()
    #expect(await test.lines() == ["Claude: [RESULT] Alpha: It repeats the private thing."])
    #expect(try test.saved()[test.a].outOfSync == nil)
  }

  /// A request handed over before Stop starts its turn with the call off: nothing was typed, so
  /// the pause has nothing to mark.
  @Test func aVoiceTurnsStartUnderThePauseMarksNothing() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.voiceTurn()
    #expect(try test.saved()[test.a].outOfSync == nil)
  }

  @Test func aVoiceTurnsReportStaysUnderThePause() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.voiceTurn()
    try await test.sync(test.a, request: test.request(1).id, kind: .report, "You allowed Bash.")
    #expect(await test.lines() == ["Claude: [CLAUDE] Alpha: You allowed Bash."])
  }

  @Test func aVoiceTurnsQuestionStaysUnderThePause() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.voiceTurn()
    try await test.voiceApproval(question: "Which name?")
    #expect(await test.lines() == ["Claude: [ASKING] Alpha: Which name?"])
  }

  /// R-13: a refused turn, Start, a spoken request that waits behind that turn, one more line typed
  /// into the turn with the call on. The request is not that turn's, and the sync was not paused.
  @Test func aRequestWaitingBehindARefusedTurnIsNotWithheld() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    await test.live()
    try await test.registry.enqueue(test.request(1), for: test.a)
    _ = try await test.registry.poll(test.a)
    try await test.sync(test.a, "One more thing, typed with the call on.")
    try await test.voiceAnswer()
    #expect(await !test.voice.added.contains { $0.hasPrefix("[FAILED]") })
  }

  /// A released mod names no turn and reports only its voice turns: its question is said, as it
  /// always was, whatever the pause, and marks nothing.
  @Test func aReleasedModsQuestionIsSaidUnderThePause() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha", syncs: false)
    try await test.post(
      "/v1/activity",
      ActivityBody(sessionId: test.a, state: .approval, question: "Which name?"))
    #expect(await test.lines() == ["Claude: [ASKING] Alpha: Which name?"])
    #expect(try test.saved()[test.a].outOfSync == nil)
  }

  /// The app restarted under a voice turn, whose request it forgot, and Claude asks. The reply is
  /// the request now, and the turn's answer, which the mod moves onto it, closes it.
  @Test func aReplyAfterARestartIsClosedByItsTurnsAnswer() async throws {
    let test = try BridgeTests()
    try await test.join(test.a, "Alpha")
    try await test.registry.enqueue(test.request(1), for: test.a)
    _ = try await test.registry.poll(test.a)
    let restarted = try test.restart()
    try await restarted.join(test.a, "Alpha")
    try await restarted.post(
      "/v1/activity",
      ActivityBody(
        sessionId: test.a, state: .approval, question: "Which?",
        turn: TurnRef(id: "voice-turn", request: test.request(1).id)))
    let reply = test.request(2)
    try await restarted.registry.enqueue(reply, for: test.a)
    #expect(try await restarted.registry.poll(test.a) == .reply(reply, forRequest: reply.id))
    let answered = try await restarted.post(
      "/v1/answer",
      AnswerBody(sessionId: test.a, id: reply.id, status: .ok, text: "Done.", reason: nil))
    #expect(answered.status == 200)
    try await restarted.registry.enqueue(test.request(3), for: test.a)
    #expect(try await restarted.registry.poll(test.a) == .request(test.request(3)))
  }

  /// The same restart under a released mod: its answer goes under the forgotten request and is
  /// refused, as before this app, and the session's next request is not held behind the reply.
  @Test func aReplyAfterARestartLeavesAReleasedModsQueueFree() async throws {
    let test = try BridgeTests()
    try await test.join(test.a, "Alpha", syncs: nil)
    try await test.registry.enqueue(test.request(1), for: test.a)
    _ = try await test.registry.poll(test.a)
    let restarted = try test.restart()
    try await restarted.join(test.a, "Alpha", syncs: nil)
    try await restarted.post(
      "/v1/activity", ActivityBody(sessionId: test.a, state: .approval, question: "Which?"))
    try await restarted.registry.enqueue(test.request(2), for: test.a)
    _ = try await restarted.registry.poll(test.a)
    let answered = try await restarted.post(
      "/v1/answer",
      AnswerBody(sessionId: test.a, id: test.request(1).id, status: .ok, text: "Done.", reason: nil)
    )
    #expect(answered.status == 409)
    try await restarted.registry.enqueue(test.request(3), for: test.a)
    #expect(try await restarted.registry.poll(test.a) == .request(test.request(3)))
  }

  /// `/clear` while the line connects: the stored context moves with the session, and so does the
  /// summary held for that line.
  @Test func aHeldSummaryIsGivenAfterAClear() async throws {
    let test = try BridgeTests()
    try await test.join(test.a, "Alpha")
    await test.voice.holdOpen()
    await test.bridge.perform(.start)
    let opened = Task { await test.bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await test.voice.openWaiting == 1 })
    try await test.post("/v1/context", ContextBody(sessionId: test.a, summary: "Held summary"))
    let new = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")
    try await test.post(
      "/v1/join", JoinBody(sessionId: new, title: "Alpha", replaces: test.a, syncs: true))
    await test.voice.releaseOpen()
    await opened.value
    #expect(await eventually { await test.bridge.status.call == .live })
    #expect(await test.voice.added.contains { $0.contains("Held summary") })
  }

  /// A voice turn's question keeps today's behaviour outside the target: said, not only recorded.
  /// A typed turn's there is context (`anotherSessionsTypedQuestionIsContextOnly`).
  @Test func aVoiceTurnsQuestionInAnotherSessionIsSaid() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: b, state: .approval, question: "Which folder?",
        turn: TurnRef(id: "voice-turn", request: request(1).id)))
    #expect(await bridge.status.unheard == 1)
  }

  /// `working` settles what was said, whatever became of the turn: it takes no decision of its own,
  /// so a question the pause kept goes though the owner typed into its turn since.
  @Test func aRefusedTurnsWorkingStillWithdrawsItsQuestion() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    await test.live()
    let turn = TurnRef(id: "turn-1", request: nil)
    try await test.sync(test.a, kind: .start)
    try await test.post(
      "/v1/activity",
      ActivityBody(sessionId: test.a, state: .approval, question: "Which?", turn: turn))
    test.voice.emit(.closed(.codex(.realtimeError("You’ve hit your usage limit."))))
    #expect(await eventually { await test.bridge.status.call == .off })
    try await test.sync(test.a, "Private thing.")  // refused: the turn stays so
    #expect(await test.bridge.status.unheard == 1)
    try await test.post(
      "/v1/activity", ActivityBody(sessionId: test.a, state: .working, turn: turn))
    #expect(await test.bridge.status.unheard == 0)
  }

  /// A `start` refused under the pause says nothing of the owner's: no answer is withheld.
  @Test func aRefusedStartWithholdsNoAnswer() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.registry.enqueue(test.request(1), for: test.a)
    _ = try await test.registry.poll(test.a)
    try await test.sync(test.a, kind: .start)
    try await test.voiceAnswer()
    #expect(await test.lines() == ["Claude: [RESULT] Alpha: It repeats the private thing."])
  }

  /// Only the owner's words withhold: a line of the mod's refused with the turn says nothing typed.
  @Test func aRefusedReportWithholdsNoAnswer() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.registry.enqueue(test.request(1), for: test.a)
    _ = try await test.registry.poll(test.a)
    try await test.sync(test.a, kind: .start)  // refused, with no request named yet
    try await test.sync(
      test.a, request: test.request(1).id, kind: .report, "The turn was interrupted.")
    try await test.voiceAnswer()
    #expect(await test.lines() == ["Claude: [RESULT] Alpha: It repeats the private thing."])
  }

  @Test func aWithheldSupersededAnswerStaysOut() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.typedIntoAVoiceTurn()
    try await test.registry.enqueue(test.request(2), for: test.a)
    try await test.voiceAnswer()
    #expect(await test.lines().isEmpty)
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

  // MARK: Lines as they are spoken

  /// codex's words arrive while they are said, so the menu has them long before the final text.
  @Test func theOwnersWordsShowAsTheyArrive() async throws {
    await live()
    voice.emit(.userSpeaking(" Thanks"))
    voice.emit(.userSpeaking(". By the"))
    #expect(await eventually { await lines() == ["You: Thanks. By the"] })
  }

  @Test func theVoicesWordsShowAsTheyArrive() async throws {
    await live()
    voice.emit(.assistantSpeaking(" Thanks for"))
    voice.emit(.assistantSpeaking(" asking"))
    #expect(await eventually { await lines() == ["Voice: Thanks for asking"] })
  }

  /// The final text is what is kept, whatever the words on the way said.
  @Test func theFinalTextReplacesTheGrowingLine() async throws {
    await live()
    voice.emit(.assistantSpeaking(" Again and again"))
    #expect(await eventually { await lines() == ["Voice: Again and again"] })
    voice.emit(.assistantUtterance("Once more."))
    #expect(await eventually { await lines() == ["Voice: Once more."] })
  }

  /// The owner's next sentence starts before the last one's final text, which comes seconds
  /// after they stop: its words stay, and the rest of it joins them.
  @Test func wordsPastTheFinalTextStay() async throws {
    await live()
    voice.emit(.userSpeaking(" First."))
    voice.emit(.userSpeaking(" Second one"))
    voice.emit(.userUtterance("First."))
    #expect(await eventually { await lines() == ["You: First.", "You: Second one"] })
    voice.emit(.userSpeaking(" goes on"))
    #expect(await eventually { await lines() == ["You: First.", "You: Second one goes on"] })
  }

  /// The same for the voice's next reply.
  @Test func aRepliesWordsPastTheFinalTextStay() async throws {
    await live()
    voice.emit(.assistantSpeaking(" Done."))
    voice.emit(.assistantSpeaking(" Next"))
    voice.emit(.assistantUtterance("Done."))
    #expect(await eventually { await lines() == ["Voice: Done.", "Voice: Next"] })
  }

  /// A final text that says everything shown leaves no line behind.
  @Test func aFinalTextThatCoversTheWordsEndsTheLine() async throws {
    await live()
    voice.emit(.userSpeaking(" First. "))
    voice.emit(.userUtterance("First."))
    #expect(await eventually { await lines() == ["You: First."] })
  }

  /// The order of a recorded call: the voice starts before the owner's final text arrives, and
  /// the owner's line stays above it.
  @Test func theOwnersFinalTextStaysAboveTheVoicesGrowingLine() async throws {
    await live()
    voice.emit(.userSpeaking(" Thanks."))
    voice.emit(.assistantSpeaking(" Thanks for"))
    voice.emit(.userUtterance("Thanks."))
    #expect(await eventually { await lines() == ["You: Thanks.", "Voice: Thanks for"] })
  }

  /// codex says an empty delta can follow a final text; it must not open a line.
  @Test func anEmptyDeltaShowsNoLine() async throws {
    await live()
    voice.emit(.assistantSpeaking(""))
    voice.emit(.assistantSpeaking(" "))
    voice.emit(.userUtterance("Hello."))
    #expect(await eventually { await lines() == ["You: Hello."] })
  }

  /// A blank delta says nothing, so it cannot put the voice's answer above the owner's question.
  @Test func aBlankDeltaTakesNoPlaceInTheOrder() async throws {
    await live()
    voice.emit(.assistantSpeaking(""))
    voice.emit(.userSpeaking(" Hi"))
    voice.emit(.assistantSpeaking(" Hello"))
    #expect(await eventually { await lines() == ["You: Hi", "Voice: Hello"] })
  }

  @Test func aGrowingLineIsNotStored() async throws {
    await live()
    voice.emit(.userSpeaking("Remember"))
    #expect(await eventually { await lines() == ["You: Remember"] })
    let restarted = try restart()
    try await restarted.join(a, "Alpha")
    #expect(await restarted.lines().isEmpty)
  }

  /// A line that closes before its final text leaves nothing: not in the menu, not in the seed.
  @Test func aGrowingLineDoesNotSeedTheNextLine() async throws {
    await live()
    voice.emit(.userSpeaking("Remember"))
    #expect(await eventually { await lines() == ["You: Remember"] })
    await bridge.perform(.stop)
    #expect(await lines().isEmpty)
    await live()
    #expect(await voice.opens.last == [])
    #expect(await lines().isEmpty)
  }

  @Test func theLineClosingByItselfEndsAGrowingLine() async throws {
    await live()
    voice.emit(.assistantSpeaking("Option A"))
    #expect(await eventually { await lines() == ["Voice: Option A"] })
    voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await lines().isEmpty })
  }

  /// A new line starts from nothing, even when the last one's words never got a final text.
  @Test func wordsOfAClosedLineDoNotJoinTheNextOnes() async throws {
    await live()
    voice.emit(.assistantSpeaking("Option A"))
    #expect(await eventually { await lines() == ["Voice: Option A"] })
    voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await bridge.status.call == .listening })
    await bridge.audioEvent(.speechStarted)
    voice.emit(.assistantSpeaking("Option B"))
    #expect(await eventually { await lines() == ["Voice: Option B"] })
  }

  /// The owner's words trail their voice, so they say nothing about whether the owner still
  /// speaks: the line hangs up when it would have without them.
  @Test func theOwnersWordsDoNotMoveTheSilenceHangUp() async throws {
    await live()
    await bridge.audioEvent(.speechEnded)
    #expect(await eventually { time.sleepers >= 3 })  // sweep, 2 silence timers
    for _ in 1..<CallMachine.silenceSeconds {
      time.advance(by: .seconds(1))
      _ = try await registry.poll(a)  // the session stays joined
    }
    voice.emit(.userSpeaking(" Trailing"))
    #expect(await eventually { await lines() == ["You: Trailing"] })
    time.advance(by: .seconds(1))
    #expect(await eventually { await bridge.status.call == .listening })
  }

  /// Nor do they make a result wait, as the owner speaking or the voice speaking does.
  @Test func aResultIsSaidAmongTheOwnersWords() async throws {
    await live()
    await bridge.audioEvent(.speechEnded)
    try await handOff()
    voice.emit(.userSpeaking(" Trailing"))
    #expect(await eventually { await lines().last == "You: Trailing" })
    try await answerFirstRequest()
    #expect(await eventually { await voice.spoken == ["[RESULT] Alpha: Done."] })
  }

  /// A line opened for a question closes without any call event when the question is settled.
  @Test func aLineClosedByAWithdrawnQuestionEndsAGrowingLine() async throws {
    await live()
    voice.emit(.userUtterance("Hi"))
    #expect(await eventually { await lines() == ["You: Hi"] })
    voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await bridge.status.call == .listening })
    await voice.holdOpen()
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which?", turn: TurnRef(id: "turn-2")))
    #expect(await eventually { await voice.openWaiting == 1 })
    voice.emit(.assistantSpeaking(" Late"))
    #expect(await eventually { await lines().last == "Voice: Late" })
    try await post(
      "/v1/activity", ActivityBody(sessionId: a, state: .working, turn: TurnRef(id: "turn-2")))
    #expect(await eventually { await bridge.status.call == .listening })
    #expect(await !lines().contains("Voice: Late"))
  }

  /// The menu shows the target's conversation: a growing line of another session is not in it.
  @Test func aGrowingLineShowsOnlyForItsSession() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    voice.emit(.userSpeaking("Remember"))
    #expect(await eventually { await lines() == ["You: Remember"] })
    await bridge.setTarget(b)
    #expect(await lines().isEmpty)
  }

  /// `/clear` gives the session a new id during the line; its words go with it.
  @Test func aGrowingLineFollowsTheSessionsNewID() async throws {
    await live()
    voice.emit(.userSpeaking("Remember"))
    #expect(await eventually { await lines() == ["You: Remember"] })
    let cleared = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")
    try await post("/v1/join", JoinBody(sessionId: cleared, title: "Alpha", replaces: a))
    #expect(await lines() == ["You: Remember"])
  }

  /// A word still on its way when the line closes would never get its final text.
  @Test func wordsAfterTheLineClosedShowNoLine() async throws {
    await live()
    voice.emit(.closed(.other("The voice session closed (example).")))
    #expect(await eventually { await bridge.status.call == .listening })
    voice.emit(.userSpeaking("Late"))
    voice.end()  // the events end after that word, so it has been taken once codex is shut down
    #expect(await eventually { await voice.shutdowns == 1 })
    #expect(await lines().isEmpty)
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

  // MARK: Synced lines

  /// With the call off, a typed line is kept for the next line and reaches nobody.
  @Test func aTypedLineGoesIntoItsSessionsConversation() async throws {
    try await join(a, "Alpha")
    try await sync(a, "Fix the build.")
    #expect(await lines() == ["You: [TYPED] Alpha: Fix the build."])
    #expect(await voice.added.isEmpty)
    #expect(await voice.opens.isEmpty)
  }

  /// An admitted line is saved with the conversation: a restarted app still has it.
  @Test func aSyncedLineSurvivesARestart() async throws {
    try await join(a, "Alpha")
    try await sync(a, "Fix the build.")
    try await sync(a, kind: .answer, "The build is fixed.")
    let restarted = try restart()
    try await restarted.join(restarted.a, "Alpha")
    #expect(
      await restarted.lines() == [
        "You: [TYPED] Alpha: Fix the build.", "Claude: [CLAUDE] Alpha: The build is fixed.",
      ])
  }

  @Test func anOtherSessionsLineStaysInItsOwnConversation() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await sync(b, "Fix Beta's build.")
    #expect(await lines().isEmpty)
    await bridge.setTarget(b)
    #expect(await lines() == ["You: [TYPED] Beta: Fix Beta's build."])
  }

  /// A line on Alpha: what is typed in Beta is kept in Beta's conversation and goes nowhere.
  @Test func anOtherSessionsLineStaysOffTheOpenLine() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    try await sync(b, "Fix Beta's build.")
    #expect(await voice.added.isEmpty)
  }

  /// `/clear` while the line connects: the session has a new id, and the seed is still its
  /// conversation.
  @Test func aClearWhileTheLineConnectsKeepsTheSeed() async throws {
    try await join(a, "Alpha")
    try await sync(a, "Fix the build.")
    await bridge.perform(.start)
    await audio.holdOffer()
    let opening = Task { await bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await audio.offerWaiting == 1 })
    let cleared = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")
    try await post("/v1/join", JoinBody(sessionId: cleared, title: "Alpha", replaces: a))
    await audio.releaseOffer()
    await opening.value
    #expect(await voice.opens.last?.map(\.text) == ["[TYPED] Alpha: Fix the build."])
  }

  /// Claude's line is a seed item although its speaker is `.claude`, as an unheard result's is not.
  @Test func aSyncedLineIsSeededToTheNextLine() async throws {
    try await join(a, "Alpha")
    try await sync(a, "Fix the build.")
    try await sync(a, kind: .answer, "The build is fixed.")
    await live()
    let items = try #require(await voice.opens.last)
    #expect(
      items == [
        InitialItem(role: .user, text: "[TYPED] Alpha: Fix the build."),
        InitialItem(role: .user, text: "[CLAUDE] Alpha: The build is fixed."),
      ])
  }

  @Test func aLiveLineGetsASyncedLineAtOnce() async throws {
    await live()
    try await sync(a, "Fix the build.")
    #expect(await voice.added == ["[TYPED] Alpha: Fix the build."])
    #expect(await voice.spoken.isEmpty)
  }

  /// A line that lands while the line launches is in the seed and not added again. Mutation:
  /// move `dropSynced()` to `.connected`.
  @Test func aLineBeforeTheSeedIsSeededOnly() async throws {
    let voices = FakeVoices()
    let test = try BridgeTests { await voices.make() }
    await test.live()
    let first = try #require(await voices.made.first)
    first.emit(.closed(.codex(.exited(-1))))
    first.end()
    #expect(await eventually { await first.shutdowns == 1 })
    await voices.setSlow()
    let opening = Task { await test.bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await voices.waiting == 1 })
    try await test.sync(test.a, "Fix the build.")
    await voices.finishLaunch()
    await opening.value
    let second = try #require(await voices.made.last)
    #expect(await second.opens.last?.map(\.text) == ["[TYPED] Alpha: Fix the build."])
    #expect(await second.added.isEmpty)
  }

  /// A line that lands once the seed is built waits for the connect and is added, not seeded.
  @Test func aLineAfterTheSeedIsAddedOnly() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    await voice.holdOpen()
    let opening = Task { await bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await voice.openWaiting == 1 })
    try await sync(a, "Fix the build.")
    await voice.releaseOpen()
    await opening.value
    #expect(await voice.added == ["[TYPED] Alpha: Fix the build."])
    #expect(await voice.opens.last?.isEmpty == true)
  }

  @Test func aSyncedLineIsRedactedClippedAndCodeFree() async throws {
    await live()
    try await sync(a, "My password: hunter2\n```\nlet secret = 1\n```\nthanks")
    try await sync(
      a, kind: .answer,
      "Done. key sk-abcdefghijklmnopqrst\n```\nlet code = 1\n```\n| a | b |\n"
        + String(repeating: "More detail here. ", count: 300))
    try await sync(a, kind: .answer, "```\nlet only = 1\n```")
    let added = await voice.added
    #expect(added.count == 3)
    for line in added {
      #expect(line.count <= AnswerShaper.maxCharacters && !line.contains("\n"))
      #expect(!line.contains("hunter2") && !line.contains("abcdefghij"))
      #expect(!line.contains("let ") && !line.contains("| a |"))
    }
    #expect(added[0].hasPrefix("[TYPED] Alpha: "))
    #expect(added[1].hasPrefix("[CLAUDE] Alpha: Done."))
    #expect(added[2].contains("code or a table only"))
  }

  // The pause: the setting on and the call off

  @Test func aPausedTurnIsDroppedWhileTheCallIsOff() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    #expect(await test.lines().isEmpty)
    #expect(try test.saved()[test.a].outOfSync == .paused)
    #expect(try test.saved()[test.a].lines.isEmpty)
  }

  @Test func aPausedTurnsAnswerStaysOutAfterStart() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    await test.bridge.perform(.start)
    try await test.sync(test.a, kind: .answer, "I did the private thing.")
    #expect(await test.lines().isEmpty)
  }

  /// R-12: the owner's post failed, so the join says the session missed a turn, under the pause.
  /// The turn's answer, which may repeat what was typed, stays off the line opened after Start.
  @Test func anAnswerOfATurnTheAppNeverSawStaysOutOfAPausedSession() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha", missed: true)
    await test.live()
    try await test.sync(test.a, kind: .answer, "It repeats the private thing.")
    #expect(await !test.voice.added.contains { $0.contains("private thing") })
    #expect(await test.lines().isEmpty)
  }

  /// The app restarts after the refused turn: its decision was saved, so its answer stays out.
  @Test func aPausedTurnsAnswerStaysOutAfterARestart() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    let restarted = try BridgeTests(dir: test.dir, time: test.time, pausesSync: true)
    try await restarted.join(restarted.a, "Alpha")
    await restarted.bridge.perform(.start)
    try await restarted.sync(restarted.a, kind: .answer, "I did the private thing.")
    #expect(await restarted.lines().isEmpty)
  }

  @Test func aTurnFromBeforeStopKeepsItsAnswerInThePause() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    await test.bridge.perform(.start)
    try await test.sync(test.a, "Fix the build.")
    await test.bridge.perform(.stop)
    try await test.sync(test.a, kind: .answer, "The build is fixed.")
    #expect(
      await test.lines() == [
        "You: [TYPED] Alpha: Fix the build.", "Claude: [CLAUDE] Alpha: The build is fixed.",
      ])
    #expect(try test.saved()[test.a].outOfSync == nil)
  }

  /// Review Focus 2: Stop, then type into the turn that started synced: that text and the
  /// answer, which may repeat it, stay out.
  @Test func theOwnerTypingAfterStopIsDropped() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    await test.bridge.perform(.start)
    try await test.sync(test.a, "Fix the build.")
    await test.bridge.perform(.stop)
    try await test.sync(test.a, "Also, the private thing.")
    try await test.sync(test.a, kind: .answer, "Both are done.")
    #expect(await test.lines() == ["You: [TYPED] Alpha: Fix the build."])
    #expect(try test.saved()[test.a].outOfSync == .paused)
  }

  /// A turn's `start` takes the decision; under the pause it is refused, and the turn's answer
  /// stays out after Start.
  @Test func aStartTakesTheDecisionAndRecordsNothing() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, kind: .start)
    #expect(try test.saved()[test.a].outOfSync == .paused)
    await test.bridge.perform(.start)
    try await test.sync(test.a, kind: .answer, "An answer.")
    #expect(await test.lines().isEmpty)
  }

  @Test func aStartWithoutThePauseAdmitsItsTurn() async throws {
    try await join(a, "Alpha")
    try await sync(a, kind: .start)
    #expect(await lines().isEmpty)
    try await sync(a, kind: .answer, "An answer.")
    #expect(await lines() == ["Claude: [CLAUDE] Alpha: An answer."])
    #expect(try saved()[a].outOfSync == nil)
  }

  @Test func aJoinThatMissedMarksTheSession() async throws {
    try await join(a, "Alpha", missed: true)
    let restarted = try restart()
    #expect(try restarted.saved()[a].outOfSync == .missed)
  }

  @Test func aJoinThatMissedUnderThePauseIsPaused() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha", missed: true)
    #expect(try test.saved()[test.a].outOfSync == .paused)
  }

  @Test func aRemovedSessionsLineIsRefused() async throws {
    try await join(a, "Alpha")
    await bridge.remove(a)
    #expect(try await sync(a, "Fix the build.").status == 404)
    #expect(try saved()[a].lines.isEmpty)
  }

  // MARK: Questions and approvals from typed turns

  /// R-18: a subagent's prompt carries the turn it ran in. Outside the target, in a typed turn,
  /// it is context only.
  @Test func aBareApprovalInATypedTurnOutsideTheTargetDoesNotChime() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    try await post(
      "/v1/activity", ActivityBody(sessionId: b, state: .approval, turn: TurnRef(id: "turn-1")))
    #expect(await bridge.status.unheard == 0)
    #expect(await !audio.calls.contains("chime"))
  }

  /// R-18: in a refused turn its notice is not recorded.
  @Test func aBareApprovalInARefusedTurnIsNotRecorded() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    try await test.post(
      "/v1/activity",
      ActivityBody(sessionId: test.a, state: .approval, turn: TurnRef(id: "turn-1")))
    #expect(try test.saved()[test.a].lines.isEmpty)
  }

  /// Claude's question in a turn the owner typed, on the target after an owner line, is said and
  /// opens the closed line.
  @Test func aTypedTurnsQuestionOpensTheTargetsLine() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    try await sync(a, "Rename the folder.")
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    #expect(await eventually { await voice.opens.count == 1 })
    #expect(
      await voice.opens.last?.map(\.text).contains("[TYPED] Alpha: Rename the folder.") == true)
  }

  /// The last line's session stays behind when that line closes; the first question from another
  /// target still opens the line, with that target's conversation. Whether the opening line is
  /// taken for the old one hangs on how two tasks interleave, so this repeats: without the fix
  /// more than half the rounds fail. Mutation: clear `lineKnowsSession` in `openLine`.
  @Test func aQuestionOpensAClosedLineAfterAnotherSessionsLine() async throws {
    for _ in 0..<32 {
      let test = try BridgeTests()
      try await test.join(test.a, "Alpha")
      try await test.join(test.b, "Beta")
      await test.live()
      test.voice.emit(.closed(.other("closed")))
      #expect(await eventually { await test.bridge.status.call == .listening })
      try await test.post("/v1/target", TargetBody(sessionId: test.b))
      try await test.sync(test.b, "Rename the folder.")
      try await test.post(
        "/v1/activity",
        ActivityBody(
          sessionId: test.b, state: .approval, question: "Which name?",
          turn: TurnRef(id: "turn-1")))
      try #require(await eventually { await test.voice.opens.count == 2 })
      try #require(await eventually { await test.bridge.status.call == .live })
      #expect(
        await test.voice.opens.last?.map(\.text).contains("[TYPED] Beta: Rename the folder.")
          == true)
    }
  }

  @Test func aTypedTurnsApprovalOpensTheTargetsLine() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    try await sync(a, "Delete the build folder.")
    try await post(
      "/v1/activity",
      ActivityBody(sessionId: a, state: .approval, turn: TurnRef(id: "turn-1")))
    #expect(await eventually { await voice.opens.count == 1 })
  }

  /// A typed turn's question in a session that is not the target is context: no chime, nothing
  /// unheard, no route for the next handoff, no line opened.
  @Test func anotherSessionsTypedQuestionIsContextOnly() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.perform(.start)
    try await sync(b, "Rename the folder.")
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: b, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    #expect(await bridge.status.unheard == 0)
    #expect(await !audio.calls.contains("chime"))
    #expect(await bridge.status.call == .listening)
    #expect(await voice.opens.isEmpty)
    await bridge.audioEvent(.speechStarted)  // the line opens with Alpha, the target
    voice.emit(.handoff(request(1)))
    #expect(try await eventually { try await registry.poll(a) == .request(request(1)) })
    #expect(try await registry.poll(b) == nil)
    await bridge.setTarget(b)
    #expect(
      await lines() == [
        "You: [TYPED] Beta: Rename the folder.", "Claude: [ASKING] Beta: Which name?",
      ])
  }

  /// A question still open when its session becomes the target is in the seed, and the next
  /// handoff is its reply.
  @Test func aQuestionStillOpenAtASwitchIsAnswerable() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.perform(.start)
    try await sync(b, "Rename the folder.")
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: b, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    await bridge.setTarget(b)
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.opens.last?.map(\.text).contains("[ASKING] Beta: Which name?") == true)
    voice.emit(.handoff(request(1)))
    let reply = Work.reply(request(1), forRequest: request(1).id)
    #expect(try await eventually { try await registry.poll(b) == reply })
  }

  /// A voice turn's question in another session is delivered as before.
  @Test func anotherSessionsVoiceTurnQuestionChimesAsBefore() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.perform(.start)
    try await post("/v1/activity", ActivityBody(sessionId: b, state: .approval, question: "Which?"))
    #expect(await bridge.status.unheard == 1)
    #expect(await audio.calls.contains("chime"))
  }

  /// A turn the pause refused leaves no trace: its question is not recorded, and the registry
  /// is not asking.
  @Test func aRefusedTurnsQuestionGoesNowhere() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.sync(test.a, "Private thing.")
    try await test.post(
      "/v1/activity",
      ActivityBody(
        sessionId: test.a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    #expect(await test.lines().isEmpty)
    #expect(await test.bridge.status.unheard == 0)
    try await test.registry.enqueue(test.request(1), for: test.a)
    #expect(try await test.registry.poll(test.a) == .request(test.request(1)))
  }

  /// Another prompt already has the session waiting; a refused turn's question after it must
  /// still not make the session ask.
  @Test func aRefusedTurnIsCheckedWhilePausedOnAnotherPrompt() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.post("/v1/activity", ActivityBody(sessionId: test.a, state: .approval))
    try await test.sync(test.a, "Private thing.")
    try await test.post(
      "/v1/activity",
      ActivityBody(
        sessionId: test.a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    try await test.registry.enqueue(test.request(1), for: test.a)
    #expect(try await test.registry.poll(test.a) == .request(test.request(1)))
    // only the subagent's prompt is kept, not the refused turn's question
    #expect(
      await test.lines() == ["Claude: [APPROVAL] Alpha: Claude is waiting for your approval"])
  }

  /// The owner answers a typed turn's question by voice: the mod answers the reply under its
  /// own id, and the answer is delivered and spoken.
  @Test func aSpokenReplyToATypedQuestionIsAwaited() async throws {
    await live()
    await bridge.audioEvent(.speechEnded)
    try await sync(a, "Rename the folder.")
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    voice.emit(.handoff(request(1)))
    let reply = Work.reply(request(1), forRequest: request(1).id)
    #expect(try await eventually { try await registry.poll(a) == reply })
    let answered = try await post(
      "/v1/answer",
      AnswerBody(sessionId: a, id: request(1).id, status: .ok, text: "Renamed.", reason: nil))
    #expect(answered.status == 200)
    #expect(await eventually { await voice.spoken.last == "[RESULT] Alpha: Renamed." })
  }

  // MARK: Synced lines in a call paused at the plan's limit

  /// The line closes at the plan's usage limit: the call is off, and keeps what arrives.
  func pausedAtTheLimit() async {
    voice.emit(.closed(.codex(.realtimeError("You’ve hit your usage limit."))))
    #expect(await eventually { await bridge.status.call == .off })
  }

  /// How many items of the latest seed carry `text`.
  func seeded(_ text: String) async -> Int {
    (await voice.opens.last ?? []).filter { $0.text.contains(text) }.count
  }

  /// A paused call keeps what the voice has to say. A synced line is context: the conversation
  /// keeps it, with no chime, and the next line gets it once, as seed.
  @Test func aTypedLineDuringAPausedCallIsSeededOnce() async throws {
    await live()
    await pausedAtTheLimit()
    let chimes = await audio.calls.filter { $0 == "chime" }.count
    try await sync(a, "Rename the folder.")
    #expect(await bridge.status.unheard == 0)
    #expect(await audio.calls.filter { $0 == "chime" }.count == chimes)
    #expect(await bridge.status.problem != nil)
    await live()
    #expect(await seeded("[TYPED] Alpha: Rename the folder.") == 1)
    #expect(await !voice.added.contains { $0.contains("Rename the folder.") })
  }

  /// The line was cut after its seed: a line that came in between reaches the next line once.
  @Test func aSyncedLineOnALineCutByARefusalIsSeededOnce() async throws {
    try await join(a, "Alpha")
    await bridge.perform(.start)
    await voice.holdOpen()
    let opening = Task { await bridge.audioEvent(.speechStarted) }
    #expect(await eventually { await voice.openWaiting == 1 })
    try await sync(a, "Rename the folder.")
    await bridge.audioEvent(.lineError(code: "usage_check_failed", message: "No."))
    await voice.releaseOpen()
    await opening.value
    #expect(await bridge.status.call == .off)
    await live()
    #expect(await seeded("[TYPED] Alpha: Rename the folder.") == 1)
    #expect(await !voice.added.contains { $0.contains("Rename the folder.") })
  }

  /// A result is kept to be said as well as in the conversation: it is not seeded too.
  @Test func aResultDuringAPausedCallIsGivenOnce() async throws {
    await live()
    await pausedAtTheLimit()
    try await answer(request(1), from: a)
    #expect(await bridge.status.unheard == 1)
    await live()
    #expect(await seeded("[RESULT] Alpha: Done.") == 0)
    #expect(await voice.added.filter { $0 == "[RESULT] Alpha: Done." }.count == 1)
  }

  @Test func aSupersededAnswerDuringAPausedCallIsSeededUnsaid() async throws {
    await live()
    await pausedAtTheLimit()
    try await superseded()
    #expect(await bridge.status.unheard == 0)
    await live()
    #expect(await seeded("[CLAUDE] Alpha: Done.") == 1)
    #expect(await !voice.added.contains("[CLAUDE] Alpha: Done."))
  }

  /// A typed turn's question in the target is said, so a paused call keeps it for the next line.
  @Test func aTypedQuestionDuringAPausedCallWaitsForTheNextLine() async throws {
    await live()
    await pausedAtTheLimit()
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    #expect(await bridge.status.unheard == 1)
    await live()
    #expect(await seeded("Which name?") == 0)
    #expect(await voice.added.filter { $0.hasPrefix("[ASKING] Alpha:") }.count == 1)
  }

  @Test func aTypedQuestionSettledDuringAPausedCallIsNotSaid() async throws {
    await live()
    await pausedAtTheLimit()
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    #expect(await bridge.status.unheard == 1)
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .working))
    #expect(await bridge.status.unheard == 0)
  }

  /// A change of target, by the menu or by the band, takes Alpha's waiting question off the queue
  /// and ends its route: it is not said on Beta's line, and the owner's next words are Beta's.
  @Test(arguments: [true, false])
  func aTargetChangeTakesAWaitingQuestionOffTheQueue(byTheMenu: Bool) async throws {
    let test = try BridgeTests()
    try await test.join(a, "Alpha")
    try await test.join(b, "Beta")
    await test.live()
    await test.pausedAtTheLimit()
    try await test.post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    if byTheMenu {
      await test.bridge.setTarget(b)
    } else {
      try await test.post("/v1/target", TargetBody(sessionId: b))
    }
    #expect(await test.bridge.status.unheard == 0)
    await test.live()
    #expect(await test.voice.added.isEmpty)
    _ = try await test.registry.poll(a)  // the first line's ask for a summary
    test.voice.emit(.handoff(request(2)))
    #expect(try await eventually { try await test.registry.poll(b) == .request(request(2)) })
    #expect(try await test.registry.poll(a) == nil)
  }

  /// A question a change of target took off the queue stays recorded: Alpha's next line has it.
  @Test func aQuestionTakenOffTheQueueIsInItsSessionsSeed() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    await pausedAtTheLimit()
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    await bridge.setTarget(b)
    await bridge.setTarget(a)
    await live()
    let seed = await voice.opens.last?.map(\.text) ?? []
    #expect(seed.contains("[ASKING] Alpha: Which name?"))
  }

  /// The menu's choice of another target with the line live: the owner's next words are Beta's.
  @Test func aTargetChangeOnALiveLineEndsTheRoute() async throws {
    let voices = FakeVoices()
    let test = try BridgeTests { await voices.make() }
    try await test.join(a, "Alpha")
    try await test.join(b, "Beta")
    await test.live()
    try await test.sync(a, "Rename it.")
    try await test.post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    await test.bridge.setTarget(b)
    #expect(await eventually { await test.bridge.status.call == .listening })
    await test.bridge.audioEvent(.speechStarted)
    #expect(await eventually { await test.bridge.status.call == .live })
    await voices.made.last?.emit(.handoff(request(2)))
    #expect(try await eventually { try await test.registry.poll(b) == .request(request(2)) })
  }

  /// `/live target`, and the band's Talk here: a question the voice has said routes nothing once
  /// the owner chose another session.
  @Test func aPostedTargetEndsTheRouteOfAQuestionAlreadySaid() async throws {
    let voices = FakeVoices()
    let test = try BridgeTests { await voices.make() }
    try await test.join(a, "Alpha")
    try await test.join(b, "Beta")
    await test.live()
    try await test.answer(request(1), from: a, .question, "Deploy which branch?")
    await voices.made.last?.emit(.assistantSpeaking("Hello"))
    await voices.made.last?.emit(.assistantUtterance("Alpha asks: deploy which branch?"))
    #expect(await eventually { await test.bridge.status.unheard == 0 })
    try await test.post("/v1/target", TargetBody(sessionId: b))
    #expect(await eventually { await test.bridge.status.call == .listening })
    await test.bridge.audioEvent(.speechStarted)
    #expect(await eventually { await test.bridge.status.call == .live })
    await voices.made.last?.emit(.handoff(request(2)))
    #expect(try await eventually { try await test.registry.poll(b) == .request(request(2)) })
  }

  /// The band's Start posts a target: of the same session it changes nothing, so a pause at the
  /// limit keeps its question and that question's route.
  @Test func aPostOfTheSameTargetKeepsAWaitingQuestion() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    await pausedAtTheLimit()
    try await post("/v1/activity", ActivityBody(sessionId: b, state: .approval, question: "Which?"))
    try await post("/v1/target", TargetBody(sessionId: a))
    await live()
    #expect(await voice.added == ["[ASKING] Beta: Which?"])
    voice.emit(.handoff(request(2)))
    let reply = Work.reply(request(2), forRequest: request(2).id)
    #expect(try await eventually { try await registry.poll(b) == reply })
  }

  /// A waiting question whose own session becomes the target is that session's to say: it stays on
  /// the queue, and the reply reaches it.
  @Test func aQuestionOfTheNewTargetStaysOnTheQueue() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    await pausedAtTheLimit()
    try await post("/v1/activity", ActivityBody(sessionId: b, state: .approval, question: "Which?"))
    await bridge.setTarget(b)
    await live()
    #expect(await voice.added == ["[ASKING] Beta: Which?"])
    voice.emit(.handoff(request(2)))
    let reply = Work.reply(request(2), forRequest: request(2).id)
    #expect(try await eventually { try await registry.poll(b) == reply })
  }

  /// A session that left can take no reply: its waiting question goes, and is not said on the
  /// next line, where the reply would land in the target as a request.
  @Test func aSessionThatLeftTakesItsQuestionOffTheQueue() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.perform(.start)
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: a, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    #expect(await bridge.status.unheard == 1)
    try await post("/v1/leave", LeaveBody(sessionId: a))
    #expect(await bridge.status.unheard == 0)
    await bridge.audioEvent(.speechStarted)
    #expect(await voice.added.isEmpty)
  }

  /// A session that left and came back asks nothing any more, so the next handoff is the target's.
  @Test func aSessionThatLeftEndsItsRoute() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    try await answer(request(1), from: b, .question, "Which branch?")
    try await post("/v1/leave", LeaveBody(sessionId: b))
    try await join(b, "Beta")
    voice.emit(.handoff(request(2)))
    #expect(try await eventually { try await registry.poll(a) == .request(request(2)) })
  }

  /// Beta's question took the route from Alpha's. Once Beta's closes, the route is Alpha's again:
  /// its question is still open, and the reply must not land in Beta as a request.
  @Test func aQuestionThatClosesGivesTheRouteBack() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await bridge.setTarget(b)
    await live()
    try await registry.enqueue(request(1), for: a)
    #expect(try await registry.poll(a) == .request(request(1)))
    try await post("/v1/activity", ActivityBody(sessionId: a, state: .approval, question: "Which?"))
    try await sync(b, "Rename it.")
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: b, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    try await post("/v1/activity", ActivityBody(sessionId: b, state: .working))
    voice.emit(.handoff(request(2)))
    let reply = Work.reply(request(2), forRequest: request(1).id)
    #expect(try await eventually { try await registry.poll(a) == reply })
  }

  /// In another session a typed turn's question is only recorded, whatever the call is doing.
  @Test func aTypedQuestionInAnotherSessionDuringAPausedCallIsOnlyRecorded() async throws {
    try await join(a, "Alpha")
    try await join(b, "Beta")
    await live()
    await pausedAtTheLimit()
    try await post(
      "/v1/activity",
      ActivityBody(
        sessionId: b, state: .approval, question: "Which name?", turn: TurnRef(id: "turn-1")))
    #expect(await bridge.status.unheard == 0)
    #expect(try saved()[b].lines.contains { $0.text.hasPrefix("[ASKING] Beta:") })
    await live()
    voice.emit(.handoff(request(2)))
    #expect(try await eventually { try await registry.poll(a) == .request(request(2)) })
    #expect(try await registry.poll(b) == nil)
  }

  /// A paused call is a stopped call to the pause setting: the microphone is released, and the
  /// owner who keeps the setting on must not have what is typed now recorded.
  @Test func thePauseSettingTreatsAPausedCallAsStopped() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    await test.live()
    await test.pausedAtTheLimit()
    try await test.sync(test.a, "Private thing.")
    #expect(await test.lines().isEmpty)
    #expect(try test.saved()[test.a].outOfSync == .paused)
    await test.live()
    #expect(await test.seeded("Private thing.") == 0)
  }

  /// A turn admitted while the line was live is admitted still: the limit did not stop it.
  @Test func aTurnTypedBeforeTheLimitKeepsItsAnswerUnderThePauseSetting() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    await test.live()
    try await test.sync(test.a, "Rename the folder.")
    await test.pausedAtTheLimit()
    try await test.sync(test.a, kind: .answer, "Renamed.")
    #expect(await test.lines().contains("Claude: [CLAUDE] Alpha: Renamed."))
  }

  /// A paused call keeps the plain failure a withheld answer closes with, and none of its text.
  @Test func aWithheldAnswerDuringAPausedCallWaitsAsAPlainFailure() async throws {
    let test = try BridgeTests(pausesSync: true)
    try await test.join(test.a, "Alpha")
    try await test.registry.enqueue(test.request(1), for: test.a)
    _ = try await test.registry.poll(test.a)
    await test.live()
    await test.pausedAtTheLimit()
    try await test.sync(test.a, request: test.request(1).id, "Private thing.")
    try await test.voiceAnswer()
    #expect(await !test.lines().contains { $0.contains("private thing") })
    await test.live()
    #expect(await test.seeded("private thing") == 0)
    let added = await test.voice.added
    #expect(added.count == 1)
    #expect(added.first?.hasPrefix("[FAILED] Alpha:") == true)
    #expect(!added.contains { $0.contains("private thing") })
  }

  // MARK: Claude's usage limits

  static let reset = "2026-01-01T06:00:00Z"
  static let resetDate = Date(timeIntervalSince1970: 1_767_247_200)

  @discardableResult
  func limits(_ windows: [LimitWindowBody], from id: SessionID? = nil) async throws
    -> HTTPResponse
  {
    try await post("/v1/limits", LimitsBody(sessionId: id ?? a, windows: windows))
  }

  @Test func aReadingReachesTheUpdate() async throws {
    try await join(a, "Alpha")
    #expect(await bridge.current.claudeLimits == nil)
    try await limits([
      LimitWindowBody(kind: "five_hour", percentUsed: 23.5, resetsAt: Self.reset),
      LimitWindowBody(kind: "seven_day", percentUsed: 7, resetsAt: nil),
    ])
    let reading = try #require(await bridge.current.claudeLimits)
    #expect(
      reading.windows == [
        LimitWindow(span: .minutes(300), usedPercent: 23.5, resetsAt: Self.resetDate),
        LimitWindow(span: .minutes(10080), usedPercent: 7, resetsAt: nil),
      ])
    #expect(reading.readAt == time.now)
  }

  @Test func anUnknownKindShowsByName() async throws {
    try await join(a, "Alpha")
    try await limits([LimitWindowBody(kind: "thirty_day", percentUsed: 90, resetsAt: nil)])
    let reading = try #require(await bridge.current.claudeLimits)
    #expect(reading.windows.map(\.span) == [.kind("thirty_day")])
    #expect(reading.windows.first?.span.label == "thirty day")
  }

  @Test func spendLimitStaysOut() async throws {
    try await join(a, "Alpha")
    try await limits([LimitWindowBody(kind: "spend_limit", percentUsed: 90, resetsAt: nil)])
    #expect(await bridge.current.claudeLimits == nil)
  }

  @Test func aKindOutsideTheAlphabetIsIgnored() async throws {
    try await join(a, "Alpha")
    for kind in ["Five", "a-b", String(repeating: "a", count: 33), "", "_", "___"] {
      try await limits([LimitWindowBody(kind: kind, percentUsed: 90, resetsAt: nil)])
    }
    #expect(await bridge.current.claudeLimits == nil)
    try await limits([
      LimitWindowBody(kind: String(repeating: "a", count: 32), percentUsed: 1, resetsAt: nil)
    ])
    #expect(await bridge.current.claudeLimits?.windows.count == 1)
  }

  @Test func aReadingHoldsAtMostThreeWindows() async throws {
    try await join(a, "Alpha")
    try await limits(
      ["a", "b", "c", "five_hour", "seven_day"].map {
        LimitWindowBody(kind: $0, percentUsed: 5, resetsAt: nil)
      })
    let spans = try #require(await bridge.current.claudeLimits).windows.map(\.span)
    #expect(spans == [.minutes(300), .minutes(10080), .kind("a")])
  }

  @Test func anIdleSessionDoesNotLowerTheFigures() async throws {
    try await join(a, "Alpha")
    try await limits([LimitWindowBody(kind: "five_hour", percentUsed: 40, resetsAt: Self.reset)])
    try await limits([LimitWindowBody(kind: "five_hour", percentUsed: 12, resetsAt: Self.reset)])
    #expect(await bridge.current.claudeLimits?.windows.first?.usedPercent == 40)
  }

  @Test func anExpiredWindowDoesNotTakeASlot() async throws {
    try await join(a, "Alpha")
    try await limits([LimitWindowBody(kind: "five_hour", percentUsed: 40, resetsAt: Self.reset)])
    time.advance(by: .seconds(Self.resetDate.timeIntervalSince(time.now) + 60))
    try await limits(
      ["seven_day", "a", "b"].map { LimitWindowBody(kind: $0, percentUsed: 5, resetsAt: nil) })
    let spans = try #require(await bridge.current.claudeLimits).windows.map(\.span)
    #expect(spans == [.minutes(10080), .kind("a"), .kind("b")])
  }

  @Test func anUnjoinedSessionIsIgnored() async throws {
    try await join(a, "Alpha")
    let reply = try await limits(
      [LimitWindowBody(kind: "five_hour", percentUsed: 40, resetsAt: nil)], from: b)
    #expect(reply.status == 200)
    #expect(await bridge.current.claudeLimits == nil)
  }

  @Test func theReadingOutlivesTheLastSession() async throws {
    try await join(a, "Alpha")
    try await limits([LimitWindowBody(kind: "five_hour", percentUsed: 40, resetsAt: Self.reset)])
    try await post("/v1/leave", LeaveBody(sessionId: a))
    #expect(await bridge.current.claudeLimits?.windows.first?.usedPercent == 40)
  }

  @Test func aResetThatDoesNotParseIsNoReset() async throws {
    try await join(a, "Alpha")
    try await limits([
      LimitWindowBody(kind: "five_hour", percentUsed: 40, resetsAt: "tomorrow"),
      LimitWindowBody(kind: "seven_day", percentUsed: 5, resetsAt: "2026-01-01T06:00:00.250Z"),
    ])
    let reading = try #require(await bridge.current.claudeLimits)
    #expect(reading.windows.first?.resetsAt == nil)
    #expect(reading.windows.last?.resetsAt == Self.resetDate.addingTimeInterval(0.25))
  }

  @Test func theStatusDoesNotChange() async throws {
    try await join(a, "Alpha")
    try await limits([LimitWindowBody(kind: "five_hour", percentUsed: 40, resetsAt: nil)])
    let json =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(await bridge.status)) as? [String: Any]
    #expect(
      Set(try #require(json).keys) == ["call", "sessions", "minutesToday", "unheard", "isMuted"])
  }

  @Test func aWeekOnlyReadingMakesAWeekOnlyRow() async throws {
    try await join(a, "Alpha")
    try await limits([LimitWindowBody(kind: "seven_day", percentUsed: 22, resetsAt: Self.reset)])
    let update = await bridge.current
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(identifier: "UTC"))
    let row = try #require(
      LimitRow(
        name: "Claude", limits: update.claudeLimits, now: time.now, calendar: utc,
        locale: Locale(identifier: "en_GB")))
    #expect(row.text == "22% of week")
    #expect(update.claudeLimits?.windows.map(\.span) == [.minutes(10080)])
    let lines = row.tooltip.split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    #expect(lines.first?.hasPrefix("Weekly window resets ") == true)
    #expect(lines.last?.hasPrefix("Read at ") == true)
  }
}
