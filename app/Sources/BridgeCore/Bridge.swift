import Foundation

/// The bridge: serves the mod's routes, runs the call machine's effects in order, and routes
/// handoffs to sessions and their answers back to the voice.
public actor Bridge: Router {
  public static let maxContext = 1500
  /// Why Start did nothing: there is no session to talk to.
  public static let noSession =
    "No Claude Code session has joined: run /live on in a session, then start."

  private let registry: SessionRegistry
  private let makeRealtime: @Sendable () async throws -> any RealtimeControlling
  private let audio: any AudioSide
  private let meter: UsageMeterStore
  private let continuityFile: URL
  private let time: any TimeSource
  private let notifier: (any ResultNotifying)?
  /// Settings' "Notify when a result is waiting".
  private var notifies = true
  private var machine = CallMachine()
  private var realtime: (any RealtimeControlling)?
  /// Counts controllers made and ended, so events from one already replaced are ignored and a
  /// launch that an end overtook is ended too.
  private var controllers = 0
  /// A Start is launching codex: a second Start is ignored, and a Stop meanwhile wins.
  private var starting = false
  /// Counts realtime opens and closes, so an open that a close overtook gives up.
  private var opening = 0
  private var silenceTimer = 0
  /// Generations of the result window and the grace timer, so only the latest one fires.
  private var windowTimer = 0
  private var graceTimer = 0
  /// Each session's conversation; the line carries the target's.
  private var continuity: Continuity
  /// The session whose conversation the line last opened with; its transcripts are kept there.
  private var lineSession: SessionID?
  /// Whether `lineSession` is set for the line opening now; until then a target change cannot
  /// be told from the target it will open with.
  private var lineKnowsSession = false
  private var problem: String?
  /// The session that asked the last `[QUESTION]`; the next handoff goes there.
  private var questionRoute: SessionID?
  private var callStart: Date?
  /// What was last published, so an unchanged status and conversation are not published again.
  private var published: BridgeUpdate?
  public nonisolated let updates: AsyncStream<BridgeUpdate>
  private let publish: AsyncStream<BridgeUpdate>.Continuation
  /// The sessions whose summary just arrived (`POST /v1/context`), so the menu's Load
  /// context stops waiting for it.
  public nonisolated let contextArrivals: AsyncStream<SessionID>
  private let announceContext: AsyncStream<SessionID>.Continuation

  /// `realtime` makes the codex side of a call; it is called at Start, and again after codex
  /// stopped. Sessions are swept every second.
  public init(
    registry: SessionRegistry,
    realtime: @escaping @Sendable () async throws -> any RealtimeControlling, audio: any AudioSide,
    meter: UsageMeterStore, continuityFile: URL, time: any TimeSource,
    notifier: (any ResultNotifying)? = nil
  ) {
    self.notifier = notifier
    self.registry = registry
    makeRealtime = realtime
    self.audio = audio
    self.meter = meter
    self.continuityFile = continuityFile
    self.time = time
    // A file that does not decode, such as the single conversation an earlier build kept, is
    // discarded rather than left on disk.
    if let data = try? Data(contentsOf: continuityFile) {
      if let saved = try? JSONDecoder().decode(Continuity.self, from: data) {
        continuity = saved
      } else {
        try? FileManager.default.removeItem(at: continuityFile)
        continuity = Continuity()
      }
    } else {
      continuity = Continuity()
    }
    (updates, publish) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    (contextArrivals, announceContext) = AsyncStream.makeStream(
      bufferingPolicy: .bufferingNewest(8))
    Task { [weak self] in
      while (try? await time.sleep(for: .seconds(1))) != nil, let bridge = self {
        await bridge.sweep()
      }
    }
  }

  public var status: StatusReply {
    get async {
      let minutesThisCall = if let callStart { await meter.minutes(since: callStart) } else { 0.0 }
      let shown = await registry.target.map { continuity[$0] } ?? Conversation()
      return StatusReply(
        call: machine.phase, sessions: await registry.rows(),
        minutesToday: await meter.minutesToday(), minutesThisCall: minutesThisCall,
        problem: problem, lastContext: shown.context,
        recentTranscript: shown.lines.suffix(3).map { Self.speaker($0.speaker) + $0.text },
        unheard: machine.pending.count)
    }
  }

  /// The target's whole conversation as the menu lists it, oldest first: every line the app
  /// keeps, each `"<Speaker>: <text>"` as the status's last lines are. Empty with no target.
  public var conversation: [String] {
    get async {
      guard let target = await registry.target else { return [] }
      return continuity[target].lines.map { Self.speaker($0.speaker) + $0.text }
    }
  }

  public func perform(_ action: CallAction) async {
    switch action {
    case .start:
      guard machine.phase == .off, !starting else { return }
      starting = true  // before any await, so a second Start meanwhile does nothing
      guard await registry.target != nil else {
        starting = false
        problem = Self.noSession
        await changed()
        return
      }
      do { _ = try await controller() } catch is CancellationError {
        return  // a Stop came first
      } catch {
        starting = false
        problem = Self.sentence(error)
        await changed()
        return
      }
      starting = false
      callStart = time.now
      await send(.start)
    case .stop:
      questionRoute = nil
      await send(.stop)
      await endCodex()
    }
  }

  /// Asks the target session for its context summary; it arrives as `POST /v1/context`.
  /// Returns the session asked, or nil when there is no target.
  @discardableResult public func loadContext() async -> SessionID? {
    guard let target = await registry.target else { return nil }
    await registry.requestContext(for: target)
    return target
  }

  /// The Settings choice: whether a chime for a waiting result also posts a notification.
  public func setNotifies(_ on: Bool) { notifies = on }

  /// The Settings choice: whether a session that becomes the target is asked for its summary.
  public func setAutoContext(_ on: Bool) async { await registry.setAutoContext(on) }

  /// The menu's choice of target, which also ends a question's route; a session that left is
  /// ignored.
  public func setTarget(_ id: SessionID) async {
    questionRoute = nil
    try? await registry.setTarget(id)
    await changed()
  }

  /// The menu's ×: forgets the session and its conversation. Its open request fails as
  /// "session left", and its next poll is told it was removed.
  public func remove(_ id: SessionID) async {
    if questionRoute == id { questionRoute = nil }
    if let delivery = await registry.remove(id) { await deliver(delivery) }
    await forgetConversation(of: id)  // ends in `changed()`, which closes a line it was on
  }

  /// Forgets the target's conversation; its next realtime session starts fresh.
  public func newConversation() async {
    guard let target = await registry.target else { return }
    await forgetConversation(of: target)
  }

  /// Forgets a session's conversation, as when the session is removed from the app.
  public func forgetConversation(of id: SessionID) async {
    continuity.forget(id)
    save()
    await changed()
  }

  public func audioEvent(_ event: AudioEvent) async {
    switch event {
    case .speechStarted: await send(.speechStarted)
    case .speechEnded: await send(.speechEnded)
    case .level: break
    case .failed(let reason):
      await send(.audioFailed(reason))
      await endCodex()
    }
  }

  public func handle(_ req: HTTPRequest) async -> HTTPResponse {
    do {
      switch (req.method, req.path) {
      case ("GET", "/v1/next"):
        guard let id = req.query["sessionId"] else { return .error(400, "sessionId is missing") }
        let work = try await registry.poll(SessionID(rawValue: id))
        return .json(PollReply(status: await status, work: work))
      case ("POST", "/v1/join"):
        let body = try req.decodeBody(JoinBody.self)
        if let old = body.replaces, await registry.rows().contains(where: { $0.sessionId == old }) {
          continuity.move(old, to: body.sessionId)  // after /clear: the same session, a new id
          if lineSession == old { lineSession = body.sessionId }
          save()
        }
        await registry.join(body)
        if problem == Self.noSession { problem = nil }
      case ("POST", "/v1/leave"):
        let delivery = await registry.leave(try req.decodeBody(LeaveBody.self).sessionId)
        if let delivery { await deliver(delivery) }
      case ("POST", "/v1/answer"):
        let body = try req.decodeBody(AnswerBody.self)
        if let delivery = try await registry.complete(body) { await deliver(delivery) }
      case ("POST", "/v1/activity"): await activity(try req.decodeBody(ActivityBody.self))
      case ("POST", "/v1/context"): try await context(try req.decodeBody(ContextBody.self))
      case ("POST", "/v1/target"):
        try await registry.setTarget(try req.decodeBody(TargetBody.self).sessionId)
      case ("POST", "/v1/call"): await perform(try req.decodeBody(CallBody.self).action)
      default: return .error(404, "no route \(req.method) \(req.path)")
      }
      return .json(await changed())
    } catch let error as RegistryError {
      return .error(error.httpStatus, error.message, code: error.code)
    } catch {
      return .error(400, "the body does not match the wire schema")
    }
  }

  // MARK: The call

  private func send(_ event: CallEvent) async {
    let before = machine.phase
    let effects = machine.handle(event)
    let now = time.now  // read before any await, so an interleaved event cannot shift it
    if before != .live, machine.phase == .live { await meter.opened(at: now) }
    if before == .live, machine.phase != .live { await meter.closed(at: now) }
    for effect in effects { await run(effect) }
    await changed()
  }

  private func run(_ effect: CallEffect) async {
    switch effect {
    case .openRealtime: await openRealtime()
    case .closeRealtime:
      opening += 1
      await audio.closePeer()
      await realtime?.close()
    case .startLocalVAD: await audio.startListening()
    case .stopLocalVAD: await audio.stopListening()
    case .flushPreroll: await audio.flushPreroll()
    case .addContext(let text): try? await realtime?.addContext(text)
    case .speak(let text): try? await realtime?.speak(text)
    case .armSilenceTimer(let seconds):
      silenceTimer += 1
      let timer = silenceTimer
      Task { [time] in
        try? await time.sleep(for: .seconds(seconds))
        await self.silenceElapsed(timer)
      }
    case .armResultWindow(let seconds):
      windowTimer += 1
      let timer = windowTimer
      Task { [time] in
        try? await time.sleep(for: .seconds(seconds))
        await self.windowElapsed(timer)
      }
    case .armGrace(let milliseconds):
      graceTimer += 1
      let timer = graceTimer
      Task { [time] in
        try? await time.sleep(for: .milliseconds(milliseconds))
        await self.graceElapsed(timer)
      }
    case .chime:
      await audio.chime()
      await notifyWaiting()
    case .problem(let sentence): problem = sentence
    }
  }

  /// A chime's notification, naming the sessions whose results wait.
  private func notifyWaiting() async {
    guard notifies, let notifier else { return }
    let labels = Dictionary(
      await registry.rows().map { ($0.sessionId, $0.label) }, uniquingKeysWith: { $1 })
    if let notice = ResultNotice.waiting(machine.pending, labels: labels) {
      await notifier.post(notice)
    }
  }

  private func silenceElapsed(_ timer: Int) async {
    if timer == silenceTimer { await send(.silenceElapsed) }
  }

  private func windowElapsed(_ timer: Int) async {
    if timer == windowTimer { await send(.resultWindowElapsed) }
  }

  private func graceElapsed(_ timer: Int) async {
    if timer == graceTimer { await send(.graceElapsed) }
  }

  private func openRealtime() async {
    opening += 1
    let attempt = opening
    lineKnowsSession = false
    do {
      let session = await registry.target
      lineSession = session
      lineKnowsSession = true
      let voice = try await controller()
      let offer = try await audio.makeOffer()
      // only the session's own conversation, context and open tasks: never another session's
      let conversation = session.map { continuity[$0] } ?? Conversation()
      let tasks = if let session { await registry.openTasks(of: session) } else { [String]() }
      let items = conversation.initialItems(
        tasks: tasks, unheard: Set(machine.pending.map(\.text)))
      let answer = try await voice.open(offerSDP: offer, items: items)
      guard attempt == opening else { return await voice.close() }
      try await audio.applyAnswer(answer)
      guard attempt == opening else { return }
      await send(.connected)
    } catch {
      guard attempt == opening else { return }
      if case CodexProblem.exited = error { await endCodex() }
      await audio.closePeer()
      await realtime?.close()  // codex may have opened its side before the page failed
      await send(.connectFailed(Self.sentence(error)))
    }
  }

  /// The running codex controller, or a new one. Throws `CancellationError` when codex was
  /// ended while the new one launched; that one is ended too.
  private func controller() async throws -> any RealtimeControlling {
    if let realtime { return realtime }
    let generation = controllers
    let made: any RealtimeControlling
    do { made = try await makeRealtime() } catch {
      // A launch that fails after a Stop is the Stop's business, not a problem to show.
      throw generation == controllers ? error : CancellationError()
    }
    guard generation == controllers else {
      await made.shutdown()
      throw CancellationError()
    }
    controllers += 1
    let id = controllers
    realtime = made
    Task { [weak self] in
      for await event in await made.events { await self?.realtimeEvent(event, from: id) }
    }
    return made
  }

  private func endCodex() async {
    let ended = realtime
    realtime = nil
    starting = false
    controllers += 1
    await ended?.shutdown()
  }

  private func realtimeEvent(_ event: RealtimeEvent, from controller: Int) async {
    guard controller == controllers else { return }
    switch event {
    case .handoff(let request):
      let session = await route(request)
      await send(.handedOff(session))
      if session == nil {
        let line = AnswerShaper.line(
          tag: "FAILED", label: "LiveBridge", body: "no Claude Code session is joined.")
        await send(.deliver(VoiceLine(text: line)))
      }
    case .userUtterance(let text):
      record(.owner, text, in: lineSession)
      await send(.userTranscribed)
    case .assistantUtterance(let text):
      record(.voice, text, in: lineSession)
      await send(.assistantFinishedSpeaking(text))
    case .assistantSpeaking: await send(.assistantSpeaking)
    case .closed(let reason):
      opening += 1
      await audio.closePeer()
      await send(.remoteClosed(reason))
    }
    await changed()
  }

  private func record(_ speaker: Conversation.Line.Speaker, _ text: String, in id: SessionID?) {
    guard let id, !text.isEmpty else { return }
    continuity.record(speaker, text, in: id)
    save()
  }

  /// A session's line for the voice is kept in that session's conversation, whichever session
  /// the open line is about, and spoken in the line as it is.
  private func say(_ line: VoiceLine) async {
    record(.claude, line.text, in: line.session)
    await send(.deliver(line))
  }

  /// A new target closes a line opened with another session's conversation; the next speech
  /// opens it with the target's. With no session left there is no conversation to switch to,
  /// so the line stays open.
  private func followTarget() async {
    guard machine.phase == .connecting || machine.phase == .live, lineKnowsSession,
      let target = await registry.target, target != lineSession
    else { return }
    await send(.targetChanged)
  }

  // MARK: Routing

  /// A handoff goes to the session that asked the last question, else to the target. It
  /// supersedes that session's results the owner has not heard yet. Returns the session it went
  /// to, or nil when none is joined.
  private func route(_ request: VoiceRequest) async -> SessionID? {
    let route = questionRoute
    questionRoute = nil
    for id in [route, await registry.target].compactMap({ $0 }) {
      guard (try? await registry.enqueue(request, for: id)) != nil else { continue }
      machine.withdraw { $0.session == id }
      return id
    }
    return nil
  }

  private func deliver(_ delivery: Delivery) async {
    // only a question the call keeps (not one dropped while off) routes the next handoff
    if delivery.status == .question, machine.phase != .off { questionRoute = delivery.session }
    let line = AnswerShaper.forVoice(delivery.text, status: delivery.status, label: delivery.label)
    await say(VoiceLine(text: line, session: delivery.session))
  }

  private func label(of id: SessionID) async throws -> SessionRow {
    guard let row = await registry.rows().first(where: { $0.sessionId == id }) else {
      throw RegistryError.unknownSession(id)
    }
    return row
  }

  /// A session that starts waiting for approval sends the voice a notice, which goes once the
  /// approval is settled.
  private func activity(_ body: ActivityBody) async {
    guard let row = try? await label(of: body.sessionId) else { return }
    await registry.setActivity(body)
    switch (row.activity == .approval, body.state == .approval) {
    case (false, true):
      let line = AnswerShaper.line(
        tag: "APPROVAL", label: row.label, body: "Claude is waiting for your approval")
      await say(VoiceLine(text: line, session: body.sessionId))
    case (true, false):
      machine.withdraw { $0.session == body.sessionId && $0.text.hasPrefix("[APPROVAL]") }
    default: break
    }
  }

  /// A session's summary, as one redacted line of at most `maxContext` characters, is shown as
  /// it is and kept in the session's conversation; a live line about that session gets it at
  /// once, and it does not hold the line open.
  private func context(_ body: ContextBody) async throws {
    let row = try await label(of: body.sessionId)
    let line = AnswerShaper.line(
      tag: "CONTEXT", label: row.label, body: body.summary, limit: Self.maxContext)
    continuity.setContext(line, for: body.sessionId)
    save()
    announceContext.yield(body.sessionId)
    if machine.phase == .live, lineSession == body.sessionId {
      try? await realtime?.addContext(line)
    }
  }

  private func sweep() async {
    for delivery in await registry.sweep() { await deliver(delivery) }
    await changed()
  }

  /// Publishes the status if it changed; every change of the target passes through here.
  @discardableResult private func changed() async -> StatusReply {
    await followTarget()
    let now = await status
    let update = BridgeUpdate(status: now, conversation: await conversation)
    if update != published { publish.yield(update) }
    published = update
    return now
  }

  private func save() {
    try? JSONEncoder().encode(continuity).write(to: continuityFile, options: .atomic)
  }

  private static func sentence(_ error: any Error) -> String { error.localizedDescription }

  /// How the menu's lines name who said each.
  private static func speaker(_ speaker: Conversation.Line.Speaker) -> String {
    switch speaker {
    case .owner: "You: "
    case .voice: "Voice: "
    case .claude: "Claude: "
    }
  }
}

/// What the app shows of the bridge: the status, and the target's whole conversation, which
/// the menu lists and the status, carried by every poll, does not.
public struct BridgeUpdate: Sendable, Equatable {
  public let status: StatusReply
  public let conversation: [String]
}
