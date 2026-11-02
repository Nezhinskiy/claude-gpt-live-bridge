import Foundation

/// The clock the core reads, so tests can move time by hand.
public protocol TimeSource: Sendable {
  var now: Date { get }
  func sleep(for duration: Duration) async throws
}

public struct SystemTime: TimeSource {
  public init() {}
  public var now: Date { Date() }
  public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
