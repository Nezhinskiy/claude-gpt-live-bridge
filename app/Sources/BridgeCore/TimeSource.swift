import Foundation
import os

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

/// A clock for tests: time moves only by `advance(by:)`, which wakes every sleeper it passes.
/// A sleeper whose task was cancelled throws `CancellationError` when woken, so a cancelled
/// timer never fires.
public final class TestTime: TimeSource {
  private struct State {
    var now: Date
    var sleepers: [(deadline: Date, wake: CheckedContinuation<Void, Never>)] = []
  }
  private let state: OSAllocatedUnfairLock<State>

  public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    state = OSAllocatedUnfairLock(initialState: State(now: now))
  }

  public var now: Date { state.withLock { $0.now } }

  /// How many sleepers are waiting; tests wait for a timer to be armed before advancing.
  public var sleepers: Int { state.withLock { $0.sleepers.count } }

  public func sleep(for duration: Duration) async throws {
    await withCheckedContinuation { wake in
      state.withLock { $0.sleepers.append(($0.now + duration.timeInterval, wake)) }
      advance(by: .zero)
    }
    try Task.checkCancellation()
  }

  public func advance(by duration: Duration) {
    let due = state.withLock { state in
      state.now += duration.timeInterval
      let due = state.sleepers.filter { $0.deadline <= state.now }
      state.sleepers.removeAll { $0.deadline <= state.now }
      return due
    }
    for sleeper in due { sleeper.wake.resume() }
  }
}

extension Duration {
  var timeInterval: TimeInterval {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
