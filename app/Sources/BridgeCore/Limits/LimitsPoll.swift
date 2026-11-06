import Foundation

/// When Codex's usage is read: when the menu opens, at most once a minute and one read at a time,
/// and the last reading stands for a quarter of an hour. Pure.
public struct LimitsPoll: Sendable, Equatable {
  /// The least time between two starts of a read.
  public static let readEvery: TimeInterval = 60
  /// A reading older than this is no longer shown.
  public static let staleAfter: TimeInterval = 15 * 60

  private var last: UsageLimits?
  private var lastBegan: Date?
  private var isReading = false

  public init() {}

  /// True when a read should start now; it is then under way until `finish`. The cooldown counts
  /// from the last start, whether that read succeeded or not.
  public mutating func begin(at now: Date) -> Bool {
    guard !isReading else { return false }
    if let lastBegan, now.timeIntervalSince(lastBegan) < Self.readEvery { return false }
    isReading = true
    lastBegan = now
    return true
  }

  /// nil: the read failed, the last reading stands.
  public mutating func finish(_ reading: UsageLimits?) {
    isReading = false
    if let reading { last = reading }
  }

  /// The last reading, nil once it is older than `staleAfter`.
  public func reading(at now: Date) -> UsageLimits? {
    guard let last, now.timeIntervalSince(last.readAt) <= Self.staleAfter else { return nil }
    return last
  }
}
