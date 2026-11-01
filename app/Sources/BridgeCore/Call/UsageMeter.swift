import Foundation

/// When the realtime session was open, so any day or call can be summed. It measures this app's
/// side only; how the ChatGPT plan meters realtime voice is not published.
public struct UsageMeter: Codable, Sendable, Equatable {
  struct Interval: Codable, Sendable, Equatable {
    var start: Date
    var end: Date
  }
  private(set) var intervals: [Interval] = []
  var openedAt: Date?

  public init() {}

  public mutating func opened(at date: Date) { openedAt = openedAt ?? date }

  public mutating func closed(at date: Date) {
    guard let start = openedAt else { return }
    intervals.append(Interval(start: start, end: max(start, date)))
    openedAt = nil
  }

  /// Minutes of closed intervals within `day`; an interval crossing midnight is split.
  public func minutes(on day: Date, calendar: Calendar) -> Double {
    guard let range = calendar.dateInterval(of: .day, for: day) else { return 0 }
    return minutes(from: range.start, to: range.end)
  }

  public func minutes(since date: Date) -> Double { minutes(from: date, to: .distantFuture) }

  private func minutes(from start: Date, to end: Date) -> Double {
    intervals.reduce(0) { $0 + max(0, min($1.end, end).timeIntervalSince(max($1.start, start))) }
      / 60
  }

  mutating func forget(endedBefore date: Date) { intervals.removeAll { $0.end < date } }
}

/// The usage meter kept in a JSON file (`usage.json` in the data directory), 31 days deep.
/// Readings include the session open right now.
public actor UsageMeterStore {
  private let file: URL
  private let time: any TimeSource
  private var meter: UsageMeter

  public init(file: URL, time: any TimeSource) {
    self.file = file
    self.time = time
    meter = (try? JSONDecoder().decode(UsageMeter.self, from: Data(contentsOf: file))) ?? .init()
    meter.openedAt = nil  // a session never outlives the process that opened it
  }

  /// `date` is when the session opened, if the caller read the clock before reaching the store.
  public func opened(at date: Date? = nil) {
    meter.opened(at: date ?? time.now)
    save()
  }

  public func closed(at date: Date? = nil) {
    meter.closed(at: date ?? time.now)
    meter.forget(endedBefore: time.now.addingTimeInterval(-31 * 86_400))
    save()
  }

  public func minutesToday() -> Double { reading.minutes(on: time.now, calendar: .current) }

  public func minutes(since date: Date) -> Double { reading.minutes(since: date) }

  private var reading: UsageMeter {
    var meter = meter
    meter.closed(at: time.now)
    return meter
  }

  /// The meter is informational: a failed write loses only the seconds since the last one.
  private func save() { try? JSONEncoder().encode(meter).write(to: file, options: .atomic) }
}
