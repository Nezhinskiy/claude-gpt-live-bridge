import Foundation

/// One source's usage in the menu: its name, a figure per window it reports, whether it says
/// usage is blocked, and a tooltip with the reset times. Pure.
public struct LimitRow: Sendable, Equatable {
  /// One window's used share, as "7% of 5 h", and whether it is close to the limit.
  public struct Figure: Sendable, Equatable {
    public let text: String
    public let isNear: Bool
  }

  /// A figure at this shown percent or more is near its limit.
  public static let nearPercent = 90

  public let name: String
  public let figures: [Figure]
  public let isBlocked: Bool
  public let tooltip: String

  /// The figures, then "blocked", joined by " · ".
  public var text: String {
    (figures.map(\.text) + (isBlocked ? ["blocked"] : [])).joined(separator: " · ")
  }

  /// nil when `limits` has no window still current and no block: there is nothing to show.
  public init?(name: String, limits: UsageLimits?, now: Date, calendar: Calendar, locale: Locale) {
    guard let current = limits?.current(at: now) else { return nil }
    guard !current.windows.isEmpty || current.isBlocked else { return nil }

    // The value comes from the socket. `Int(_:)` traps on NaN and on infinity, which `min` and `max`
    // let through, so a value that is not finite is 0; the rest is clamped to 0...100 here only.
    func figure(_ window: LimitWindow) -> Figure {
      let value = window.usedPercent.isFinite ? window.usedPercent : 0
      let percent = Int(min(max(value, 0), 100).rounded())
      return Figure(
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
    /// The time on today's date, else the short weekday and the time.
    func when(_ date: Date) -> (text: String, isToday: Bool) {
      let isToday = calendar.isDate(date, inSameDayAs: now)
      return ((isToday ? timeOnly : dayAndTime).string(from: date), isToday)
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
    figures = windows.map(figure)
    isBlocked = current.isBlocked
    tooltip = lines.joined(separator: "\n")
  }
}
