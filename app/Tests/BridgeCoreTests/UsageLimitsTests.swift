import Foundation
import Testing

@testable import BridgeCore

struct UsageLimitsTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let five = LimitSpan.minutes(300)
  let week = LimitSpan.minutes(10080)

  func window(_ span: LimitSpan, _ percent: Double = 10, _ reset: Date? = nil) -> LimitWindow {
    LimitWindow(span: span, usedPercent: percent, resetsAt: reset)
  }

  func reading(_ windows: LimitWindow..., readAt: Date? = nil) -> UsageLimits {
    UsageLimits(windows: windows, readAt: readAt ?? now)
  }

  @Test func aWindowPastItsResetIsDropped() {
    let past = window(five, 10, now.addingTimeInterval(-1))
    let atNow = window(week, 20, now)
    let open = window(.minutes(240), 30)
    #expect(reading(past, atNow, open).current(at: now).windows == [open, atNow])
  }

  @Test func theLaterResetWins() {
    let early = window(five, 80, now.addingTimeInterval(100))
    let late = window(five, 3, now.addingTimeInterval(200))
    #expect(reading(early).merging(reading(late)).windows == [late])
    #expect(reading(late).merging(reading(early)).windows == [late])
  }

  @Test func resetsAMinuteApartAreOneWindow() {
    let reset = now.addingTimeInterval(100)
    let held = reading(window(five, 40, reset))
    let near = window(five, 12, reset.addingTimeInterval(59))
    #expect(held.merging(reading(near)).windows == [window(five, 40, reset)])
    let nearAndHigher = window(five, 41, reset.addingTimeInterval(-59))
    #expect(held.merging(reading(nearAndHigher)).windows == [nearAndHigher])
    let later = window(five, 12, reset.addingTimeInterval(61))
    #expect(held.merging(reading(later)).windows == [later])
    let earlier = window(five, 90, reset.addingTimeInterval(-61))
    #expect(held.merging(reading(earlier)).windows == [window(five, 40, reset)])
  }

  @Test func onTheSameResetTheHigherPercentStays() {
    let reset = now.addingTimeInterval(100)
    let old = reading(window(five, 40, reset), readAt: now)
    let new = reading(window(five, 12, reset), readAt: now.addingTimeInterval(60))
    #expect(old.merging(new).windows.first?.usedPercent == 40)
  }

  @Test func aLosingArrivalDoesNotMoveReadAt() {
    let reset = now.addingTimeInterval(100)
    let old = reading(window(five, 40, reset), readAt: now)
    let losing = reading(window(five, 12, reset), readAt: now.addingTimeInterval(3600))
    #expect(old.merging(losing).readAt == now)
  }

  @Test func aConfirmingOrWinningArrivalMovesReadAt() {
    let reset = now.addingTimeInterval(100)
    let old = reading(window(five, 40, reset), readAt: now)
    let later = now.addingTimeInterval(60)
    #expect(old.merging(reading(window(five, 40, reset), readAt: later)).readAt == later)
    #expect(old.merging(reading(window(five, 41, reset), readAt: later)).readAt == later)
    #expect(old.merging(reading(window(week, 1, reset), readAt: later)).readAt == later)
  }

  @Test func aWindowWithNoResetTakesTheNewest() {
    let dated = window(week, 50, now.addingTimeInterval(100))
    let undated = window(week, 5)
    #expect(reading(undated).merging(reading(dated)).windows == [dated])
    #expect(reading(undated).merging(reading(window(week, 9))).windows == [window(week, 9)])
  }

  @Test func aKnownResetSurvivesAnUndatedReport() {
    let reset = now.addingTimeInterval(100)
    let held = reading(window(week, 50, reset))
    #expect(held.merging(reading(window(week, 60))).windows == [window(week, 60, reset)])
    #expect(held.merging(reading(window(week, 5))).windows == [window(week, 50, reset)])
  }

  @Test func anUndatedWindowGoesAfterFifteenMinutes() {
    let undated = window(five, 95)
    let got = reading(undated, readAt: now)
    #expect(got.current(at: now.addingTimeInterval(15 * 60)).windows == [undated])
    #expect(got.current(at: now.addingTimeInterval(15 * 60 + 1)).windows.isEmpty)
  }

  @Test func anUndatedWindowNobodyReportsGoes() {
    let held = reading(window(week, 30), window(five, 10, now.addingTimeInterval(100)))
    let merged = held.merging(reading(window(.kind("x"), 5)))
    #expect(merged.windows.map(\.span) == [five, .kind("x")])
  }

  @Test func aMissingWindowKeepsTheHeldOne() {
    let held = window(week, 22, now.addingTimeInterval(100))
    #expect(reading(held).merging(reading()).windows == [held])
  }

  @Test func aWindowNobodyReportsGoesAtItsReset() {
    let held = window(.kind("x"), 30, now.addingTimeInterval(100))
    let merged = reading(held).merging(reading(window(five, 5)))
    #expect(merged.windows.contains(held))
    #expect(merged.current(at: now).windows.contains(held))
    #expect(!merged.current(at: now.addingTimeInterval(101)).windows.contains(held))
  }

  @Test func windowsAreShortestFirst() {
    let some = reading(window(.unknown), window(.kind("b")), window(.minutes(45)))
    #expect(some.windows.map(\.span) == [.minutes(45), .kind("b"), .unknown])
    let kinds = reading(window(.kind("b")), window(.kind("a")), window(.minutes(9)))
    #expect(kinds.windows.map(\.span) == [.minutes(9), .kind("a"), .kind("b")])
  }

  @Test func aRowHoldsThreeWithTheKnownFirst() {
    let got = reading(
      window(.minutes(10)), window(.minutes(20)), window(.minutes(10080)), window(.minutes(30)),
      window(.minutes(300)))
    #expect(UsageLimits.maxWindows == 3)
    #expect(got.windows.map(\.span) == [.minutes(10), .minutes(300), .minutes(10080)])
  }

  @Test func aLaterWindowOfAHeldSpanIsDropped() {
    #expect(reading(window(five, 1), window(five, 2)).windows == [window(five, 1)])
  }
}

struct LimitSpanTests {
  @Test func labelsFollowTheLength() {
    let labels: [(Int, String)] = [
      (300, "5 h"), (240, "4 h"), (45, "45 min"), (1440, "1 d"), (43200, "30 d"),
      (9576, "week"), (10080, "week"), (10584, "week"), (9575, "7 d"),
    ]
    for (minutes, label) in labels {
      #expect(LimitSpan.minutes(minutes).label == label, "\(minutes)")
    }
  }

  @Test func windowNamesFollowTheLength() {
    let names: [(LimitSpan, String)] = [
      (.minutes(300), "5-hour window"), (.minutes(240), "4-hour window"),
      (.minutes(10080), "Weekly window"), (.minutes(43200), "30-day window"),
      (.minutes(45), "45-minute window"), (.unknown, "Limit"),
      (.kind("five_minute"), "Five minute window"),
    ]
    for (span, name) in names { #expect(span.windowName == name) }
    #expect(LimitSpan.kind("five_minute").label == "five minute")
    #expect(LimitSpan.unknown.label == "limit")
  }

  @Test func onlyFiveHoursAndAWeekAreKnown() {
    #expect(LimitSpan.minutes(300).isKnown && LimitSpan.minutes(10080).isKnown)
    #expect(!LimitSpan.minutes(240).isKnown && !LimitSpan.unknown.isKnown)
    #expect(!LimitSpan.kind("x").isKnown)
  }

  @Test func lengthsNearTheKnownOnesAreNormalised() {
    for (minutes, want) in [(285.0, 300), (315, 300), (9576, 10080), (10584, 10080)] {
      #expect(LimitSpan(minutes: minutes) == .minutes(want), "\(minutes)")
    }
    for minutes in [284.0, 316, 9575, 10585] {
      #expect(LimitSpan(minutes: minutes) == .minutes(Int(minutes)), "\(minutes)")
    }
    for odd in [nil, 0, -5, .infinity, .nan, 1e300] as [Double?] {
      #expect(LimitSpan(minutes: odd) == .unknown)
    }
  }
}
