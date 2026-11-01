import Foundation

/// What the voice should say about a session's request, under the session's label.
public struct Delivery: Sendable, Equatable {
  public var label: String
  public var status: AnswerStatus
  public var text: String
}

public enum RegistryError: Error, Equatable {
  case unknownSession(SessionID)
  /// The id is not this session's open request (or, for an `update`, its latest one).
  case unknownRequest(RequestID)

  public var message: String {
    switch self {
    case .unknownSession: "unknown session"
    case .unknownRequest: "unknown or stale request id"
    }
  }

  /// The status the HTTP route answers with.
  public var httpStatus: Int {
    switch self {
    case .unknownSession: 404
    case .unknownRequest: 409
    }
  }
}

/// The sessions that joined the call, their requests and their liveness.
///
/// Each session has at most one request in flight: `poll` hands out the next queued request only
/// after the previous one completed. A newer request supersedes the answer of an older one,
/// which is then not delivered. A session that stops polling for `sessionExpiry` is dropped and
/// its open request fails; a request in flight for `requestTimeout` fails too. Exactly one
/// session is the target while any is joined.
public actor SessionRegistry {
  private struct Session {
    let joinOrder: Int
    var title = ""
    var autoContext = false
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
  private let sessionExpiry: TimeInterval
  private let requestTimeout: TimeInterval
  private var sessions: [SessionID: Session] = [:]
  private var joins = 0
  public private(set) var target: SessionID?

  public init(
    time: any TimeSource, sessionExpiry: Duration = .seconds(5),
    requestTimeout: Duration = .seconds(600)
  ) {
    self.time = time
    self.sessionExpiry = sessionExpiry.timeInterval
    self.requestTimeout = requestTimeout.timeInterval
  }

  /// Adds the session, or renames it and refreshes its liveness if it already joined.
  public func join(_ body: JoinBody) {
    var session = sessions[body.sessionId] ?? Session(joinOrder: joins, lastPoll: time.now)
    joins += 1
    session.title = body.title
    session.autoContext = body.autoContext
    session.lastPoll = time.now
    sessions[body.sessionId] = session
    if target == nil { retarget(body.sessionId) }
  }

  /// Removes the session; an open request it leaves behind is reported as failed.
  @discardableResult public func leave(_ id: SessionID) -> Delivery? {
    drop(id, labels: labels(), reason: "session left")
  }

  public func setTarget(_ id: SessionID) throws {
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
      return Delivery(label: label, status: answer.status, text: text)
    }
  }

  public func setActivity(_ body: ActivityBody) { sessions[body.sessionId]?.activity = body.state }

  /// Drops sessions that stopped polling and fails requests in flight too long. Run every second.
  public func sweep() -> [Delivery] {
    let now = time.now
    let labels = labels()
    var deliveries: [Delivery] = []
    for (id, session) in ordered() {
      if now.timeIntervalSince(session.lastPoll) >= sessionExpiry {
        deliveries += [drop(id, labels: labels, reason: "session closed")].compactMap { $0 }
      } else if let flight = session.inFlight,
        now.timeIntervalSince(flight.since) >= requestTimeout
      {
        sessions[id]?.inFlight = nil
        if session.latest == flight.id, let label = labels[id] {
          deliveries.append(Delivery(label: label, status: .failed, text: "timed out"))
        }
      }
    }
    return deliveries
  }

  /// The requests not answered yet, as `[TASK] <label>: <brief>` lines for the voice; an
  /// older request a newer one superseded is left out.
  public func openTasks() -> [String] {
    let labels = labels()
    return ordered().flatMap { id, session in
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
    guard var session = sessions[id] else { throw RegistryError.unknownSession(id) }
    defer { sessions[id] = session }
    return try change(&session)
  }

  /// Makes `id` the target; a session with `autoContext` is asked for its summary.
  private func retarget(_ id: SessionID?) {
    target = id
    if let id, sessions[id]?.autoContext == true { sessions[id]?.wantsContext = true }
  }

  private func drop(_ id: SessionID, labels: [SessionID: String], reason: String) -> Delivery? {
    guard let session = sessions.removeValue(forKey: id) else { return nil }
    if target == id { retarget(ordered().last?.key) }
    guard session.hasOpenRequest, let label = labels[id] else { return nil }
    return Delivery(label: label, status: .failed, text: reason)
  }
}
