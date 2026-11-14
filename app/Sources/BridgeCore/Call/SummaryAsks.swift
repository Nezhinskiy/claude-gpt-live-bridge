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

  /// The open ask it closed, taken or stale.
  var closed: SummaryAsks.Ask? {
    switch self {
    case .taken(let ask, _), .stale(let ask, _): ask
    case .otherAsk, .closedAsk, .unasked: nil
    }
  }
}

/// Every rule about summary asks: which ask is open and its number, which post answers it, how long
/// a line waits for it, when a session is asked by itself, and what the menu shows. The asks are
/// kept in `Continuity`, so they outlive a restart; the waits, the hold-offs and what was loaded
/// are in memory. Pure: the caller passes the time.
struct SummaryAsks: Sendable {
  typealias Ask = Conversation.SummaryAsk

  enum Policy {
    /// The mod's budget for a summary (`CONTEXT_TIMEOUT_MS`, both tested against
    /// `wire/summary-budget.json`): a numbered ask is answered within it or not at all.
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
  /// when it ended if the answer did not end it. Kept across a reconnect, not across Stop, Start or
  /// a target change.
  private var wait: (session: SessionID, number: Int, began: Date, ended: Date?)?
  /// When each session's last summary with text was taken.
  private var lastLoaded: [SessionID: Date] = [:]
  /// The sessions whose last numbered ask was answered with no summary. Each ask sends the
  /// transcript to a model again, so none goes to them by itself (`asksByItself`) until a turn of
  /// theirs arrives, the next Start, or a summary with text, which only a press can ask for then.
  private var heldOff: Set<SessionID> = []

  /// Whether an ask nobody pressed for, from Start, a target change or a line, goes to `id`.
  func asksByItself(_ id: SessionID) -> Bool { !heldOff.contains(id) }

  /// A turn of `id` arrived: its transcript changed, so it is asked by itself again.
  mutating func turnArrived(in id: SessionID) { heldOff.remove(id) }

  /// The ask of `id` that can still be answered at `now`, without taking it.
  func openAsk(of id: SessionID, in continuity: Continuity, at now: Date) -> Ask? {
    continuity[id].summaryAsk.flatMap { now < $0.at + Policy.answerable ? $0 : nil }
  }

  /// `id` is asked for a summary, naming `model` and `fallback` if its mod writes summaries. An open
  /// ask is joined, as the mod joins the summary on its way, and nothing changes, unless a named ask
  /// finds it stale or unnumbered and replaces it. A new named ask takes the next number, which only
  /// grows.
  @discardableResult
  func ask(
    _ id: SessionID, in continuity: inout Continuity, at now: Date, model: String?,
    fallback: String?
  ) -> AskResult {
    if let open = openAsk(of: id, in: continuity, at: now),
      model == nil || (!open.isStale && open.number != nil)
    {
      return .joined(open)
    }
    let number = model.map { _ in (continuity.asksMade ?? 0) + 1 }
    let ask = Ask(at: now, model: model, fallbackModel: fallback, number: number)
    continuity.changeSummaryAsk(of: id) { $0 = ask }
    if let number { continuity.asksMade = number }
    return .new(ask)
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

  /// The call started or stopped: every session may be waited for and asked by itself again, and
  /// no earlier wait is logged.
  mutating func callStartedOrStopped() {
    spent = []
    heldOff = []
    wait = nil
  }

  /// The call's target changed: the next line's wait starts again, for the log.
  mutating func targetChanged() { wait = nil }

  /// A summary post from `id`, with the ask's `number` if the mod echoes one; `wrote` is false for
  /// an empty one. A post for another ask leaves the open ask open; any other closes it. An empty
  /// answer to the open, current ask spends the session's wait for the call and, if the ask is
  /// numbered, holds off the session's asks by itself; one with text ends that.
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
    if wrote {
      heldOff.remove(id)
    } else {
      spent.insert(id)
      if open.number != nil { heldOff.insert(id) }
    }
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
