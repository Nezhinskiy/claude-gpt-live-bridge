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

  /// The figure's unit: "5 h", "week", "30 d", "45 min", "limit", or a kind with spaces.
  public var label: String {
    switch self {
    case .minutes(let raw):
      let minutes = Self.snapped(raw)
      if minutes == Self.aWeek { return "week" }
      if minutes < 60 { return "\(minutes) min" }
      if minutes < 1440 { return "\(Self.rounded(minutes, per: 60)) h" }
      return "\(Self.rounded(minutes, per: 1440)) d"
    case .kind(let name): return name.replacingOccurrences(of: "_", with: " ")
    case .unknown: return "limit"
    }
  }

  /// The tooltip's name for the window: "5-hour window", "Weekly window", "Limit".
  public var windowName: String {
    switch self {
    case .minutes(let raw):
      let minutes = Self.snapped(raw)
      if minutes == Self.aWeek { return "Weekly window" }
      if minutes < 60 { return "\(minutes)-minute window" }
      if minutes < 1440 { return "\(Self.rounded(minutes, per: 60))-hour window" }
      return "\(Self.rounded(minutes, per: 1440))-day window"
    case .kind:
      let text = label
      return text.prefix(1).uppercased() + text.dropFirst() + " window"
    case .unknown: return "Limit"
    }
  }

  /// A length the app names: five hours or a week.
  public var isKnown: Bool {
    guard case .minutes(let raw) = self else { return false }
    let minutes = Self.snapped(raw)
    return minutes == Self.shortMinutes || minutes == Self.aWeek
  }

  private static func rounded(_ minutes: Int, per unit: Int) -> Int {
    (minutes + unit / 2) / unit
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

  /// This reading without the windows whose reset has passed: they say nothing about the new one.
  public func current(at now: Date) -> UsageLimits {
    var copy = self
    copy.windows = windows.filter { window in
      guard let resetsAt = window.resetsAt else { return true }
      return resetsAt >= now
    }
    return copy
  }

  /// `newer` over this one, window by window: the later reset wins, on the same reset the higher
  /// percent (use within a window only grows), and a window with no reset takes the newer. A
  /// window `newer` lacks stays as held until its reset.
  public func merging(_ newer: UsageLimits) -> UsageLimits {
    func merged(_ old: LimitWindow, _ new: LimitWindow) -> LimitWindow {
      guard let oldReset = old.resetsAt, let newReset = new.resetsAt else { return new }
      if newReset != oldReset { return newReset > oldReset ? new : old }
      return new.usedPercent >= old.usedPercent ? new : old
    }
    var all = newer.windows.map { new in
      windows.first { $0.span == new.span }.map { merged($0, new) } ?? new
    }
    all += windows.filter { old in !newer.windows.contains { $0.span == old.span } }
    return UsageLimits(windows: all, isBlocked: newer.isBlocked, readAt: newer.readAt)
  }
}
