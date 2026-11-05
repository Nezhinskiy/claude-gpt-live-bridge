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
