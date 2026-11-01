import Foundation

/// The bridge: serves the mod's routes, runs the call machine's effects in order, and routes
/// handoffs to sessions and their answers back to the voice.
public actor Bridge: Router {
  public static let maxContext = 1500
  /// Why Start did nothing: there is no session to talk to.
  public static let noSession =
    "No Claude Code session has joined: run /voice on in a session, then start."

  private let registry: SessionRegistry
  private let makeRealtime: @Sendable () async throws -> any RealtimeControlling
  private let audio: any AudioSide
  private let meter: UsageMeterStore
  private let continuityFile: URL
  private let time: any TimeSource
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
  private var continuity: Continuity
  private var problem: String?
  /// The session that asked the last `[QUESTION]`; the next handoff goes there.
  private var questionRoute: SessionID?
  private var callStart: Date?
  /// The status last published, so an unchanged one is not published again.
  private var published: StatusReply?
  public nonisolated let updates: AsyncStream<StatusReply>
  private let publish: AsyncStream<StatusReply>.Continuation

  /// `realtime` makes the codex side of a call; it is called at Start, and again after codex
  /// stopped. Sessions are swept every second.
  public init(
    registry: SessionRegistry,
    realtime: @escaping @Sendable () async throws -> any RealtimeControlling, audio: any AudioSide,
    meter: UsageMeterStore, continuityFile: URL, time: any TimeSource
  ) {
    self.registry = registry
    makeRealtime = realtime
    self.audio = audio
    self.meter = meter
    self.continuityFile = continuityFile
    self.time = time
    continuity =
      (try? JSONDecoder().decode(Continuity.self, from: Data(contentsOf: continuityFile)))
      ?? Continuity()
    (updates, publish) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    Task { [weak self] in
      while (try? await time.sleep(for: .seconds(1))) != nil, let bridge = self {
        await bridge.sweep()
      }
    }
  }

  public var status: StatusReply {
    get async {
      let minutesThisCall = if let callStart { await meter.minutes(since: callStart) } else { 0.0 }
      return StatusReply(
        call: machine.phase, sessions: await registry.rows(),
        minutesToday: await meter.minutesToday(), minutesThisCall: minutesThisCall,
        problem: problem, lastContext: continuity.context,
        recentTranscript: continuity.utterances.suffix(3).map {
          ($0.role == .user ? "You: " : "Voice: ") + $0.text
        }, unheard: machine.pending.count)
    }
  }

  public func perform(_ action: CallAction) async {
    switch action {
    case .start:
      guard machine.phase == .off, !starting else { return }
      guard await registry.target != nil else {
        problem = Self.noSession
        await changed()
        return
      }
      starting = true
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
  public func loadContext() async {
    if let target = await registry.target { await registry.requestContext(for: target) }
  }

  /// The popover's choice of target, which also ends a question's route; a session that left is
  /// ignored.
  public func setTarget(_ id: SessionID) async {
    questionRoute = nil
    try? await registry.setTarget(id)
    await changed()
  }

  /// Forgets the conversation; the next realtime session starts fresh.
  public func newConversation() async {
    continuity = Continuity()
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
        await registry.join(try req.decodeBody(JoinBody.self))
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
      return .error(error.httpStatus, error.message)
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
    case .armSilenceTimer(let seconds):
      silenceTimer += 1
      let timer = silenceTimer
      Task { [time] in
        try? await time.sleep(for: .seconds(seconds))
        await self.silenceElapsed(timer)
      }
    case .chime: await audio.chime()
    case .problem(let sentence): problem = sentence
    }
  }

  private func silenceElapsed(_ timer: Int) async {
    if timer == silenceTimer { await send(.silenceElapsed) }
  }

  private func openRealtime() async {
    opening += 1
    let attempt = opening
    do {
      let voice = try await controller()
      let offer = try await audio.makeOffer()
      let items = continuity.initialItems(tasks: await registry.openTasks())
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
    let made = try await makeRealtime()
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
      await send(.handedOff)
      await route(request)
    case .userUtterance(let text):
      record(.user, text)
      await send(.userTranscribed)
    case .assistantUtterance(let text):
      record(.assistant, text)
      await send(.assistantFinishedSpeaking(text))
    case .assistantSpeaking: await send(.assistantSpeaking)
    case .closed(let reason):
      opening += 1
      await audio.closePeer()
      await send(.remoteClosed(reason))
    }
    await changed()
  }

  private func record(_ role: Role, _ text: String) {
    guard !text.isEmpty else { return }
    continuity.record(Utterance(role: role, text: text))
    save()
  }

  // MARK: Routing

  /// A handoff goes to the session that asked the last question, else to the target. It
  /// supersedes that session's results the owner has not heard yet.
  private func route(_ request: VoiceRequest) async {
    let route = questionRoute
    questionRoute = nil
    for id in [route, await registry.target].compactMap({ $0 }) {
      guard (try? await registry.enqueue(request, for: id)) != nil else { continue }
      machine.withdraw { $0.session == id }
      return
    }
    let line = AnswerShaper.line(
      tag: "FAILED", label: "LiveBridge", body: "no Claude Code session is joined.")
    await send(.deliver(VoiceLine(text: line)))
  }

  private func deliver(_ delivery: Delivery) async {
    // only a question the call keeps (not one dropped while off) routes the next handoff
    if delivery.status == .question, machine.phase != .off { questionRoute = delivery.session }
    let line = AnswerShaper.forVoice(delivery.text, status: delivery.status, label: delivery.label)
    await send(.deliver(VoiceLine(text: line, session: delivery.session)))
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
      await send(.deliver(VoiceLine(text: line, session: body.sessionId)))
    case (true, false):
      machine.withdraw { $0.session == body.sessionId && $0.text.hasPrefix("[APPROVAL]") }
    default: break
    }
  }

  /// A session's summary, as one redacted line of at most `maxContext` characters, is shown as
  /// it is and kept for later sessions; a live voice gets it at once, and it does not hold the
  /// line open.
  private func context(_ body: ContextBody) async throws {
    let row = try await label(of: body.sessionId)
    let line = AnswerShaper.line(
      tag: "CONTEXT", label: row.label, body: body.summary, limit: Self.maxContext)
    continuity.context = line
    save()
    if machine.phase == .live { try? await realtime?.addContext(line) }
  }

  private func sweep() async {
    for delivery in await registry.sweep() { await deliver(delivery) }
    await changed()
  }

  @discardableResult private func changed() async -> StatusReply {
    let now = await status
    if now != published { publish.yield(now) }
    published = now
    return now
  }

  private func save() {
    try? JSONEncoder().encode(continuity).write(to: continuityFile, options: .atomic)
  }

  private static func sentence(_ error: any Error) -> String { error.localizedDescription }
}
