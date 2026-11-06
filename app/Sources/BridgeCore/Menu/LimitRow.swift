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
    guard current.fiveHour != nil || current.week != nil || current.isBlocked else { return nil }

    // The value comes from the socket, and `Int(_:)` traps on a huge double: clamp first.
    func figure(_ window: LimitWindow, of span: String) -> Figure {
      let percent = Int(min(max(window.usedPercent, 0), 100).rounded())
      return Figure(text: "\(percent)% of \(span)", isNear: percent >= Self.nearPercent)
    }
    let windows: [(window: LimitWindow, span: String, label: String)] = [
      current.fiveHour.map { ($0, "5 h", "5-hour window") },
      current.week.map { ($0, "week", "Weekly window") },
    ].compactMap { $0 }

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
      guard let resetsAt = item.window.resetsAt else { continue }
      let shown = when(resetsAt)
      lines.append("\(item.label) resets " + (shown.isToday ? "at " : "") + shown.text)
    }
    lines.append("Read at " + when(current.readAt).text)

    self.name = name
    figures = windows.map { figure($0.window, of: $0.span) }
    isBlocked = current.isBlocked
    tooltip = lines.joined(separator: "\n")
  }
}
