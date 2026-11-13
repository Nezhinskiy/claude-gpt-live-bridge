import Foundation

/// How a session's summary shows in the menu: on its way, or the last one taken and when.
public enum SummaryDisplay: Sendable, Equatable {
  case none, loading
  case loaded(at: Date)
}

/// What a summary post is to the session's asks (`SummaryAsks.answer`).
enum SummaryAnswer: Equatable {
  /// It answers the open, current ask; `waited`: how long a line waited for it, if one did.
  case taken(SummaryAsks.Ask, waited: TimeInterval?)
  /// It answers the open ask, asked for before the latest gap or forget, so it is ignored.
  case stale(SummaryAsks.Ask, waited: TimeInterval?)
  /// It carries the number of another ask than the open one: ignored, and the open ask stays open.
  case otherAsk
  /// It carries a number and no ask is open: it answers one already closed, and is ignored.
  case closedAsk
  /// No ask is open and it names none: an older mod's `/live context`, undated, and taken.
  case unasked

  var isTaken: Bool {
    switch self {
    case .taken, .unasked: true
    case .stale, .otherAsk, .closedAsk: false
    }
  }
}

/// Every rule about summary asks: which ask is open and its number, which post answers it, how long
/// a line waits for it, and what the menu shows. The asks are kept in `Continuity`, so they outlive
/// a restart; the waits and what was loaded are in memory. Pure: the caller passes the time.
struct SummaryAsks: Sendable {
  typealias Ask = Conversation.SummaryAsk

  enum Policy {
    /// The mod's budget for a summary (`CONTEXT_TIMEOUT_MS`): a numbered ask is answered within it
    /// or not at all.
    static let modBudget: TimeInterval = 60
    /// How long an ask can still be answered: an older mod may never answer.
    static let answerable: TimeInterval = 2 * modBudget
    /// The wait's limit, from the ask; the spec's "The time limit" says how it was set.
    static let waitLimit: TimeInterval = 10
    static let shownLoaded: TimeInterval = 3
  }

  enum AskResult: Equatable {
    case new(Ask)
    case joined(Ask)

    var ask: Ask {
      switch self {
      case .new(let ask), .joined(let ask): ask
      }
    }
  }

  /// The sessions whose wait is spent this call: an answer with no summary, or a line that waited
  /// until the limit.
  private var spent: Set<SessionID> = []
  /// The line's latest wait, for the log: the session, its ask's number, when the wait began, and
  /// when it ended if the answer did not end it.
  private var wait: (session: SessionID, number: Int, began: Date, ended: Date?)?
  /// When each session's last summary with text was taken.
  private var lastLoaded: [SessionID: Date] = [:]

  /// The ask of `id` that can still be answered at `now`, without taking it.
  func openAsk(of id: SessionID, in continuity: Continuity, at now: Date) -> Ask? {
    continuity[id].summaryAsk.flatMap { now < $0.at + Policy.answerable ? $0 : nil }
  }

  /// `id` is asked for a summary, naming `model` and `fallback` if its mod writes summaries. An open
  /// ask is joined, as the mod joins the summary on its way, unless a named ask finds it stale or
  /// unnumbered and replaces it. A new named ask takes the next number, which only grows.
  @discardableResult
  func ask(
    _ id: SessionID, in continuity: inout Continuity, at now: Date, model: String?,
    fallback: String?
  ) -> AskResult {
    let next = (continuity.asksMade ?? 0) + 1
    let open = openAsk(of: id, in: continuity, at: now)
    let result = continuity.changeSummaryAsk(of: id) { record -> AskResult in
      if let open, model == nil || (!open.isStale && open.number != nil) { return .joined(open) }
      let ask = Ask(
        at: now, model: model, fallbackModel: fallback, number: model == nil ? nil : next)
      record = ask
      return .new(ask)
    }
    if result.ask.number == next { continuity.asksMade = next }
    return result
  }

  /// A line of `id` looks at `now`: it sleeps until the deadline this returns, or opens on nil. It
  /// waits for an open, current, numbered ask, until the limit from the ask, unless the session's
  /// wait is spent this call. A line that waited until the limit spends it; one that comes after
  /// the limit does not. For the same ask again, after a reconnect, the wait keeps its start.
  mutating func wait(_ id: SessionID, in continuity: Continuity, at now: Date) -> Date? {
    guard let ask = openAsk(of: id, in: continuity, at: now), let number = ask.number,
      !ask.isStale, !spent.contains(id)
    else { return nil }
    let deadline = ask.at + Policy.waitLimit
    let isWaiting = wait.map { $0.session == id && $0.number == number } ?? false
    guard now < deadline else {
      if isWaiting, wait?.ended == nil { spent.insert(id) }
      return nil
    }
    if isWaiting { wait?.ended = nil } else { wait = (id, number, now, nil) }
    return deadline
  }

  /// The line stopped waiting before the answer came.
  mutating func endWait(at now: Date) { if wait?.ended == nil { wait?.ended = now } }

  /// The call started: every session may be waited for again.
  mutating func newCall() { spent = [] }

  /// A summary post from `id`, with the ask's `number` if the mod echoes one; `wrote` is false for
  /// an empty one. A post for another ask leaves the open ask open; any other closes it. An empty
  /// answer to the open, current ask spends the session's wait for the call.
  mutating func answer(
    _ id: SessionID, number: Int?, wrote: Bool, in continuity: inout Continuity, at now: Date
  ) -> SummaryAnswer {
    let open = openAsk(of: id, in: continuity, at: now)
    let isOtherAsk = number != nil && open?.number != number
    continuity.changeSummaryAsk(of: id) { if !isOtherAsk { $0 = nil } }
    if isOtherAsk { return open == nil ? .closedAsk : .otherAsk }
    guard let open else {
      lastLoaded[id] = wrote ? now : nil
      return .unasked
    }
    var waited: TimeInterval?
    if let wait, wait.session == id, wait.number == open.number {
      waited = (wait.ended ?? now).timeIntervalSince(wait.began)
      self.wait = nil
    }
    if open.isStale { return .stale(open, waited: waited) }
    if !wrote { spent.insert(id) }
    lastLoaded[id] = wrote ? now : nil
    return .taken(open, waited: waited)
  }

  /// Loading while an open ask to a mod that writes summaries is current and within the mod's
  /// budget, whatever made it; else the last summary taken, if it had text.
  func display(of id: SessionID, in continuity: Continuity, at now: Date) -> SummaryDisplay {
    if let ask = openAsk(of: id, in: continuity, at: now), !ask.isStale, ask.number != nil,
      now < ask.at + Policy.modBudget
    {
      return .loading
    }
    return lastLoaded[id].map { .loaded(at: $0) } ?? .none
  }

  /// Forgets what was loaded for the sessions not in `ids`: they left or were removed.
  mutating func keep(only ids: Set<SessionID>) {
    lastLoaded = lastLoaded.filter { ids.contains($0.key) }
  }
}
