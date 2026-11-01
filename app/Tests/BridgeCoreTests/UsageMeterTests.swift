import Foundation
import Testing

@testable import BridgeCore

struct UsageMeterTests {
  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  /// 1 January 2026 (UTC) at `hour:minute`; hour 24 is the next day.
  static func at(_ hour: Int, _ minute: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour, minute: minute))!
  }

  static func meter(_ intervals: [(Date, Date)]) -> UsageMeter {
    var meter = UsageMeter()
    for (start, end) in intervals {
      meter.opened(at: start)
      meter.closed(at: end)
    }
    return meter
  }

  @Test func sumsOpenIntervalsPerDay() {
    var meter = Self.meter([(Self.at(10, 0), Self.at(10, 30)), (Self.at(23, 50), Self.at(24, 20))])
    meter.opened(at: Self.at(24, 30))  // still open: not counted
    #expect(meter.minutes(on: Self.at(12, 0), calendar: Self.calendar) == 40)
    #expect(meter.minutes(on: Self.at(36, 0), calendar: Self.calendar) == 20)
  }

  @Test func minutesSinceCallStart() {
    let meter = Self.meter([(Self.at(10, 0), Self.at(10, 5)), (Self.at(10, 12), Self.at(10, 15))])
    #expect(meter.minutes(since: Self.at(10, 10)) == 3)
  }

  @Test func storeCountsTheOpenSessionAndPersists() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let time = TestTime()
    let start = time.now
    let store = UsageMeterStore(file: file, time: time)
    await store.opened()
    time.advance(by: .seconds(30))
    #expect(await store.minutes(since: start) == 0.5)
    time.advance(by: .seconds(60))
    await store.closed()
    #expect(await UsageMeterStore(file: file, time: time).minutes(since: start) == 1.5)
  }
}
