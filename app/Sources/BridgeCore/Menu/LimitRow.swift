import Foundation

/// One source's usage in the menu: its name, a figure per window it reports, whether it says
/// usage is blocked, and a tooltip with the reset times. Pure.
public struct LimitRow: Sendable, Equatable {
  /// A piece of the row's text, in order: a window's used share as "7% of 5 h", a separator, or
  /// "blocked". `isNear` marks a share close to its limit; the app only colours the runs.
  public struct Run: Sendable, Equatable {
    public let text: String
    public let isNear: Bool
  }

  /// A figure at this shown percent or more is near its limit.
  public static let nearPercent = 90

  public let name: String
  /// The figures, then "blocked", with " · " between each two.
  public let runs: [Run]
  public let isBlocked: Bool
  public let tooltip: String

  /// The runs joined: the row's text after its name.
  public var text: String { runs.map(\.text).joined() }

  /// nil when `limits` has no window still current and no block: there is nothing to show.
  public init?(name: String, limits: UsageLimits?, now: Date, calendar: Calendar, locale: Locale) {
    guard let current = limits?.current(at: now) else { return nil }
    guard !current.windows.isEmpty || current.isBlocked else { return nil }

    // The value comes from the socket. `Int(_:)` traps on NaN and on infinity, which `min` and `max`
    // let through, so a value that is not finite is 0; the rest is clamped to 0...100 here only.
    func figure(_ window: LimitWindow) -> Run {
      let value = window.usedPercent.isFinite ? window.usedPercent : 0
      let percent = Int(min(max(value, 0), 100).rounded())
      return Run(
        text: "\(percent)% of \(window.span.label)", isNear: percent >= Self.nearPercent)
    }
    let windows = current.windows

    func formatted(_ template: String) -> DateFormatter {
      let formatter = DateFormatter()
      formatter.calendar = calendar
      formatter.locale = locale
      formatter.timeZone = calendar.timeZone
      formatter.dateFormat = DateFormatter.dateFormat(
        fromTemplate: template, options: 0, locale: locale)
      return formatter
    }
    let timeOnly = formatted("jmm")
    let dayAndTime = formatted("EEEjmm")
    let dateAndTime = formatted("dMMMjmm")
    /// The time on today's date; within six days of today the short weekday and the time; further
    /// off, either way, the date and the time (a weekday alone could mean any week).
    func when(_ date: Date) -> (text: String, isToday: Bool) {
      let isToday = calendar.isDate(date, inSameDayAs: now)
      let days =
        calendar.dateComponents(
          [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
      let formatter = isToday ? timeOnly : abs(days) <= 6 ? dayAndTime : dateAndTime
      return (formatter.string(from: date), isToday)
    }

    var lines: [String] = []
    if current.isBlocked { lines.append("\(name) reports usage is blocked right now.") }
    for item in windows {
      guard let resetsAt = item.resetsAt else { continue }
      let shown = when(resetsAt)
      lines.append("\(item.span.windowName) resets " + (shown.isToday ? "at " : "") + shown.text)
    }
    lines.append("Read at " + when(current.readAt).text)

    self.name = name
    let separator = Run(text: " · ", isNear: false)
    var runs = Array(windows.map(figure).map { [$0] }.joined(separator: [separator]))
    if current.isBlocked {
      runs += (runs.isEmpty ? [] : [separator]) + [Run(text: "blocked", isNear: false)]
    }
    self.runs = runs
    isBlocked = current.isBlocked
    tooltip = lines.joined(separator: "\n")
  }
}
