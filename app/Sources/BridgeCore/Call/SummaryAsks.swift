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
  /// It carries the number of an ask that is not open: ignored, and the open ask stays open.
  case otherAsk
  /// No ask is open and it names none: an older mod's `/live context`, undated, and taken.
  case unasked

  var isTaken: Bool {
    switch self {
    case .taken, .unasked: true
    case .stale, .otherAsk: false
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

  /// When each session's last summary with text was taken.
  private var loadedAt: [SessionID: Date] = [:]

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

  /// A summary post from `id`, with the ask's `number` if the mod echoes one; `wrote` is false for
  /// an empty one. A post for another ask leaves the open ask open; any other closes it.
  mutating func answer(
    _ id: SessionID, number: Int?, wrote: Bool, in continuity: inout Continuity, at now: Date
  ) -> SummaryAnswer {
    let open = openAsk(of: id, in: continuity, at: now)
    let isOtherAsk = number != nil && open?.number != number
    continuity.changeSummaryAsk(of: id) { if !isOtherAsk { $0 = nil } }
    if isOtherAsk { return .otherAsk }
    guard let open else {
      loadedAt[id] = wrote ? now : nil
      return .unasked
    }
    if open.isStale { return .stale(open, waited: nil) }
    loadedAt[id] = wrote ? now : nil
    return .taken(open, waited: nil)
  }

  /// Loading while an open ask to a mod that writes summaries is current and within the mod's
  /// budget, whatever made it; else the last summary taken, if it had text.
  func display(of id: SessionID, in continuity: Continuity, at now: Date) -> SummaryDisplay {
    if let ask = openAsk(of: id, in: continuity, at: now), !ask.isStale, ask.number != nil,
      now < ask.at + Policy.modBudget
    {
      return .loading
    }
    return loadedAt[id].map { .loaded(at: $0) } ?? .none
  }

  /// Forgets what was loaded for the sessions not in `ids`: they left or were removed.
  mutating func keep(only ids: Set<SessionID>) {
    loadedAt = loadedAt.filter { ids.contains($0.key) }
  }
}
