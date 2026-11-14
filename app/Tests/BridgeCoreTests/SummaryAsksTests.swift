import Foundation
import Testing

@testable import BridgeCore

struct SummaryAsksTests {
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")
  let t0 = Date(timeIntervalSince1970: 1_700_000_000)
  let haiku = SummaryModel.default

  // MARK: Asks and answers

  /// The ask came after the gap, so its summary covers it.
  @Test func aSummaryAskedForAfterAGapCoversIt() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    continuity.markMissed(a, asPaused: false)
    let ask = asks.ask(a, in: &continuity, at: t0, model: nil, fallback: nil).ask
    #expect(
      asks.answer(a, number: nil, wrote: true, in: &continuity, at: t0) == .taken(ask, waited: nil))
  }

  @Test func aSummaryNobodyAskedForIsTaken() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    continuity.markMissed(a, asPaused: false)
    #expect(asks.answer(a, number: nil, wrote: true, in: &continuity, at: t0) == .unasked)
  }

  /// A gap the join reports after the ask makes it stale, as a refused line does.
  @Test func aMissedTurnAfterTheAskRefusesItsSummary() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: nil, fallback: nil)
    continuity.markMissed(a, asPaused: false)
    #expect(!asks.answer(a, number: nil, wrote: true, in: &continuity, at: t0).isTaken)
  }

  /// The mod joins a second ask to the summary on its way, which is the first ask's.
  @Test func aSecondAskDoesNotFreshenTheFirst() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: nil, fallback: nil)
    continuity.markMissed(a, asPaused: false)
    asks.ask(a, in: &continuity, at: t0 + 1, model: nil, fallback: nil)
    #expect(!asks.answer(a, number: nil, wrote: true, in: &continuity, at: t0 + 2).isTaken)
  }

  /// A second ask while one is open is the same ask, number included.
  @Test func aSecondNumberedAskJoinsTheOpenOne() {
    var continuity = Continuity()
    let asks = SummaryAsks()
    let first = asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil)
    let second = asks.ask(a, in: &continuity, at: t0 + 1, model: haiku, fallback: nil)
    #expect(first == .new(second.ask))
    #expect(second == .joined(first.ask))
    #expect(first.ask.number == 1)
  }

  /// An ask recorded with no number (for a mod that forks, or by 0.5.x) cannot be told from a
  /// stale one by a numbered answer, so an ask naming a model replaces it.
  @Test func anAskNamingAModelReplacesOneWithNoNumber() {
    var continuity = Continuity()
    let asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: nil, fallback: nil)
    let ask = asks.ask(a, in: &continuity, at: t0 + 1, model: haiku, fallback: nil).ask
    #expect(ask.number != nil)
    #expect(asks.openAsk(of: a, in: continuity, at: t0 + 2)?.model == haiku)
  }

  @Test func aForgetDoesNotRestartTheNumbering() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    let first = asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil).ask
    _ = asks.answer(a, number: first.number, wrote: true, in: &continuity, at: t0)
    continuity.forget(a)
    let second = asks.ask(a, in: &continuity, at: t0 + 1, model: haiku, fallback: nil).ask
    #expect(second.number != first.number)
  }

  /// An ask after a gap is a fresh one, with its own model, not blocked behind the stale ask.
  @Test func aFreshAskReplacesAStaleOne() {
    var continuity = Continuity()
    let asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: "claude-opus-5-5", fallback: nil)
    continuity.markMissed(a, asPaused: false)
    asks.ask(a, in: &continuity, at: t0 + 1, model: "claude-sonnet-5-5", fallback: nil)
    let open = asks.openAsk(of: a, in: continuity, at: t0 + 2)
    #expect(open?.isStale == false)
    #expect(open?.model == "claude-sonnet-5-5")
    #expect(open?.at == t0 + 1)
  }

  /// A summary refused closes its ask: the owner's next press stands on its own.
  @Test func aRefusedSummaryClosesItsAsk() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: nil, fallback: nil)
    continuity.markMissed(a, asPaused: false)
    _ = asks.answer(a, number: nil, wrote: true, in: &continuity, at: t0)
    asks.ask(a, in: &continuity, at: t0 + 1, model: nil, fallback: nil)
    #expect(asks.answer(a, number: nil, wrote: true, in: &continuity, at: t0 + 2).isTaken)
  }

  /// A summary that never came (nothing to summarise, or a failure) does not hold back a later one.
  @Test func anAskPastItsLifeRefusesNothing() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: nil, fallback: nil)
    continuity.markMissed(a, asPaused: false)
    let later = t0 + SummaryAsks.Policy.answerable
    asks.ask(a, in: &continuity, at: later, model: nil, fallback: nil)
    #expect(asks.answer(a, number: nil, wrote: true, in: &continuity, at: later).isTaken)
  }

  /// `/clear` moves the conversation, and the ask with it.
  @Test func anAskMovesWithItsConversation() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: nil, fallback: nil)
    continuity.markMissed(a, asPaused: false)
    continuity.move(a, to: b)
    #expect(!asks.answer(b, number: nil, wrote: true, in: &continuity, at: t0).isTaken)
  }

  /// A post with another ask's number answers none, and the open ask stays open.
  @Test func aPostForAnotherAskLeavesTheOpenAsk() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    let open = asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil).ask
    #expect(asks.answer(a, number: 7, wrote: true, in: &continuity, at: t0) == .otherAsk)
    #expect(asks.openAsk(of: a, in: continuity, at: t0) == open)
  }

  /// A numbered post when no ask is open answers one already closed: it is not taken.
  @Test func aNumberedPostWithNoAskOpenIsNotTaken() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    #expect(asks.answer(a, number: 1, wrote: true, in: &continuity, at: t0) == .closedAsk)
  }

  // MARK: The wait

  @Test func noAskNoWait() {
    var asks = SummaryAsks()
    #expect(asks.wait(a, in: Continuity(), at: t0) == nil)
  }

  /// An ask with no number went to a mod that forks, which posts nothing when it has nothing.
  @Test func anOlderModIsNeverWaitedFor() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: nil, fallback: nil)
    #expect(asks.wait(a, in: continuity, at: t0) == nil)
  }

  /// A line opened late in a summary's run waits only for the rest of it.
  @Test func theLimitCountsFromTheAsk() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil)
    #expect(asks.wait(a, in: continuity, at: t0 + 4) == t0 + SummaryAsks.Policy.waitLimit)
  }

  /// Its summary would be ignored, so nothing waits for it.
  @Test func aStaleAskIsNotWaitedFor() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil)
    continuity.markMissed(a, asPaused: false)
    #expect(asks.wait(a, in: continuity, at: t0) == nil)
  }

  /// An answer with no summary spends the session's wait for the call, though no line waited for
  /// it; a new call waits again.
  @Test func anEmptyAnswerSpendsTheWaitForTheCall() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    let first = asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil).ask
    _ = asks.answer(a, number: first.number, wrote: false, in: &continuity, at: t0 + 1)
    asks.ask(a, in: &continuity, at: t0 + 2, model: haiku, fallback: nil)
    #expect(asks.wait(a, in: continuity, at: t0 + 2) == nil)
    asks.callStartedOrStopped()
    #expect(asks.wait(a, in: continuity, at: t0 + 2) == t0 + 2 + SummaryAsks.Policy.waitLimit)
  }

  /// A line that waits until the limit spends the session's wait for the call.
  @Test func aLineThatWaitsOutTheLimitSpendsTheWait() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    let first = asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil).ask
    let limit = t0 + SummaryAsks.Policy.waitLimit
    #expect(asks.wait(a, in: continuity, at: t0) == limit)
    #expect(asks.wait(a, in: continuity, at: limit) == nil)
    _ = asks.answer(a, number: first.number, wrote: true, in: &continuity, at: limit + 1)
    asks.ask(a, in: &continuity, at: limit + 2, model: haiku, fallback: nil)
    #expect(asks.wait(a, in: continuity, at: limit + 2) == nil)
  }

  /// A line that comes after the limit, the ask still in flight, opens without waiting and leaves
  /// the session's wait for a later ask.
  @Test func aLineAfterTheLimitDoesNotSpendTheWait() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    let first = asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil).ask
    let limit = t0 + SummaryAsks.Policy.waitLimit
    #expect(asks.wait(a, in: continuity, at: limit) == nil)
    _ = asks.answer(a, number: first.number, wrote: true, in: &continuity, at: limit + 1)
    asks.ask(a, in: &continuity, at: limit + 2, model: haiku, fallback: nil)
    #expect(asks.wait(a, in: continuity, at: limit + 2) == limit + 2 + SummaryAsks.Policy.waitLimit)
  }

  /// The log's `waited`: from the wait's start to the answer, or to the wait's end if it ended
  /// first; a reconnect waits again for the same ask from the same start.
  @Test func theWaitCountsFromItsStart() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    let ask = asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil).ask
    _ = asks.wait(a, in: continuity, at: t0 + 2)
    asks.endWait(at: t0 + 3)
    _ = asks.wait(a, in: continuity, at: t0 + 4)
    #expect(
      asks.answer(a, number: 1, wrote: true, in: &continuity, at: t0 + 5)
        == .taken(ask, waited: 3))
    let next = asks.ask(a, in: &continuity, at: t0 + 6, model: haiku, fallback: nil).ask
    _ = asks.wait(a, in: continuity, at: t0 + 6)
    asks.endWait(at: t0 + 7)
    #expect(
      asks.answer(a, number: 2, wrote: true, in: &continuity, at: t0 + 9)
        == .taken(next, waited: 1))
  }

  /// After Stop and Start, the log's `waited` counts only the new call's line.
  @Test func aNewCallCountsOnlyItsOwnWait() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    let ask = asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil).ask
    _ = asks.wait(a, in: continuity, at: t0)
    asks.endWait(at: t0 + 1)
    asks.callStartedOrStopped()
    _ = asks.wait(a, in: continuity, at: t0 + 3)
    #expect(
      asks.answer(a, number: 1, wrote: true, in: &continuity, at: t0 + 5)
        == .taken(ask, waited: 2))
  }

  // MARK: What the menu shows

  /// Whatever asked for it, the summary is on its way until its answer, per session.
  @Test func anyAskInFlightShowsLoading() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil)
    #expect(asks.display(of: a, in: continuity, at: t0) == .loading)
    #expect(asks.display(of: b, in: continuity, at: t0) == .none)
    _ = asks.answer(a, number: 1, wrote: true, in: &continuity, at: t0 + 1)
    #expect(asks.display(of: a, in: continuity, at: t0 + 1) == .loaded(at: t0 + 1))
    asks.ask(a, in: &continuity, at: t0 + 2, model: haiku, fallback: nil)
    #expect(asks.display(of: a, in: continuity, at: t0 + 2) == .loading)  // a newer ask
  }

  /// An older mod posts nothing when it has nothing to summarise, so the menu does not wait.
  @Test func anAskToAnOlderModIsNotInFlight() {
    var continuity = Continuity()
    let asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: nil, fallback: nil)
    #expect(asks.display(of: a, in: continuity, at: t0) == .none)
  }

  /// The mod answers within its budget or not at all, so the menu stops waiting there.
  @Test func anAskIsNotInFlightPastTheModsBudget() {
    var continuity = Continuity()
    let asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil)
    #expect(asks.display(of: a, in: continuity, at: t0 + 59) == .loading)
    #expect(asks.display(of: a, in: continuity, at: t0 + 60) == .none)
  }

  @Test func aStaleAskIsNotInFlight() {
    var continuity = Continuity()
    let asks = SummaryAsks()
    asks.ask(a, in: &continuity, at: t0, model: haiku, fallback: nil)
    continuity.forget(a)
    #expect(asks.display(of: a, in: continuity, at: t0) == .none)
  }

  /// An empty answer is no summary: nothing was loaded, and an earlier load is no longer shown.
  /// An ignored one changes nothing.
  @Test func onlyATakenSummaryShowsAsLoaded() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    _ = asks.answer(a, number: nil, wrote: true, in: &continuity, at: t0)
    asks.ask(a, in: &continuity, at: t0 + 1, model: haiku, fallback: nil)
    _ = asks.answer(a, number: 9, wrote: true, in: &continuity, at: t0 + 2)
    continuity.forget(a)
    _ = asks.answer(a, number: 1, wrote: true, in: &continuity, at: t0 + 2)
    #expect(asks.display(of: a, in: continuity, at: t0 + 2) == .loaded(at: t0))
    _ = asks.answer(a, number: nil, wrote: false, in: &continuity, at: t0 + 3)
    #expect(asks.display(of: a, in: continuity, at: t0 + 3) == .none)
  }

  @Test func aSessionThatLeftIsForgotten() {
    var continuity = Continuity()
    var asks = SummaryAsks()
    _ = asks.answer(a, number: nil, wrote: true, in: &continuity, at: t0)
    _ = asks.answer(b, number: nil, wrote: true, in: &continuity, at: t0)
    asks.keep(only: [b])
    #expect(asks.display(of: a, in: continuity, at: t0) == .none)
    #expect(asks.display(of: b, in: continuity, at: t0) == .loaded(at: t0))
  }
}
