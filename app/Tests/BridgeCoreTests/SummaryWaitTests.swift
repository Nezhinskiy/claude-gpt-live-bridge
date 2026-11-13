import Foundation
import Testing

@testable import BridgeCore

struct SummaryWaitTests {
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  var ask: Conversation.SummaryAsk {
    Conversation.SummaryAsk(at: t0, model: SummaryModel.default, number: 1)
  }

  @Test func noAskNoWait() {
    #expect(SummaryWait().deadline(for: a, ask: nil, writesSummaries: true) == nil)
  }

  @Test func anOlderModIsNeverWaitedFor() {
    #expect(SummaryWait().deadline(for: a, ask: ask, writesSummaries: false) == nil)
  }

  @Test func aWaitThatEndedEmptyIsNotRepeatedThisCall() {
    var wait = SummaryWait()
    wait.endedWithout(a)
    #expect(wait.deadline(for: a, ask: ask, writesSummaries: true) == nil)
  }

  /// A line opened late in a summary's run waits only for the rest of it.
  @Test func theLimitCountsFromTheAsk() {
    #expect(
      SummaryWait().deadline(for: a, ask: ask, writesSummaries: true) == t0 + SummaryWait.limit)
  }

  @Test func aNewCallWaitsAgain() {
    var wait = SummaryWait()
    wait.endedWithout(a)
    wait.newCall()
    #expect(wait.deadline(for: a, ask: ask, writesSummaries: true) == t0 + SummaryWait.limit)
  }

  /// Its summary would be ignored, so nothing waits for it.
  @Test func aStaleAskIsNotWaitedFor() {
    var stale = ask
    stale.isStale = true
    #expect(SummaryWait().deadline(for: a, ask: stale, writesSummaries: true) == nil)
  }
}
