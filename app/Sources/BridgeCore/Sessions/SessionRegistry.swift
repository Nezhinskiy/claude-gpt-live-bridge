import Foundation

/// What the voice should say about a session's request, under the session's label.
public struct Delivery: Sendable, Equatable {
  public var session: SessionID
  public var label: String
  public var status: AnswerStatus
  public var text: String
  /// It answers the voice's fetch of the session's context, not a request.
  public var isFetch = false
}

public enum RegistryError: Error, Equatable {
  case unknownSession(SessionID)
  /// The id is not this session's open request (or, for an `update`, its latest one).
  case unknownRequest(RequestID)
  /// The owner removed the session in the menu; it is told so until the owner joins it again.
  case removedSession(SessionID)

  public var message: String {
    switch self {
    case .unknownSession: "unknown session"
    case .unknownRequest: "unknown or stale request id"
    case .removedSession: "this session was removed from LiveBridge"
    }
  }

  /// The status the HTTP route answers with.
  public var httpStatus: Int {
    switch self {
    case .unknownSession: 404
    case .unknownRequest: 409
    case .removedSession: 410
    }
  }

  /// The wire's code for an error the mod acts on.
  public var code: ErrorCode? { if case .removedSession = self { .removed } else { nil } }
}

/// The sessions that joined the call, their requests and their liveness.
///
/// Each session has at most one request in flight: `poll` hands out the next queued request only
/// after the previous one completed. While Claude waits on a question it asked the owner, the
/// next request is that question's reply instead: it goes out at once, for the request in
/// flight, and supersedes nothing. A newer request supersedes the answer of an older one,
/// which is then not delivered. A session that stops polling for 5 s is dropped and its open
/// request fails; a request in flight for 10 minutes fails too, and so does the voice's fetch of
/// a session's context at its deadline. Exactly one session is the target while any is joined.
public actor SessionRegistry {
  private struct Session {
    let joinOrder: Int
    var title = ""
    var lastPoll: Date
    var activity = SessionActivity.idle
    var queued: [VoiceRequest] = []
    var inFlight: (id: RequestID, brief: String, since: Date)?
    /// The newest request enqueued; only its answers are delivered.
    var latest: RequestID?
    /// Claude waits on a question it asked the owner in the request in flight.
    var isAsking = false
    /// The owner's reply to that question, until the session polls it.
    var reply: VoiceRequest?
    var wantsContext = false
    /// The deadline of the voice's fetch of the context, until the context arrives.
    var fetchDue: Date?

    var hasOpenRequest: Bool { inFlight != nil || !queued.isEmpty }
  }

  private let time: any TimeSource
  private static let sessionExpiry: TimeInterval = 5
  private static let requestTimeout: TimeInterval = 600
  private var sessions: [SessionID: Session] = [:]
  /// Sessions the owner removed that the owner has not joined again since.
  private var removed: Set<SessionID> = []
  private var joins = 0
  private var lastSweep: Date?
  /// A longer gap between sweeps means the Mac slept, not that every mod went quiet.
  private static let sleepGap: TimeInterval = 3
  /// The longest title kept; the label, the band and every voice line carry it.
  public static let maxTitle = 80
  public private(set) var target: SessionID?
  public init(time: any TimeSource) {
    self.time = time
  }

  /// Adds the session, or renames it and refreshes its liveness if it already joined. A session
  /// that `replaces` an id takes over that id's place, target and requests. A removed session
  /// joins again only when the owner asks (`owner`); the mod's own joins, such as following a
  /// new title, throw `removedSession`.
  public func join(_ body: JoinBody) throws {
    if removed.contains(body.sessionId) {
      guard body.owner == true else { throw RegistryError.removedSession(body.sessionId) }
      removed.remove(body.sessionId)
    }
    let replaced = body.replaces.flatMap { sessions.removeValue(forKey: $0) }
    if replaced != nil, target == body.replaces { target = body.sessionId }
    var session =
      sessions[body.sessionId] ?? replaced ?? Session(joinOrder: joins, lastPoll: time.now)
    joins += 1
    session.title = String(body.title.prefix(Self.maxTitle))
    session.lastPoll = time.now
    sessions[body.sessionId] = session
    if target == nil { retarget(body.sessionId) }
  }

  /// Removes the session; an open request it leaves behind is reported as failed.
  @discardableResult public func leave(_ id: SessionID) -> Delivery? {
    drop(id, labels: labels(), reason: "session left")
  }

  /// The owner removed the session: like `leave`, and until the owner joins it again every call
  /// from it throws `removedSession`, so the mod stops instead of joining again.
  @discardableResult public func remove(_ id: SessionID) -> Delivery? {
    guard sessions[id] != nil else { return nil }
    removed.insert(id)
    return leave(id)
  }

  public func setTarget(_ id: SessionID) throws {
    if removed.contains(id) { throw RegistryError.removedSession(id) }
    guard sessions[id] != nil else { throw RegistryError.unknownSession(id) }
    retarget(id)
  }

  public func enqueue(_ request: VoiceRequest, for id: SessionID) throws {
    try update(id) { session in
      if session.isAsking, session.reply == nil {
        session.reply = request
      } else {
        session.queued.append(request)
        session.latest = request.id
      }
    }
  }

  /// The session's next work, if any; every poll refreshes its liveness.
  public func poll(_ id: SessionID) throws -> Work? {
    let now = time.now
    return try update(id) { session in
      session.lastPoll = now
      if let reply = session.reply {
        session.reply = nil
        session.isAsking = false
        return .reply(reply)
      }
      if session.inFlight == nil, !session.queued.isEmpty {
        let request = session.queued.removeFirst()
        session.inFlight = (request.id, request.brief, now)
        return .request(request)
      }
      guard session.wantsContext else { return nil }
      session.wantsContext = false
      return .context
    }
  }

  /// What a fetch that got no context says.
  static let fetchFailure = "context not available"

  /// Asks the session for its context summary at its next poll. With `fetch`, the voice asked
  /// for it, and its fetch fails at that deadline unless the context arrives first; a later
  /// fetch moves the deadline.
  public func requestContext(for id: SessionID, fetch: Date?) {
    sessions[id]?.wantsContext = true
    if let fetch { sessions[id]?.fetchDue = fetch }
  }

  /// The session's context arrived: whether it answers a fetch, which then ends.
  public func endFetch(of id: SessionID) -> Bool {
    sessions[id]?.fetchDue.take() != nil
  }

  /// Records an answer. `ok`, `failed` and `question` close the request in flight; `update`
  /// closes nothing. Returns `nil` when a newer request superseded this one.
  public func complete(_ answer: AnswerBody) throws -> Delivery? {
    let label = labels()[answer.sessionId]
    return try update(answer.sessionId) { session in
      let isInFlight = session.inFlight?.id == answer.id
      if answer.status == .update {
        guard isInFlight || session.latest == answer.id else {
          throw RegistryError.unknownRequest(answer.id)
        }
      } else {
        guard isInFlight else { throw RegistryError.unknownRequest(answer.id) }
        session.inFlight = nil
      }
      guard session.latest == answer.id, let label else { return nil }
      let text = answer.text.isEmpty ? answer.reason ?? "" : answer.text
      return Delivery(session: answer.sessionId, label: label, status: answer.status, text: text)
    }
  }

  /// A question settled before its reply went out (answered in Claude Code) leaves the reply
  /// to go as a request of its own.
  public func setActivity(_ body: ActivityBody) {
    guard var session = sessions[body.sessionId] else { return }
    defer { sessions[body.sessionId] = session }
    session.activity = body.state
    session.isAsking = body.state == .approval && body.question != nil
    guard !session.isAsking, let reply = session.reply else { return }
    session.reply = nil
    session.queued.append(reply)
    session.latest = reply.id
  }

  /// Drops sessions that stopped polling and fails requests in flight too long. Run every second;
  /// after a sleep, liveness starts again and request clocks skip the time asleep.
  public func sweep() -> [Delivery] {
    let now = time.now
    defer { lastSweep = now }
    if let lastSweep, case let gap = now.timeIntervalSince(lastSweep), gap > Self.sleepGap {
      for id in sessions.keys {
        sessions[id]?.lastPoll = now
        sessions[id]?.inFlight?.since += gap
      }
      return []
    }
    let labels = labels()
    var deliveries: [Delivery] = []
    for (id, session) in ordered() {
      if now.timeIntervalSince(session.lastPoll) >= Self.sessionExpiry {
        deliveries += [drop(id, labels: labels, reason: "session closed")].compactMap { $0 }
        continue
      }
      if let flight = session.inFlight, now.timeIntervalSince(flight.since) >= Self.requestTimeout {
        sessions[id]?.inFlight = nil
        if session.latest == flight.id, let label = labels[id] {
          deliveries.append(
            Delivery(session: id, label: label, status: .failed, text: "timed out"))
        }
      }
      if let due = session.fetchDue, now >= due, let label = labels[id] {
        sessions[id]?.fetchDue = nil
        deliveries.append(
          Delivery(
            session: id, label: label, status: .failed, text: Self.fetchFailure, isFetch: true))
      }
    }
    return deliveries
  }

  /// Whether any session has a request queued or in flight.
  public var hasOpenRequests: Bool { sessions.values.contains { $0.hasOpenRequest } }

  /// The requests not answered yet, as `[TASK] <label>: <brief>` lines for the voice; an
  /// older request a newer one superseded is left out. Given a session, only its own.
  public func openTasks(of only: SessionID? = nil) -> [String] {
    let labels = labels()
    return ordered().filter { only == nil || $0.key == only }.flatMap { id, session in
      let briefs =
        (session.inFlight.map { $0.id == session.latest ? [$0.brief] : [] } ?? [])
        + session.queued.map(\.brief)
      return briefs.map { AnswerShaper.line(.task, label: labels[id] ?? "", body: $0).text }
    }
  }

  /// The sessions in the order they joined.
  public func rows() -> [SessionRow] {
    let labels = labels()
    return ordered().map { id, session in
      SessionRow(
        sessionId: id, label: labels[id] ?? session.title, activity: session.activity,
        isTarget: id == target)
    }
  }

  private func ordered() -> [(key: SessionID, value: Session)] {
    sessions.sorted { $0.value.joinOrder < $1.value.joinOrder }
  }

  private func labels() -> [SessionID: String] {
    Labels.disambiguate(sessions.map { ($0.key, $0.value.title) })
  }

  private func update<T>(_ id: SessionID, _ change: (inout Session) throws -> T) throws -> T {
    if removed.contains(id) { throw RegistryError.removedSession(id) }
    guard var session = sessions[id] else { throw RegistryError.unknownSession(id) }
    defer { sessions[id] = session }
    return try change(&session)
  }

  private func retarget(_ id: SessionID?) { target = id }

  private func drop(_ id: SessionID, labels: [SessionID: String], reason: String) -> Delivery? {
    guard let session = sessions.removeValue(forKey: id) else { return nil }
    if target == id { retarget(ordered().last?.key) }
    guard session.hasOpenRequest, let label = labels[id] else { return nil }
    return Delivery(session: id, label: label, status: .failed, text: reason)
  }
}
