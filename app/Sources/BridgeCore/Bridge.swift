import Foundation

/// The bridge: serves the mod's routes, runs the call machine's effects in order, and routes
/// handoffs to sessions and their answers back to the voice.
public actor Bridge: Router {
  public static let maxContext = 1500

  private let registry: SessionRegistry
  private let makeRealtime: @Sendable () async throws -> any RealtimeControlling
  private let audio: any AudioSide
  private let meter: UsageMeterStore
  private let continuityFile: URL
  private let time: any TimeSource
  private let notifier: (any ResultNotifying)?
  /// Settings' "Notify when a result is waiting", read at each chime.
  private let notifies: @Sendable () -> Bool
  private var machine = CallMachine()
  /// The running codex controller; its events count only while it is this one.
  private var realtime: (any RealtimeControlling)?
  /// The one connection attempt under way: Start launching codex, or the line opening
  /// (launching codex first if it is not running). Stop, a close of the line and a new target
  /// cancel it; a cancelled attempt has no effect.
  private var connecting: Task<Void, Never>?
  /// The armed timers, one of each kind; arming one again replaces it.
  private var timers: [CallTimer: Task<Void, Never>] = [:]
  /// Each session's conversation; the line carries the target's.
  private var continuity: Continuity
  /// The session whose conversation the line last opened with; its transcripts are kept there.
  private var lineSession: SessionID?
  /// Whether `lineSession` is set for the line opening now; until then a target change cannot
  /// be told from the target it will open with.
  private var lineKnowsSession = false
  private var problem: Problem?
  /// The session that asked the last `[QUESTION]`; the next handoff goes there.
  private var questionRoute: SessionID?
  private var callStart: Date?
  /// What was last published, so an unchanged status and conversation are not published again.
  private var published: BridgeUpdate?
  /// Counts `changed()` calls; only the latest one publishes.
  private var changes = 0
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
    notifier: (any ResultNotifying)? = nil, notifies: @escaping @Sendable () -> Bool = { true }
  ) {
    self.notifier = notifier
    self.notifies = notifies
    self.registry = registry
    makeRealtime = realtime
    self.audio = audio
    self.meter = meter
    self.continuityFile = continuityFile
    self.time = time
    // a file that does not decode starts empty
    continuity =
      (try? JSONDecoder().decode(Continuity.self, from: Data(contentsOf: continuityFile)))
      ?? Continuity()
    (updates, publish) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    (contextArrivals, announceContext) = AsyncStream.makeStream(
      bufferingPolicy: .bufferingNewest(8))
    Task { [weak self] in
      while (try? await time.sleep(for: .seconds(1))) != nil, let bridge = self {
        await bridge.sweep()
      }
    }
  }

  /// What every joined session's poll carries.
  public var status: StatusReply {
    get async {
      StatusReply(
        call: machine.phase, sessions: await registry.rows(),
        minutesToday: await meter.minutesToday(), problem: problem?.sentence,
        unheard: machine.pending.count)
    }
  }

  /// What the app shows: the status, and what only the app needs.
  public var current: BridgeUpdate {
    get async {
      let status = await status
      let minutes = if let callStart { await meter.minutes(since: callStart) } else { 0.0 }
      let shown = await registry.target.map { continuity[$0] } ?? Conversation()
      return BridgeUpdate(
        status: status, problem: problem, minutesThisCall: minutes, context: shown.context,
        conversation: shown.lines)
    }
  }

  public func perform(_ action: CallAction) async {
    switch action {
    case .start:
      guard await registry.target != nil else {
        problem = .noSession
        await changed()
        return
      }
      // after the look, so a second Start that came in meanwhile finds this one under way
      guard machine.phase == .off, connecting == nil else { return }
      await attempt { await self.launch() }
    case .stop:
      questionRoute = nil
      await send(.stop)
      await endCodex()
    }
  }

  /// Runs `work` as the connection attempt, until it ends or is cancelled.
  private func attempt(_ work: @escaping @Sendable () async -> Void) async {
    let task = Task { await work() }
    connecting = task
    await task.value
    if connecting == task { connecting = nil }
  }

  /// Start: launches codex, so a problem with it shows at once, then listens.
  private func launch() async {
    do { _ = try await controller() } catch {
      guard !Task.isCancelled else { return }  // a Stop came first
      problem = Problem(error)
      await changed()
      return
    }
    guard !Task.isCancelled else { return }
    callStart = time.now
    await send(.start)
  }

  /// Whether any session has a request open, which an update installs only after.
  public var hasOpenRequests: Bool { get async { await registry.hasOpenRequests } }

  /// Asks the target session for its context summary; it arrives as `POST /v1/context`.
  public func loadContext() async {
    guard let target = await registry.target else { return }
    await registry.requestContext(for: target)
  }

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

  /// Forgets the target's conversation; its next realtime session starts fresh, and a closed
  /// line no longer opens for a result the forgotten conversation asked for.
  public func newConversation() async {
    guard let target = await registry.target else { return }
    if lineKnowsSession, lineSession == target { await send(.conversationChanged) }
    await forgetConversation(of: target)
  }

  /// Forgets a session's conversation, as when the session is removed from the app.
  private func forgetConversation(of id: SessionID) async {
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
        let replaced = await registry.rows().contains { $0.sessionId == body.replaces }
        try await registry.join(body)
        if let old = body.replaces, replaced {  // after /clear: the same session, a new id
          continuity.move(old, to: body.sessionId)
          machine.rename(old, to: body.sessionId)
          if lineSession == old { lineSession = body.sessionId }
          if questionRoute == old { questionRoute = body.sessionId }
          save()
        }
        if problem == .noSession { problem = nil }
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
    case .openRealtime: await attempt { await self.openLine() }
    case .closeRealtime:
      connecting?.cancel()
      connecting = nil
      await audio.closePeer()
      await realtime?.close()
    case .startLocalVAD: await audio.startListening()
    case .stopLocalVAD: await audio.stopListening()
    case .flushPreroll: await audio.flushPreroll()
    case .addContext(let line): try? await realtime?.addContext(line.text)
    case .speak(let line): try? await realtime?.speak(line.text)
    case .armSilenceTimer(let seconds): arm(.silence, after: .seconds(seconds))
    case .armResultWindow(let seconds): arm(.resultWindow, after: .seconds(seconds))
    case .armGrace(let milliseconds): arm(.grace, after: .milliseconds(milliseconds))
    case .chime:
      await audio.chime()
      await notifyWaiting()
    case .problem(let shown): problem = shown
    }
  }

  /// A chime's notification, naming the sessions whose results wait.
  private func notifyWaiting() async {
    guard notifies(), let notifier else { return }
    let labels = Dictionary(
      await registry.rows().map { ($0.sessionId, $0.label) }, uniquingKeysWith: { $1 })
    if let notice = ResultNotice.waiting(machine.pending, labels: labels) {
      await notifier.post(notice)
    }
  }

  private func arm(_ timer: CallTimer, after delay: Duration) {
    timers[timer]?.cancel()
    timers[timer] = Task { [time] in
      try? await time.sleep(for: delay)
      await self.fire(timer)
    }
  }

  /// A timer armed again meanwhile was cancelled, and does not fire.
  private func fire(_ timer: CallTimer) async {
    guard !Task.isCancelled else { return }
    await send(timer.event)
  }

  /// Opens the line with the target's conversation. Cancelled, it does nothing more: whoever
  /// cancelled it closes what it opened. A line the voice closed itself (`CancellationError`)
  /// says why in its `closed` event.
  private func openLine() async {
    lineKnowsSession = false
    let session = await registry.target
    lineSession = session
    lineKnowsSession = true
    do {
      let voice = try await controller()
      let offer = try await audio.makeOffer()
      // only the session's own conversation, context and open tasks: never another session's
      let conversation = session.map { continuity[$0] } ?? Conversation()
      let tasks = if let session { await registry.openTasks(of: session) } else { [String]() }
      let items = conversation.initialItems(
        tasks: tasks, unheard: Set(machine.pending.map(\.text)))
      let answer = try await voice.open(offerSDP: offer, items: items)
      try Task.checkCancellation()
      try await audio.applyAnswer(answer)
      try Task.checkCancellation()
      await send(.connected)
    } catch {
      guard !Task.isCancelled, !(error is CancellationError) else { return }
      if let realtime, (error as? CodexProblem)?.endsCodex == true { await retire(realtime) }
      await audio.closePeer()
      await realtime?.close()  // codex may have opened its side before the page failed
      await send(.connectFailed(Problem(error)))
    }
  }

  /// The running codex controller, or a new one. A launch runs to its end, outside the
  /// attempt's cancellation; an attempt cancelled meanwhile ends what it launched.
  private func controller() async throws -> any RealtimeControlling {
    if let realtime { return realtime }
    let made = try await Task { [makeRealtime] in try await makeRealtime() }.value
    guard !Task.isCancelled else {
      await Task { await made.shutdown() }.value
      throw CancellationError()
    }
    realtime = made
    Task { [weak self] in
      for await event in await made.events { await self?.realtimeEvent(event, from: made) }
      await self?.retire(made)
    }
    return made
  }

  private func endCodex() async {
    if let realtime { await retire(realtime) }
  }

  /// Ends `controller` if it is still the running one: its events ended (codex exited or
  /// stopped answering), or the call ended. The next line launches a fresh one.
  private func retire(_ controller: any RealtimeControlling) async {
    guard realtime === controller else { return }
    realtime = nil
    await controller.shutdown()
  }

  private func realtimeEvent(_ event: RealtimeEvent, from controller: any RealtimeControlling)
    async
  {
    guard realtime === controller else { return }
    switch event {
    case .handoff(let request):
      let session = await route(request)
      await send(.handedOff(session))
      if session == nil {
        await send(
          .deliver(
            AnswerShaper.line(
              .failed, label: "LiveBridge", body: "no Claude Code session is joined.")))
      }
    case .userUtterance(let text):
      record(.owner, text, in: lineSession)
      await send(.userTranscribed)
    case .assistantUtterance(let text):
      record(.voice, text, in: lineSession)
      await send(.assistantFinishedSpeaking(text))
    case .assistantSpeaking: await send(.assistantSpeaking)
    case .closed(let reason):
      connecting?.cancel()
      connecting = nil
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
  /// opens it with the target's. While the line is closed it ends the wait for a result, which
  /// would open a line seeded with the new target's conversation. With no session left nobody is
  /// there to talk to, so the call
  /// stops as Stop does, a Start still launching codex included, and says why, as Start with no
  /// session does.
  private func followTarget() async {
    guard machine.phase != .off || connecting != nil else { return }
    guard let target = await registry.target else {
      problem = .noSession
      await perform(.stop)
      return
    }
    guard lineKnowsSession, target != lineSession, isLineOpen || !machine.awaited.isEmpty
    else { return }
    await send(.conversationChanged)
  }

  private var isLineOpen: Bool { machine.phase == .connecting || machine.phase == .live }

  // MARK: Routing

  /// A handoff goes to the session that asked the last question, else to the target. It
  /// supersedes that session's results the owner has not heard yet, and its brief is kept in
  /// that session's conversation, so the menu shows its queue took it. Returns the session it
  /// went to, or nil when none is joined.
  private func route(_ request: VoiceRequest) async -> SessionID? {
    let route = questionRoute
    questionRoute = nil
    for id in [route, await registry.target].compactMap({ $0 }) {
      guard (try? await registry.enqueue(request, for: id)) != nil else { continue }
      machine.withdraw { $0.session == id }
      record(.handoff, request.brief, in: id)
      return id
    }
    return nil
  }

  private func deliver(_ delivery: Delivery) async {
    // only a question the call keeps (not one dropped while off) routes the next handoff
    if delivery.status == .question, machine.phase != .off { questionRoute = delivery.session }
    await say(
      AnswerShaper.forVoice(
        delivery.text, status: delivery.status, label: delivery.label, session: delivery.session))
  }

  private func label(of id: SessionID) async throws -> SessionRow {
    guard let row = await registry.rows().first(where: { $0.sessionId == id }) else {
      throw RegistryError.unknownSession(id)
    }
    return row
  }

  /// A session that starts waiting for approval sends the voice a notice, which goes once the
  /// approval is settled. A question Claude asked goes to the voice whole, and the next handoff
  /// is routed to that session as its reply.
  private func activity(_ body: ActivityBody) async {
    guard let row = try? await label(of: body.sessionId) else { return }
    await registry.setActivity(body)
    switch (row.activity == .approval, body.state == .approval) {
    case (false, true):
      if let question = body.question {
        if machine.phase != .off { questionRoute = body.sessionId }
        await say(
          AnswerShaper.line(.asking, label: row.label, body: question, session: body.sessionId))
      } else {
        await say(
          AnswerShaper.line(
            .approval, label: row.label, body: "Claude is waiting for your approval",
            session: body.sessionId))
      }
    case (true, false):
      if questionRoute == body.sessionId { questionRoute = nil }
      machine.withdraw { $0.session == body.sessionId && [.approval, .asking].contains($0.kind) }
    default: break
    }
  }

  /// A session's summary, as one redacted line of at most `maxContext` characters, is shown as
  /// it is and kept in the session's conversation; a live line about that session gets it at
  /// once, and it does not hold the line open.
  private func context(_ body: ContextBody) async throws {
    let row = try await label(of: body.sessionId)
    let line = AnswerShaper.line(
      .context, label: row.label, body: body.summary, limit: Self.maxContext
    ).text
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
  /// Two changes can interleave across the awaits, so only the latest one publishes: an older
  /// one finishing last would show the status from before the newer change.
  @discardableResult private func changed() async -> StatusReply {
    await followTarget()
    changes += 1
    let mine = changes
    let update = await current
    guard mine == changes else { return update.status }
    if update != published { publish.yield(update) }
    published = update
    return update.status
  }

  private func save() {
    try? JSONEncoder().encode(continuity).write(to: continuityFile, options: .atomic)
  }
}

/// The call's timers, each armed by its `CallEffect`.
private enum CallTimer {
  case silence, resultWindow, grace

  var event: CallEvent {
    switch self {
    case .silence: .silenceElapsed
    case .resultWindow: .resultWindowElapsed
    case .grace: .graceElapsed
    }
  }
}

/// What the app shows of the bridge: the status every joined session gets too, and what only
/// the menu shows, which no session is sent.
public struct BridgeUpdate: Sendable, Equatable {
  public let status: StatusReply
  /// The status's problem, with its kind.
  public let problem: Problem?
  public let minutesThisCall: Double
  /// The target's `[CONTEXT]` line, exactly as the voice gets it; kept across restarts.
  public let context: String?
  /// The target's whole conversation, oldest first: every line the app keeps.
  public let conversation: [Conversation.Line]
}
