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
  /// Settings' "Play sounds for requests and answers", read at each sound.
  private let confirmsWithSound: @Sendable () -> Bool
  /// Settings' "Pause sync while the call is stopped", read at each synced line, join and line
  /// that opens.
  private let pausesSync: @Sendable () -> Bool
  /// A session's first summary is loaded under the pause too (`Settings.loadContextOnFirstCall`).
  private let loadsContextOnFirstCall: @Sendable () -> Bool
  /// Settings' timers for the line, read before each event.
  private let timeouts: @Sendable () -> CallMachine.Timeouts
  /// Settings' Connect over TCP, read as each line applies its answer.
  private let connectsOverTCP: @Sendable () -> Bool
  /// Told how long each summary ask took to be answered (`SummaryLog`).
  private let reportsSummary: @Sendable (SummaryTiming) -> Void
  /// Settings' summary model, read at each ask.
  private let summaryModel: @Sendable () -> String
  /// What came of the last summary asked for with a model.
  public private(set) var lastSummary: SummaryReport?
  /// Settings' model check in flight: its id, the session it went to, who waits on it, and the task
  /// that hands it over and ends it after `checkSeconds`.
  private var modelCheck:
    (
      id: String, session: SessionID, done: CheckedContinuation<ModelCheckResult, Never>,
      timer: Task<Void, Never>
    )?
  private static let checkSeconds = 20
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
  /// What the open line is still saying, which belongs to `lineSession`.
  private var growing = GrowingLines()
  /// The session whose conversation the line last opened with; its transcripts are kept there.
  private var lineSession: SessionID?
  /// Whether `lineSession` is set for the line opening now; until then a target change cannot
  /// be told from the target it will open with. It goes false with the decision to open, not
  /// when the attempt starts: the `changed()` that follows that decision could otherwise take the
  /// last line's session for this line's, and close it.
  private var lineKnowsSession = false
  /// Which lines of this call wait for their session's summary.
  private var summaryWait = SummaryWait()
  /// The lines waiting for a summary, each woken to look again at every change.
  private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
  private var waits = 0
  /// Counts the wakes of `changed()`, so a change that comes while a line looks is not missed.
  private var wakes = 0
  /// Runs in each look of a waiting line, past its awaits and before it sleeps: where a test lands
  /// a change.
  private var whileLooking: @Sendable () async -> Void = {}
  /// The line's latest wait, for the log: the session and its ask's time, when the wait began,
  /// and when it ended if the answer did not end it.
  private var lineWait: (session: SessionID, ask: Date, since: Date, until: Date?)?
  /// The target the call was last at, which a target change asks ahead of its line; nil while
  /// the call is off.
  private var callTarget: SessionID?
  /// The context line the opening line was seeded with.
  private var seededContext: String?
  /// A summary for the opening line's session that came while it connected, added once the line
  /// is connected unless the line was seeded with it.
  private var heldContext: VoiceLine?
  private var problem: Problem?
  /// What Claude Code last said of Claude's usage windows, merged over the readings before it.
  /// Memory only; it outlives the sessions that sent it.
  private var claudeLimits: UsageLimits?
  private var callStart: Date?
  /// What was last published, so an unchanged status and conversation are not published again.
  private var published: BridgeUpdate?
  /// Counts `changed()` calls; only the latest one publishes.
  private var changes = 0
  public nonisolated let updates: AsyncStream<BridgeUpdate>
  private let publish: AsyncStream<BridgeUpdate>.Continuation
  /// The sessions whose summary was just taken (`POST /v1/context`), so the menu shows it loaded;
  /// an empty one is announced as such.
  public nonisolated let contextArrivals: AsyncStream<ContextArrival>
  private let announceContext: AsyncStream<ContextArrival>.Continuation
  /// The running app's version; sessions on an older mod are listed against it.
  private let appVersion: AppVersion?

  /// `realtime` makes the codex side of a call; it is called at Start, and again after codex
  /// stopped. Sessions are swept every second.
  public init(
    registry: SessionRegistry,
    realtime: @escaping @Sendable () async throws -> any RealtimeControlling, audio: any AudioSide,
    meter: UsageMeterStore, continuityFile: URL, time: any TimeSource,
    notifier: (any ResultNotifying)? = nil, notifies: @escaping @Sendable () -> Bool = { true },
    confirmsWithSound: @escaping @Sendable () -> Bool = { true },
    pausesSync: @escaping @Sendable () -> Bool = { false },
    timeouts: @escaping @Sendable () -> CallMachine.Timeouts,
    loadsContextOnFirstCall: @escaping @Sendable () -> Bool,
    connectsOverTCP: @escaping @Sendable () -> Bool = { false },
    summaryModel: @escaping @Sendable () -> String = { SummaryModel.default },
    reportsSummary: @escaping @Sendable (SummaryTiming) -> Void = { _ in }, appVersion: AppVersion?
  ) {
    self.reportsSummary = reportsSummary
    self.summaryModel = summaryModel
    self.appVersion = appVersion
    self.notifier = notifier
    self.notifies = notifies
    self.confirmsWithSound = confirmsWithSound
    self.pausesSync = pausesSync
    self.timeouts = timeouts
    self.loadsContextOnFirstCall = loadsContextOnFirstCall
    self.connectsOverTCP = connectsOverTCP
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
        unheard: machine.pending.count, isMuted: machine.isMuted)
    }
  }

  /// What the app shows: the status, and what only the app needs.
  public var current: BridgeUpdate {
    get async {
      let status = await status
      let minutes = if let callStart { await meter.minutes(since: callStart) } else { 0.0 }
      let target = await registry.target
      let shown = target.map { continuity[$0] } ?? Conversation()
      let contextNeed = if let target { await contextNeed(target) } else { ContextNeed.none }
      var olderMods: [String] = []
      if let appVersion { olderMods = await registry.labelsOnAnOlderMod(than: appVersion) }
      return BridgeUpdate(
        status: status, problem: problem, minutesThisCall: minutes,
        conversation: shown.shownLines + growing.lines,
        labelsOnAnOlderMod: olderMods, contextNeed: contextNeed,
        claudeLimits: claudeLimits, lastSummary: lastSummary,
        summariesInFlight: await summariesInFlight)
    }
  }

  /// The joined sessions whose summary is on its way, whatever asked for it (Start, a target
  /// change, Load context or a line): an open ask to a mod that writes summaries, within the
  /// mod's budget, that no gap or forget has made stale (`SummaryAsk.isInFlight`).
  public var summariesInFlight: Set<SessionID> {
    get async {
      let now = time.now
      return Set(
        await registry.rows().map(\.sessionId).filter {
          continuity.openSummaryAsk(of: $0, at: now)?.isInFlight(at: now) ?? false
        })
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
      await send(.stop)
      await endCodex()
    case .mute: await send(.mute)
    case .unmute: await send(.unmute)
    }
  }

  /// Runs `work` as the connection attempt, until it ends or is cancelled; `waits` false
  /// returns once it has started.
  private func attempt(waits: Bool = true, _ work: @escaping @Sendable () async -> Void) async {
    let task = Task { await work() }
    connecting = task
    let ended = Task {
      await task.value
      if connecting == task { connecting = nil }
    }
    if waits { await ended.value }
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
    summaryWait.newCall()
    callTarget = nil  // so the call's first `changed()` asks the target ahead of its line
    await send(.start)
  }

  /// Whether any session has a request open, which an update installs only after.
  public var hasOpenRequests: Bool { get async { await registry.hasOpenRequests } }

  /// Asks the target session for its context summary; it arrives as `POST /v1/context`. The
  /// menu shows the ask in flight at once.
  public func loadContext() async {
    guard let target = await registry.target else { return }
    await askForContext(of: target)
    await changed()
  }

  /// At Start and at a target change during the call, a session whose mod writes summaries is
  /// asked at once, if its line would ask (`needsContext`, unless the pause holds it back), so its
  /// line waits less. One that forks is asked when its line opens, so Start spends nothing on the
  /// session's own model before anyone speaks.
  private func askAhead(of id: SessionID) async {
    guard await registry.writesSummaries(id), !pauseHoldsBackSummary(of: id),
      await needsContext(id)
    else { return }
    await askForContext(of: id)
  }

  /// A mod that writes summaries is told the model and, unless it is the default, the default to
  /// fall back on; one that forks is asked as before.
  private func askForContext(of id: SessionID) async {
    var model: String?
    var fallback: String?
    if await registry.writesSummaries(id) {
      model = summaryModel()
      fallback = model == SummaryModel.default ? nil : SummaryModel.default
    }
    let ask = continuity.noteSummaryAsk(of: id, at: time.now, model: model, fallbackModel: fallback)
    save()
    await registry.requestContext(
      for: id, model: ask.model, fallbackModel: ask.fallbackModel, ask: ask.number)
  }

  /// Settings' check of a custom summary model, run by a joined session's mod: the target if its
  /// mod writes summaries, else the most recently joined one whose mod does. The result is taken
  /// only from that session, under the check's id; 20 s without one, or the session's drop, is
  /// `noAnswer`. A newer check ends the one before it. It takes the session's word: a process
  /// joined as that session can say any model works (SECURITY.md).
  public func checkModel(_ model: String) async -> ModelCheckResult {
    guard let session = await registry.sessionThatChecks() else { return .noSession }
    let id = UUID().uuidString
    return await withCheckedContinuation { done in
      finishCheck(.noAnswer)
      let timer = Task { [registry, time] in
        await registry.requestCheck(for: session, check: id, model: model)
        guard (try? await time.sleep(for: .seconds(Self.checkSeconds))) != nil else { return }
        await self.finishCheck(.noAnswer, of: id)
      }
      modelCheck = (id, session, done, timer)
    }
  }

  /// Ends the check in flight with `result`, if it is check `id` or no id is given.
  private func finishCheck(_ result: ModelCheckResult, of id: String? = nil) {
    guard let check = modelCheck, id == nil || id == check.id else { return }
    modelCheck = nil
    check.timer.cancel()
    check.done.resume(returning: result)
  }

  /// `POST /v1/model-check`: the result of the check in flight, from the session it went to.
  private func modelChecked(_ body: ModelCheckBody) async throws {
    _ = try await label(of: body.sessionId)
    guard modelCheck?.session == body.sessionId else { return }
    finishCheck(ModelCheckResult(body), of: body.id)
  }

  /// The menu's choice of target; a session that left is ignored.
  public func setTarget(_ id: SessionID) async {
    try? await pickTarget(id)
    await changed()
  }

  /// The owner's choice of target, from the menu or the band. A change takes every
  /// other session's question off the line's queue, so it is not said on the new target's line and
  /// the reply does not reach the wrong session; it stays recorded, so it is in its own session's
  /// seed. A route ends with its question.
  private func pickTarget(_ id: SessionID) async throws {
    let isChange = await registry.target != id
    try await registry.setTarget(id)
    if isChange { await withdraw { $0.asks && $0.session != id } }
    machine.endSaidQuestionRoutes()
  }

  /// The menu's ×: forgets the session and its conversation. Its open request fails as
  /// "session left", and its next poll is told it was removed.
  public func remove(_ id: SessionID) async {
    if let delivery = await registry.remove(id) { await deliver(delivery) }
    await forgetConversation(of: id)  // ends in `changed()`, which closes a line it was on
  }

  /// Settings' Connect over TCP changed and the owner chose Reconnect: a line connecting or open
  /// closes and opens again at once, over the new transport. With no line, the next one takes it.
  public func reconnect() async {
    await send(.reconnect)
  }

  /// Settings changed one of the line's timers: one turned on starts on a quiet open line.
  public func timeoutsChanged() async {
    await send(.timeoutsChanged)
  }

  /// Forgets the target's conversation; its next realtime session starts fresh.
  public func newConversation() async {
    guard let target = await registry.target else { return }
    if lineIsOpen(for: target) { await send(.conversationChanged) }
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
    case .lineError(let code, let message):
      // codex's sideband does not carry these: the service's usage gate reaches only the page
      if let reason = Problem.refusal(code: code, message: message) { await send(.refused(reason)) }
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
          if lineSession == old {
            lineSession = body.sessionId
            heldContext?.session = body.sessionId
          }
          save()
        }
        if body.missed == true {
          continuity.markMissed(body.sessionId, asPaused: pausesSync())
          save()
        }
        if problem == .noSession { problem = nil }
      case ("POST", "/v1/leave"):
        let delivery = await registry.leave(try req.decodeBody(LeaveBody.self).sessionId)
        if let delivery { await deliver(delivery) }
      case ("POST", "/v1/answer"):
        let body = try req.decodeBody(AnswerBody.self)
        switch try await registry.complete(body) {
        case .delivery(let delivery): await deliver(delivery)
        case .superseded: await keepSuperseded(body)
        case .dropped: break
        }
      case ("POST", "/v1/activity"): await activity(try req.decodeBody(ActivityBody.self))
      case ("POST", "/v1/limits"): await limits(try req.decodeBody(LimitsBody.self))
      case ("POST", "/v1/context"): try await context(try req.decodeBody(ContextBody.self))
      case ("POST", "/v1/model-check"):
        try await modelChecked(try req.decodeBody(ModelCheckBody.self))
      case ("POST", "/v1/sync"): try await sync(try req.decodeBody(SyncBody.self))
      case ("POST", "/v1/target"):
        try await pickTarget(try req.decodeBody(TargetBody.self).sessionId)
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
    machine.timeouts = timeouts()
    let effects = machine.handle(event)
    let now = time.now  // read before any await, so an interleaved event cannot shift it
    if before != .live, machine.phase == .live { await meter.opened(at: now) }
    if before == .live, machine.phase != .live { await meter.closed(at: now) }
    for effect in effects { await run(effect) }
    await changed()
  }

  private func run(_ effect: CallEffect) async {
    switch effect {
    case .openRealtime: await startOpening(preroll: true)
    case .openRealtimeForResult: await startOpening(preroll: false, waits: false)
    case .reopenRealtime(let preroll):
      await closeLine()
      // A Stop, a new target or another reconnect may have come during the close.
      guard machine.phase == .connecting, connecting == nil else { return }
      growing = GrowingLines()  // no final text comes for what the closed line said
      await startOpening(preroll: preroll, waits: false)
    case .closeRealtime: await closeLine()
    case .startLocalVAD:
      // a Mute meanwhile does not cancel a Start: the page records it, and listens muted
      if await mayTakeMicrophone(while: { $0.phase != .off }) { await audio.startListening() }
    case .stopLocalVAD: await audio.stopListening()
    case .endCodex: await endCodex()
    case .flushPreroll: await audio.flushPreroll()
    case .muteMicrophone: await audio.muteMicrophone()
    case .unmuteMicrophone:
      if await mayTakeMicrophone(while: { $0.phase != .off && !$0.isMuted }) {
        await audio.unmuteMicrophone()
      }
    case .addContext(let line): try? await realtime?.addContext(line.text)
    case .speak(let line): try? await realtime?.speak(line.text)
    case .armSilenceTimer(let seconds): arm(.silence, after: .seconds(seconds))
    case .cancelSilenceTimer:
      timers[.silence]?.cancel()
      timers[.silence] = nil
    case .armResultWindow(let seconds): arm(.resultWindow, after: .seconds(seconds))
    case .armGrace(let milliseconds): arm(.grace, after: .milliseconds(milliseconds))
    case .chime:
      await audio.chime()
      await notifyWaiting()
    case .confirmHandoff: if confirmsWithSound() { await audio.confirmHandoff() }
    case .confirmAnswer: if confirmsWithSound() { await audio.confirmAnswer() }
    case .problem(let shown): problem = shown
    }
  }

  private func closeLine() async {
    connecting?.cancel()
    connecting = nil
    await audio.closePeer()
    await realtime?.close()
  }

  /// Asks macOS for the microphone, whose first-run prompt stays up until the owner answers it;
  /// meanwhile a Stop or a Mute can change the call. So the take is still wanted only while
  /// `isCurrent` holds for the call as it is once macOS answered. A refusal for a wanted take
  /// ends the call, as a failed microphone does; for one no longer wanted it says nothing.
  private func mayTakeMicrophone(while isCurrent: (CallMachine) -> Bool) async -> Bool {
    let refusal = await audio.microphoneProblem()
    guard isCurrent(machine) else { return false }
    if let refusal {
      await audioEvent(.failed(refusal))
      return false
    }
    return true
  }

  /// A chime's notification, naming the sessions whose results wait.
  private func notifyWaiting() async {
    guard notifies(), let notifier else { return }
    let labels = Dictionary(
      await registry.rows().map { ($0.sessionId, $0.label) }, uniquingKeysWith: { $1 })
    if let notice = ResultNotice.waiting(
      machine.pending, labels: labels, callIsOff: machine.phase == .off)
    {
      await notifier.post(notice)
    }
  }

  /// The deadline is taken now, not when the task starts, so a late start does not move it.
  private func arm(_ timer: CallTimer, after delay: Duration) {
    timers[timer]?.cancel()
    let deadline = time.now + delay.timeInterval
    timers[timer] = Task { [time] in
      try? await time.sleep(until: deadline)
      await self.fire(timer)
    }
  }

  /// A timer armed again meanwhile was cancelled, and does not fire.
  private func fire(_ timer: CallTimer) async {
    guard !Task.isCancelled else { return }
    await send(timer.event)
  }

  /// Whether the voice lacks part of the session: it has no summary, a turn is missing from its
  /// conversation, or the session's mod does not post sync lines.
  private func needsContext(_ id: SessionID) async -> Bool {
    if !continuity[id].isCurrent { return true }
    return await !registry.syncs(id)
  }

  /// What the menu says of it: a session whose next line asks for the one thing missing is
  /// offered no press, unless a line is already open, whose ask may have brought nothing. A paused
  /// mark is no gap: all it costs the voice is the summary that line then brings.
  private func contextNeed(_ id: SessionID) async -> ContextNeed {
    guard await needsContext(id) else { return .none }
    let conversation = continuity[id]
    let hasGap = conversation.outOfSync == .missed || conversation.isOverSeed
    let syncs = await registry.syncs(id)
    return !hasGap && syncs && !pauseHoldsBackSummary(of: id) && !lineIsOpen(for: id)
      ? .withTheLine : .load
  }

  /// Starts the attempt that opens the line, in the same turn as the machine's decision to open.
  private func startOpening(preroll: Bool, waits: Bool = true) async {
    lineKnowsSession = false
    await attempt(waits: waits) { await self.openLine(preroll: preroll) }
  }

  /// Whether the pause, the setting or a session's mark, stops the next line asking for a summary,
  /// which is written from the transcript, paused text included (a current mod leaves out tool
  /// output, thinking and reminders, but not text that quotes them). A session with no summary
  /// has its first one asked for all the same, if the owner left `loadsContextOnFirstCall` on.
  private func pauseHoldsBackSummary(of id: SessionID) -> Bool {
    if loadsContextOnFirstCall(), continuity[id].context == nil { return false }
    return pausesSync() || continuity[id].outOfSync == .paused
  }

  /// Opens the line with the target's conversation, and asks the target for its context when it
  /// needs one and may have one. While that session's summary is in flight the line waits, after
  /// the offer and before the seed and the connect (`waitForSummary`). Cancelled, it does nothing
  /// more: whoever cancelled it closes what it opened. A line the voice closed itself
  /// (`CancellationError`) says why in its `closed` event.
  private func openLine(preroll: Bool) async {
    seededContext = nil
    heldContext = nil
    let session = await registry.target
    lineSession = session
    lineKnowsSession = true
    if let session, !pauseHoldsBackSummary(of: session), await needsContext(session) {
      await askForContext(of: session)
    }
    do {
      let voice = try await controller()
      let offer = try await audio.makeOffer(preroll: preroll)
      await waitForSummary()
      try Task.checkCancellation()
      // `lineSession` from here: `/clear` during the awaits gives the session a new id.
      let tasks =
        if let lineSession { await registry.openTasks(of: lineSession) } else { [String]() }
      try Task.checkCancellation()
      // No await from here to `dropSynced()`: a synced line lands in the seed or in the hold,
      // never both, and a stale attempt cannot drop a newer line's hold. Only the session's own
      // conversation, context and open tasks: never another session's.
      let conversation = lineSession.map { continuity[$0] } ?? Conversation()
      let items = conversation.initialItems(
        tasks: tasks, unheard: Set(machine.pending.map(\.text)))
      seededContext = conversation.context
      machine.dropSynced()
      let answer = try await voice.open(offerSDP: offer, items: items)
      try Task.checkCancellation()
      try await audio.applyAnswer(connectsOverTCP() ? AnswerSDP.preferringTCP(answer) : answer)
      try Task.checkCancellation()
      await send(.connected)
      if let held = heldContext, held.session == lineSession, held.text != seededContext,
        machine.phase == .live
      {
        try? await voice.addContext(held.text)
      }
      heldContext = nil
    } catch {
      guard !Task.isCancelled, !(error is CancellationError) else { return }
      if let realtime, (error as? CodexProblem)?.endsCodex == true { await retire(realtime) }
      await audio.closePeer()
      await realtime?.close()  // codex may have opened its side before the page failed
      await send(.connectFailed(Problem(error)))
    }
  }

  /// Holds the opening line while its session's summary is in flight (`SummaryWait`): until the
  /// post that answers the open ask, the limit, the session's drop, a gap or forget that makes the
  /// ask stale, or the line's cancellation. Each change wakes it to look again. An empty answer
  /// (`context(_:)`) and the limit end this call's waits for the session; nothing goes to the
  /// voice meanwhile, as the line is not open and the page queues what is said.
  private func waitForSummary() async {
    while !Task.isCancelled, let id = lineSession {
      let looked = wakes
      guard let ask = continuity.openSummaryAsk(of: id, at: time.now),
        let deadline = summaryWait.deadline(
          for: id, ask: ask, writesSummaries: await registry.writesSummaries(id))
      else { break }
      guard time.now < deadline else {
        summaryWait.endedWithout(id)
        break
      }
      if let wait = lineWait, wait.session == id, wait.ask == ask.at {
        lineWait?.until = nil  // the same ask again, after a reconnect
      } else {
        lineWait = (id, ask.at, time.now, nil)
      }
      await whileLooking()
      if wakes == looked { await sleep(until: deadline) }  // else a change came since it looked
    }
    if lineWait != nil, lineWait?.until == nil { lineWait?.until = time.now }
  }

  /// Returns at `deadline`, at the next `changed()` or when the task is cancelled.
  private func sleep(until deadline: Date) async {
    waits += 1
    let wait = waits
    let timer = Task { [time] in
      guard (try? await time.sleep(until: deadline)) != nil else { return }
      self.wake(wait)
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { waiting[wait] = $0 }
    } onCancel: {
      Task { await self.wake(wait) }
    }
    timer.cancel()
  }

  func whileLooking(_ run: @escaping @Sendable () async -> Void) { whileLooking = run }

  private func wake(_ wait: Int) { waiting.removeValue(forKey: wait)?.resume() }

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
    case .userSpeaking(let words): growing.add(words, from: .owner)
    case .userUtterance(let text):
      growing.finish(.owner, with: text)
      record(.owner, text, in: lineSession)
      await send(.userTranscribed)
    case .assistantSpeaking(let words):
      growing.add(words, from: .voice)
      await send(.assistantSpeaking)
    case .assistantUtterance(let text):
      growing.finish(.voice, with: text)
      record(.voice, text, in: lineSession)
      await send(.assistantFinishedSpeaking(text))
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
    await send(
      .deliver(
        line, opensLine: await opensLine(line),
        onOwnLine: lineKnowsSession && lineSession == line.session))
  }

  /// Whether `line` opens a closed line: an answer, a question or an approval notice from the
  /// target, whose conversation holds a turn of the owner's. A line seeded without one stays
  /// silent (ADR 0001 (b), (n)); an update chimes.
  private func opensLine(_ line: VoiceLine) async -> Bool {
    guard let session = line.session, line.kind.answers || [.asking, .approval].contains(line.kind)
    else { return false }
    let target = await registry.target
    return session == target && continuity[session].lines.contains { $0.speaker == .owner }
  }

  /// A session that left can take no reply: its route ends, and neither its question nor its
  /// approval notice is said. Both stay recorded. A model check it was running gets no answer.
  private func withdrawQuestionsOfDroppedSessions() async {
    for id in await registry.takeDropped() {
      if modelCheck?.session == id { finishCheck(.noAnswer) }
      machine.endQuestionRoute(of: id)
      await withdraw { $0.session == id && ($0.asks || $0.kind == .approval) }
    }
  }

  /// Drops unheard lines; a line opened only for them closes.
  private func withdraw(where isSuperseded: (VoiceLine) -> Bool) async {
    let effects = machine.withdraw(where: isSuperseded)
    for effect in effects { await run(effect) }
    if !effects.isEmpty { await changed() }
  }

  /// A new target closes a line opened with another session's conversation; the next speech
  /// opens it with the target's. The call's first target, and each new one, from the menu, the
  /// band or the registry after a drop, is asked ahead of its line (`askAhead`). With no session
  /// left nobody is there to talk to, so the call stops as Stop does, a Start still launching
  /// codex included, and says why, as Start with no session does.
  private func followTarget() async {
    guard machine.phase != .off || connecting != nil else {
      callTarget = nil
      return
    }
    guard let target = await registry.target else {
      problem = .noSession
      await perform(.stop)
      return
    }
    if machine.phase != .off, target != callTarget {
      callTarget = target
      await askAhead(of: target)
    }
    guard isLineOpen, lineKnowsSession, target != lineSession else { return }
    await send(.conversationChanged)
  }

  /// The pause setting is on and the call is off: what the owner types now stays out.
  private var pausing: Bool { pausesSync() && machine.phase == .off }

  private var isLineOpen: Bool { machine.phase == .connecting || machine.phase == .live }

  private func lineIsOpen(for id: SessionID) -> Bool {
    isLineOpen && lineKnowsSession && lineSession == id
  }

  // MARK: Routing

  /// A handoff goes to the session that asked the last question, else to the target. It
  /// supersedes that session's results the owner has not heard yet, and its brief is kept in
  /// that session's conversation, so the menu shows its queue took it. Returns the session it
  /// went to, or nil when none is joined.
  private func route(_ request: VoiceRequest) async -> SessionID? {
    let route = machine.takeQuestionRoute()
    for id in [route, await registry.target].compactMap({ $0 }) {
      guard (try? await registry.enqueue(request, for: id)) != nil else { continue }
      await withdraw { $0.session == id }
      record(.handoff, request.brief, in: id)
      return id
    }
    return nil
  }

  private func deliver(_ delivery: Delivery) async {
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

  /// A joined session's reading of Claude's usage windows, merged into what is held: a session
  /// that sat idle may report figures older than another's. What is held counts only while it is
  /// current: an expired window takes no slot from a live one. A reset that is not an ISO 8601
  /// time is no reset.
  private func limits(_ body: LimitsBody) async {
    guard (try? await label(of: body.sessionId)) != nil else { return }
    let windows = body.windows.compactMap { one -> LimitWindow? in
      Self.span(ofKind: one.kind).map {
        LimitWindow(
          span: $0, usedPercent: one.percentUsed, resetsAt: one.resetsAt.flatMap(Self.isoDate))
      }
    }
    let reading = UsageLimits(windows: windows, readAt: time.now)
    guard !reading.windows.isEmpty else { return }
    claudeLimits = claudeLimits?.current(at: time.now).merging(reading) ?? reading
  }

  /// The span of a Claude window kind: `five_hour` and `seven_day` are the two lengths the app
  /// names, `spend_limit` is not a usage window, and any other kind shows by name. A kind comes
  /// from the socket and reaches the menu, so only `[a-z0-9_]{1,32}` with a character other than
  /// `_` is accepted.
  static func span(ofKind kind: String) -> LimitSpan? {
    switch kind {
    case "five_hour": return .minutes(LimitSpan.shortMinutes)
    case "seven_day": return .minutes(LimitSpan.aWeek)
    case "spend_limit": return nil
    default:
      let allowed = kind.utf8.allSatisfy {
        ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
      }
      // A kind of only underscores would show as blanks.
      let named = kind.utf8.contains { $0 != 95 }
      return allowed && named && kind.utf8.count <= 32 ? .kind(kind) : nil
    }
  }

  /// An ISO 8601 time, with or without fractional seconds.
  private static func isoDate(_ text: String) -> Date? {
    (try? Date(text, strategy: .iso8601))
      ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
  }

  /// A session that starts waiting for approval sends the voice a notice, which goes once the
  /// approval is settled. A question Claude asked goes to the voice whole, and the next handoff
  /// is routed to that session as its reply. Either carries what Claude wrote before it.
  /// From a turn with no voice request behind it (`turn.request`) in a session that is not the
  /// target, either is context only: kept in its conversation, with no chime and no route. From a
  /// turn refused under the pause, neither is kept or said, and the registry is told of no
  /// question; `working` and `idle` settle what was said before, whatever became of the turn. A
  /// released mod names no turn: it reports only its voice turns, which nothing here refuses.
  private func activity(_ body: ActivityBody) async {
    let id = body.sessionId
    guard let row = try? await label(of: id) else { return }
    var body = body
    var isAdmitted = true
    if body.state == .approval, let turn = body.turn {
      isAdmitted = continuity.admits(turn: turn, kind: .report, in: id, pausing: pausing)
      save()
      if !isAdmitted { body.question = nil }
    }
    await registry.setActivity(body)
    guard isAdmitted else { return }
    switch (row.activity == .approval, body.state == .approval) {
    case (false, true):
      let head = body.question.map(AnswerShaper.prose) ?? "Claude is waiting for your approval"
      let line = AnswerShaper.line(
        body.question == nil ? .approval : .asking, label: row.label,
        body: AnswerShaper.paused(head, wrote: body.text), session: id)
      if let turn = body.turn, turn.request == nil, await registry.target != id {
        record(.claude, line.text, in: id)
        break
      }
      await say(line)
    case (true, false):
      machine.endQuestionRoute(of: id)
      await withdraw { $0.session == body.sessionId && [.approval, .asking].contains($0.kind) }
    default: break
    }
  }

  /// A session's summary, as one redacted line of at most `maxContext` characters, is shown as
  /// it is and kept in the session's conversation. One asked for before the latest gap or forget
  /// is ignored: it would clear a mark it does not cover, or bring back what was forgotten, and the
  /// menu is told of nothing loaded. A post with the number of an ask other than the open one is
  /// such a summary, and leaves the open ask open; one with no number is matched by its time. An
  /// empty one keeps the stored line and closes the ask: a mod that writes summaries sends one when
  /// it has none. The answer to an ask that named a model, if a model was tried, is `lastSummary`.
  /// A line waiting for the summary (`waitForSummary`) is seeded with it; a live line about that
  /// session gets it at once, and one still connecting gets it when connected; it does not hold
  /// the line open. A summary equal to the stored one is not
  /// added again, but it is still the voice's picture as of now, so it clears out-of-sync.
  private func context(_ body: ContextBody) async throws {
    let id = body.sessionId
    let row = try await label(of: id)
    let now = time.now
    let wrote = !body.summary.allSatisfy(\.isWhitespace)
    let failures = body.failures ?? []
    let ask = continuity.openSummaryAsk(of: id, at: now)
    // The line waiting for this ask, if one is.
    var isWaitedFor = false
    if let ask {
      let model = failures.count == 1 && wrote ? ask.fallbackModel : ask.model
      // A post with another ask's number was written for an ask a gap made stale.
      let isOtherAsk = body.ask != nil && body.ask != ask.number
      var waited: TimeInterval?
      if !isOtherAsk, let wait = lineWait, wait.session == id, wait.ask == ask.at {
        waited = (wait.until ?? now).timeIntervalSince(wait.since)
        isWaitedFor = wait.until == nil
        lineWait = nil
      }
      reportsSummary(
        SummaryTiming(
          askedFor: now.timeIntervalSince(ask.at), stale: ask.isStale || isOtherAsk,
          hadSummary: wrote, model: model, stats: body.stats, waited: waited))
    }
    // The waiting line looks again at the `changed()` after every post, this one ignored or not.
    guard continuity.takeSummaryAsk(of: id, at: now, number: body.ask) else { return }
    if isWaitedFor, !wrote { summaryWait.endedWithout(id) }
    // An answer on which no model was tried leaves Settings' line as it was.
    if let asked = ask?.model, wrote || !failures.isEmpty {
      lastSummary = SummaryReport(
        asked: asked, fallback: ask?.fallbackModel, failures: failures, wrote: wrote)
    }
    let line =
      wrote
      ? AnswerShaper.line(
        .context, label: row.label, body: body.summary, limit: Self.maxContext, session: id)
      : nil
    guard let line else {
      announceContext.yield(ContextArrival(session: id, wrote: false))
      return
    }
    let isNew = line.text != continuity[id].context
    continuity.setContext(line.text, for: id)
    save()
    announceContext.yield(ContextArrival(session: id, wrote: true))
    guard isNew, lineSession == id else { return }
    switch machine.phase {
    case .live: try? await realtime?.addContext(line.text)
    case .connecting: heldContext = line
    default: break
    }
  }

  /// A line of a turn. It is kept in its session's conversation if `Continuity.admits` takes it
  /// (the pause setting with the call off refuses it, and marks the session paused); the open line
  /// about that session is given it at once, as context. A `typed` line refused in a turn with a
  /// voice request behind it withholds exactly that request.
  private func sync(_ body: SyncBody) async throws {
    let id = body.sessionId
    let row = try await label(of: id)
    let admitted = continuity.admits(turn: body.turn, kind: body.kind, in: id, pausing: pausing)
    if !admitted, body.kind == .typed, let request = body.turn.request {
      await registry.withholdAnswer(request, of: id)
    }
    guard admitted, await addSynced(body.text ?? "", kind: body.kind, of: row) else {
      save()  // the turn's decision persists, a `start`'s included
      return
    }
  }

  /// A newer request superseded this answer, so it is not said, and the mod, told 200, notes no
  /// gap. So it is kept as Claude's synced line, unless it is a failure, which holds no answer.
  /// `SessionRegistry.complete` has already dropped one whose request is withheld.
  private func keepSuperseded(_ body: AnswerBody) async {
    guard body.status != .failed, let row = try? await label(of: body.sessionId) else { return }
    await addSynced(body.text, kind: .answer, of: row)
  }

  /// Keeps a line of a turn in its session's conversation, as the owner's if it is typed; the open
  /// line about that session is given it at once, as context. False, and nothing saved, when it
  /// has nothing to say.
  @discardableResult
  private func addSynced(_ text: String, kind: SyncKind, of row: SessionRow) async -> Bool {
    let id = row.sessionId
    guard let line = AnswerShaper.synced(text, kind: kind, label: row.label, session: id) else {
      return false
    }
    record(line.kind == .typed ? .owner : .claude, line.text, in: id)
    if lineKnowsSession, lineSession == id { await send(.synced(line)) }
    return true
  }

  private func sweep() async {
    for delivery in await registry.sweep() { await deliver(delivery) }
    await changed()
  }

  /// Publishes the status if it changed; every change of the target passes through here.
  /// Two changes can interleave across the awaits, so only the latest one publishes: an older
  /// one finishing last would show the status from before the newer change.
  @discardableResult private func changed() async -> StatusReply {
    for wait in waiting.values { wait.resume() }  // a waiting line looks again
    waiting = [:]
    wakes += 1
    await withdrawQuestionsOfDroppedSessions()
    await followTarget()
    if !isLineOpen { growing = GrowingLines() }  // no final text comes for what a closed line said
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
  /// The target's whole conversation, oldest first: every line the app keeps, a summary no kept
  /// line holds, and the lines the open line is still saying.
  public let conversation: [Conversation.Line]
  /// The joined sessions whose mod is older than the app, or names no version, by label.
  public let labelsOnAnOlderMod: [String]
  /// Whether Load context has something to do for the target.
  public let contextNeed: ContextNeed
  /// What Claude Code last said of Claude's usage windows; nil until a session has.
  public var claudeLimits: UsageLimits? = nil
  /// What came of the last summary asked for with a model, for Settings.
  public var lastSummary: SummaryReport? = nil
  /// The joined sessions whose summary is on its way (`Bridge.summariesInFlight`).
  public var summariesInFlight: Set<SessionID> = []
}
