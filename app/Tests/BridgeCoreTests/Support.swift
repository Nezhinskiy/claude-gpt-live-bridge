import Foundation
import Testing
import os

@testable import BridgeCore

/// The observed codex messages in `Fixtures/adr` (ADR 0001).
func adrFixture(_ name: String, extension ext: String = "json") throws -> Data {
  let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/adr")
  return try Data(contentsOf: try #require(url))
}

func adrJSON(_ name: String) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: adrFixture(name))
}

/// Waits, in real time, up to two seconds for `condition`.
func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
  for _ in 0..<200 {
    if try await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return false
}

/// The task was still running at the bound `settle(_:within:)` gave it.
struct StillRunning: Error, CustomStringConvertible {
  let limit: Duration
  var description: String { "The task was still running after \(limit)." }
}

/// Waits, in real time, up to `limit` for `task` to end, and throws its error or `StillRunning`.
/// `await task.value` ignores cancellation, so a task left suspended would hold the test, and
/// the whole run, past its time limit; this ends the test instead, and leaves the task behind.
func settle<Failure: Error>(
  _ task: Task<Void, Failure>, within limit: Duration = .seconds(5)
) async throws {
  let first = OSAllocatedUnfairLock<CheckedContinuation<Void, any Error>?>(initialState: nil)
  try await withCheckedThrowingContinuation { done in
    first.withLock { $0 = done }
    let timer = Task {
      guard (try? await Task.sleep(for: limit)) != nil else { return }
      first.withLock { $0.take() }?.resume(throwing: StillRunning(limit: limit))
    }
    Task {
      let result = await task.result
      first.withLock { $0.take() }?.resume(with: result.mapError { $0 })
      timer.cancel()
    }
  }
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A clock for tests: time moves only by `advance(by:)`, which wakes every sleeper it passes.
/// A sleeper whose task was cancelled throws `CancellationError` when woken, so a cancelled
/// timer never fires.
final class TestTime: TimeSource {
  private struct State {
    var now: Date
    var sleepers: [(deadline: Date, wake: CheckedContinuation<Void, Never>)] = []
  }
  private let state: OSAllocatedUnfairLock<State>

  init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    state = OSAllocatedUnfairLock(initialState: State(now: now))
  }

  var now: Date { state.withLock { $0.now } }

  /// How many sleepers are waiting; tests wait for a timer to be armed before advancing.
  var sleepers: Int { state.withLock { $0.sleepers.count } }

  /// When each waiting sleeper wakes; a test waits for the timer it needs by its deadline.
  var deadlines: [Date] { state.withLock { $0.sleepers.map(\.deadline) } }

  func sleep(until deadline: Date) async throws {
    await withCheckedContinuation { wake in
      state.withLock { $0.sleepers.append((deadline, wake)) }
      advance(by: .zero)
    }
    try Task.checkCancellation()
  }

  func advance(by duration: Duration) {
    let due = state.withLock { state in
      state.now += duration.timeInterval
      let due = state.sleepers.filter { $0.deadline <= state.now }
      state.sleepers.removeAll { $0.deadline <= state.now }
      return due
    }
    for sleeper in due { sleeper.wake.resume() }
  }
}

extension BridgeUpdate {
  /// The newest summary the conversation shows.
  var context: String? { conversation.last { $0.speaker == .context }?.text }
  var needsContext: Bool { contextNeed == .load }

  func with(contextNeed: ContextNeed) -> BridgeUpdate {
    BridgeUpdate(
      status: status, problem: problem, minutesThisCall: minutesThisCall,
      conversation: conversation, labelsOnAnOlderMod: labelsOnAnOlderMod,
      contextNeed: contextNeed, claudeLimits: claudeLimits)
  }
}
