import Foundation
import Testing

@testable import BridgeCore

struct UsageLimitsTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func reading(
    fiveHour: LimitWindow? = nil, week: LimitWindow? = nil, readAt: Date? = nil
  ) -> UsageLimits {
    UsageLimits(fiveHour: fiveHour, week: week, readAt: readAt ?? now)
  }

  @Test func aWindowPastItsResetIsDropped() {
    let past = LimitWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(-1))
    let atNow = LimitWindow(usedPercent: 20, resetsAt: now)
    let open = LimitWindow(usedPercent: 30, resetsAt: nil)
    #expect(reading(fiveHour: past, week: atNow).current(at: now).fiveHour == nil)
    #expect(reading(fiveHour: past, week: atNow).current(at: now).week == atNow)
    #expect(reading(fiveHour: open).current(at: now).fiveHour == open)
  }

  @Test func theLaterResetWins() {
    let early = LimitWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(100))
    let late = LimitWindow(usedPercent: 3, resetsAt: now.addingTimeInterval(200))
    #expect(reading(fiveHour: early).merging(reading(fiveHour: late)).fiveHour == late)
    #expect(reading(fiveHour: late).merging(reading(fiveHour: early)).fiveHour == late)
  }

  @Test func onTheSameResetTheHigherPercentStays() {
    let reset = now.addingTimeInterval(100)
    let old = reading(
      fiveHour: LimitWindow(usedPercent: 40, resetsAt: reset), readAt: now)
    let new = reading(
      fiveHour: LimitWindow(usedPercent: 12, resetsAt: reset),
      readAt: now.addingTimeInterval(60))
    let merged = old.merging(new)
    #expect(merged.fiveHour?.usedPercent == 40)
    #expect(merged.readAt == new.readAt)
  }

  @Test func aWindowWithNoResetTakesTheNewest() {
    let reset = now.addingTimeInterval(100)
    let dated = LimitWindow(usedPercent: 50, resetsAt: reset)
    let undated = LimitWindow(usedPercent: 5, resetsAt: nil)
    #expect(reading(week: dated).merging(reading(week: undated)).week == undated)
    #expect(reading(week: undated).merging(reading(week: dated)).week == dated)
  }

  @Test func aMissingWindowKeepsTheHeldOne() {
    let held = LimitWindow(usedPercent: 22, resetsAt: now.addingTimeInterval(100))
    let merged = reading(week: held).merging(reading(week: nil))
    #expect(merged.week == held)
  }
}
