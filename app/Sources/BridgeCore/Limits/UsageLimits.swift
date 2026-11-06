import Foundation

/// One usage window: how much of it is used and when it resets.
public struct LimitWindow: Sendable, Equatable {
  public var usedPercent: Double
  public var resetsAt: Date?

  public init(usedPercent: Double, resetsAt: Date?) {
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
  }
}

/// What one source says about its usage: a five-hour window and a week window, either may be
/// missing, and when it was read. Held in memory only.
public struct UsageLimits: Sendable, Equatable {
  public var fiveHour: LimitWindow?
  public var week: LimitWindow?
  /// The source says ordinary usage is not allowed right now, whatever the percentages show.
  public var isBlocked = false
  public var readAt: Date

  public init(
    fiveHour: LimitWindow? = nil, week: LimitWindow? = nil, isBlocked: Bool = false, readAt: Date
  ) {
    self.fiveHour = fiveHour
    self.week = week
    self.isBlocked = isBlocked
    self.readAt = readAt
  }

  /// This reading without the windows whose reset has passed: they say nothing about the new one.
  public func current(at now: Date) -> UsageLimits {
    func live(_ window: LimitWindow?) -> LimitWindow? {
      guard let window, let resetsAt = window.resetsAt, resetsAt < now else { return window }
      return nil
    }
    var copy = self
    copy.fiveHour = live(fiveHour)
    copy.week = live(week)
    return copy
  }

  /// `newer` over this one, window by window: the later reset wins, on the same reset the higher
  /// percent (use within a window only grows), and a window with no reset takes the newer. A
  /// window `newer` lacks stays as held.
  public func merging(_ newer: UsageLimits) -> UsageLimits {
    func merged(_ old: LimitWindow?, _ new: LimitWindow?) -> LimitWindow? {
      guard let old else { return new }
      guard let new else { return old }
      guard let oldReset = old.resetsAt, let newReset = new.resetsAt else { return new }
      if newReset != oldReset { return newReset > oldReset ? new : old }
      return new.usedPercent >= old.usedPercent ? new : old
    }
    var result = newer
    result.fiveHour = merged(fiveHour, newer.fiveHour)
    result.week = merged(week, newer.week)
    return result
  }
}
