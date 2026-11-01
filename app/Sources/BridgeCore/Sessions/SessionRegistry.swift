import Foundation

/// What the voice should say about a session's request, under the session's label.
public struct Delivery: Sendable, Equatable {
  public var session: SessionID
  public var label: String
  public var status: AnswerStatus
  public var text: String
}

public enum RegistryError: Error, Equatable {
  case unknownSession(SessionID)
  /// The id is not this session's open request (or, for an `update`, its latest one).
  case unknownRequest(RequestID)
  /// The owner removed the session in the menu; it is told so until it joins again.
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
/// after the previous one completed. A newer request supersedes the answer of an older one,
/// which is then not delivered. A session that stops polling for 5 s is dropped and its open
/// request fails; a request in flight for 10 minutes fails too. Exactly one
/// session is the target while any is joined.
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
    var wantsContext = false

    var hasOpenRequest: Bool { inFlight != nil || !queued.isEmpty }
  }

  private let time: any TimeSource
  private static let sessionExpiry: TimeInterval = 5
  private static let requestTimeout: TimeInterval = 600
  private var sessions: [SessionID: Session] = [:]
  /// Sessions the owner removed that have not joined since.
  private var removed: Set<SessionID> = []
  private var joins = 0
  private var lastSweep: Date?
  /// A longer gap between sweeps means the Mac slept, not that every mod went quiet.
  private static let sleepGap: TimeInterval = 3
  /// The longest title kept; the label, the band and every voice line carry it.
  public static let maxTitle = 80
  public private(set) var target: SessionID?
  /// The app's setting: a session that becomes the target is asked for its summary. A join from
  /// an older mod may still carry an `autoContext` flag; decoding drops it.
  public private(set) var autoContext = false

  public init(time: any TimeSource, autoContext: Bool = false) {
    self.time = time
    self.autoContext = autoContext
  }

  /// Adds the session, or renames it and refreshes its liveness if it already joined. A session
  /// that `replaces` an id takes over that id's place, target and requests.
  public func join(_ body: JoinBody) {
    removed.remove(body.sessionId)
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

  /// The owner removed the session: like `leave`, and until it joins again every call from it
  /// throws `removedSession`, so the mod stops instead of joining again.
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
      session.queued.append(request)
      session.latest = request.id
    }
  }

  /// The session's next work, if any; every poll refreshes its liveness.
  public func poll(_ id: SessionID) throws -> Work? {
    let now = time.now
    return try update(id) { session in
      session.lastPoll = now
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

  /// Asks the session for its context summary at its next poll.
  public func requestContext(for id: SessionID) { sessions[id]?.wantsContext = true }

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

  public func setActivity(_ body: ActivityBody) { sessions[body.sessionId]?.activity = body.state }

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
      } else if let flight = session.inFlight,
        now.timeIntervalSince(flight.since) >= Self.requestTimeout
      {
        sessions[id]?.inFlight = nil
        if session.latest == flight.id, let label = labels[id] {
          deliveries.append(
            Delivery(session: id, label: label, status: .failed, text: "timed out"))
        }
      }
    }
    return deliveries
  }

  /// The requests not answered yet, as `[TASK] <label>: <brief>` lines for the voice; an
  /// older request a newer one superseded is left out. Given a session, only its own.
  public func openTasks(of only: SessionID? = nil) -> [String] {
    let labels = labels()
    return ordered().filter { only == nil || $0.key == only }.flatMap { id, session in
      let briefs =
        (session.inFlight.map { $0.id == session.latest ? [$0.brief] : [] } ?? [])
        + session.queued.map(\.brief)
      return briefs.map { AnswerShaper.line(tag: "TASK", label: labels[id] ?? "", body: $0) }
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

  public func setAutoContext(_ on: Bool) { autoContext = on }

  /// Makes `id` the target; with `autoContext` on it is asked for its summary.
  private func retarget(_ id: SessionID?) {
    target = id
    if let id, autoContext { sessions[id]?.wantsContext = true }
  }

  private func drop(_ id: SessionID, labels: [SessionID: String], reason: String) -> Delivery? {
    guard let session = sessions.removeValue(forKey: id) else { return nil }
    if target == id { retarget(ordered().last?.key) }
    guard session.hasOpenRequest, let label = labels[id] else { return nil }
    return Delivery(session: id, label: label, status: .failed, text: reason)
  }
}
