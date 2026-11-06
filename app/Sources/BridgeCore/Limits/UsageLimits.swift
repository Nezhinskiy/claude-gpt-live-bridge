import Foundation

/// How long a usage window is, as far as the source says. Windows are told apart by this and
/// nothing else, so a window of a new length shows rather than vanishes.
public enum LimitSpan: Hashable, Sendable {
  /// A length in minutes. Within 5 % of 300 or 10080 it is exactly that (see `init(minutes:)`).
  case minutes(Int)
  /// A Claude kind the app does not know, by name.
  case kind(String)
  /// The source gave no length.
  case unknown

  /// The five-hour length and the week's, in minutes: the lengths the app names.
  public static let shortMinutes = 300
  public static let aWeek = 10080

  /// A length from the source's number: 300 or 10080 when within 5 % of it, else rounded to a
  /// whole minute. No usable number is `.unknown`.
  public init(minutes: Double?) {
    guard let minutes, minutes.isFinite, minutes >= 0.5, minutes <= 1e7 else {
      self = .unknown
      return
    }
    self = .minutes(Self.snapped(Int(minutes.rounded())))
  }

  private static func snapped(_ minutes: Int) -> Int {
    for target in [shortMinutes, aWeek] where abs(minutes - target) * 20 <= target { return target }
    return minutes
  }

  /// The figure's unit: "5 h", "week", "30 d", "45 min", "90 min", "limit", or a kind with spaces.
  public var label: String {
    switch self {
    case .minutes(let minutes):
      if minutes == Self.aWeek { return "week" }
      let (count, unit) = Self.length(minutes)
      return "\(count) \(unit.short)"
    case .kind(let name): return name.replacingOccurrences(of: "_", with: " ")
    case .unknown: return "limit"
    }
  }

  /// The tooltip's name for the window: "5-hour window", "Weekly window", "Limit".
  public var windowName: String {
    switch self {
    case .minutes(let minutes):
      if minutes == Self.aWeek { return "Weekly window" }
      let (count, unit) = Self.length(minutes)
      return "\(count)-\(unit.long) window"
    case .kind:
      let text = label
      return text.prefix(1).uppercased() + text.dropFirst() + " window"
    case .unknown: return "Limit"
    }
  }

  /// A length the app names: five hours or a week.
  public var isKnown: Bool {
    guard case .minutes(let minutes) = self else { return false }
    return minutes == Self.shortMinutes || minutes == Self.aWeek
  }

  private enum Unit {
    case minute, hour, day

    var short: String {
      switch self {
      case .minute: "min"
      case .hour: "h"
      case .day: "d"
      }
    }

    var long: String {
      switch self {
      case .minute: "minute"
      case .hour: "hour"
      case .day: "day"
      }
    }
  }

  /// A length in minutes as a count and a unit: whole hours under a day in hours, anything else
  /// under a day in minutes (90 stays 90 min, not 2 h), a day or more in days, rounded.
  private static func length(_ minutes: Int) -> (count: Int, unit: Unit) {
    if minutes >= 1440 { return ((minutes + 720) / 1440, .day) }
    if minutes >= 60 && minutes % 60 == 0 { return (minutes / 60, .hour) }
    return (minutes, .minute)
  }

  /// Shortest first: lengths ascending, then kinds by name, then no length.
  fileprivate var order: (rank: Int, minutes: Int, name: String) {
    switch self {
    case .minutes(let minutes): return (0, minutes, "")
    case .kind(let name): return (1, 0, name)
    case .unknown: return (2, 0, "")
    }
  }
}

/// One usage window: its length, how much of it is used and when it resets.
public struct LimitWindow: Sendable, Equatable {
  public var span: LimitSpan
  public var usedPercent: Double
  public var resetsAt: Date?

  public init(span: LimitSpan, usedPercent: Double, resetsAt: Date?) {
    self.span = span
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
  }
}

/// What one source says about its usage: the windows it reports, shortest first and at most
/// `maxWindows`, and when it was read. Held in memory only.
public struct UsageLimits: Sendable, Equatable {
  /// A row holds this many windows; the ones of a length the app names stay first.
  public static let maxWindows = 3

  public private(set) var windows: [LimitWindow]
  /// The source says ordinary usage is not allowed right now, whatever the percentages show.
  public var isBlocked = false
  public var readAt: Date

  /// Keeps the first window of each span, the known lengths first when there are too many, and
  /// orders them shortest first.
  public init(windows: [LimitWindow] = [], isBlocked: Bool = false, readAt: Date) {
    self.windows = Self.ordered(windows)
    self.isBlocked = isBlocked
    self.readAt = readAt
  }

  private static func ordered(_ windows: [LimitWindow]) -> [LimitWindow] {
    var seen: Set<LimitSpan> = []
    let distinct = windows.filter { seen.insert($0.span).inserted }
    let kept = (distinct.filter { $0.span.isKnown } + distinct.filter { !$0.span.isKnown })
      .prefix(maxWindows)
    return kept.sorted {
      ($0.span.order.rank, $0.span.order.minutes, $0.span.order.name) < (
        $1.span.order.rank, $1.span.order.minutes, $1.span.order.name
      )
    }
  }

  /// How long a window with no reset stays after the reading: nothing says when it ends, so it is
  /// not kept for ever. Codex's own staleness limit.
  public static let undatedLife: TimeInterval = 15 * 60

  /// This reading without the windows that no longer say anything about the current one: those
  /// whose reset has passed, and those with no reset once `undatedLife` has passed since `readAt`.
  public func current(at now: Date) -> UsageLimits {
    var copy = self
    copy.windows = windows.filter { window in
      guard let resetsAt = window.resetsAt else {
        return now.timeIntervalSince(readAt) <= Self.undatedLife
      }
      return resetsAt >= now
    }
    return copy
  }

  /// Resets this close are one reset: a source's time may jitter by a second or so.
  static let sameReset: TimeInterval = 60

  /// `newer` over this one, window by window: the later reset wins, on the same reset (within a
  /// minute) the higher percent, kept whole (use within a window only grows), and a window with no reset takes the newer, except
  /// that a known reset is kept against an undated report (with the higher percent). A window
  /// `newer` lacks stays as held until its reset; one with no reset has none to wait for and goes.
  /// `readAt` moves to `newer`'s only when some window of it was taken or matches what is held:
  /// an arrival that lost everywhere confirmed nothing.
  public func merging(_ newer: UsageLimits) -> UsageLimits {
    func merged(_ old: LimitWindow, _ new: LimitWindow) -> LimitWindow {
      guard let oldReset = old.resetsAt else { return new }
      guard let newReset = new.resetsAt else {
        return LimitWindow(
          span: new.span, usedPercent: max(old.usedPercent, new.usedPercent), resetsAt: oldReset)
      }
      if abs(newReset.timeIntervalSince(oldReset)) > Self.sameReset {
        return newReset > oldReset ? new : old
      }
      return new.usedPercent >= old.usedPercent ? new : old
    }
    var all: [LimitWindow] = []
    var confirmed = false
    for new in newer.windows {
      guard let old = windows.first(where: { $0.span == new.span }) else {
        all.append(new)
        confirmed = true
        continue
      }
      let kept = merged(old, new)
      all.append(kept)
      if kept.usedPercent == new.usedPercent
        && (new.resetsAt == nil || kept.resetsAt == new.resetsAt)
      {
        confirmed = true
      }
    }
    all += windows.filter { old in
      old.resetsAt != nil && !newer.windows.contains { $0.span == old.span }
    }
    return UsageLimits(
      windows: all, isBlocked: newer.isBlocked, readAt: confirmed ? newer.readAt : readAt)
  }
}
