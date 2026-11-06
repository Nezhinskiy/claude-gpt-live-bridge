import Foundation
import Testing

@testable import BridgeCore

struct LimitsPollTests {
  let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  func reading(_ percent: Double = 7) -> UsageLimits {
    UsageLimits(
      windows: [LimitWindow(span: .minutes(300), usedPercent: percent, resetsAt: nil)], readAt: t0)
  }

  @Test func theFirstOpenReads() {
    var poll = LimitsPoll()
    let began1 = poll.begin(at: t0)
    #expect(began1)
  }

  @Test func oneReadAtATime() {
    var poll = LimitsPoll()
    let began2 = poll.begin(at: t0)
    #expect(began2)
    let began3 = poll.begin(at: t0 + 600)  // still under way
    #expect(!began3)
    poll.finish(reading())
    let began4 = poll.begin(at: t0 + 600)
    #expect(began4)
  }

  @Test func aSecondOpenWithinAMinuteDoesNotRead() {
    var poll = LimitsPoll()
    let began5 = poll.begin(at: t0)
    #expect(began5)
    poll.finish(reading())
    let began6 = poll.begin(at: t0 + 59)
    #expect(!began6)
    let began7 = poll.begin(at: t0 + 60)
    #expect(began7)
  }

  @Test func aFailedReadAllowsTheNextAfterTheCooldown() {
    var poll = LimitsPoll()
    let began8 = poll.begin(at: t0)
    #expect(began8)
    poll.finish(nil)
    let began9 = poll.begin(at: t0 + 59)
    #expect(!began9)
    let began10 = poll.begin(at: t0 + 60)
    #expect(began10)
  }

  @Test func aFailedReadKeepsTheLastReading() {
    var poll = LimitsPoll()
    let first = reading()
    let began11 = poll.begin(at: t0)
    #expect(began11)
    poll.finish(first)
    let began12 = poll.begin(at: t0 + 60)
    #expect(began12)
    poll.finish(nil)
    #expect(poll.reading(at: t0 + 61) == first)
  }

  @Test func aReadingOlderThanFifteenMinutesIsGone() {
    var poll = LimitsPoll()
    let first = reading()
    let began13 = poll.begin(at: t0)
    #expect(began13)
    poll.finish(first)
    #expect(poll.reading(at: t0 + 15 * 60) == first)
    #expect(poll.reading(at: t0 + 15 * 60 + 1) == nil)
  }
}
