import Foundation

/// The clock the core reads, so tests can move time by hand.
public protocol TimeSource: Sendable {
  var now: Date { get }
  /// Returns at `deadline`, at once if it has passed.
  func sleep(until deadline: Date) async throws
}

extension TimeSource {
  /// Sleeps for `duration` from when the sleep begins.
  public func sleep(for duration: Duration) async throws {
    try await sleep(until: now + duration.timeInterval)
  }
}

public struct SystemTime: TimeSource {
  public init() {}
  public var now: Date { Date() }
  public func sleep(until deadline: Date) async throws {
    try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
  }
}

extension Duration {
  var timeInterval: TimeInterval {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
