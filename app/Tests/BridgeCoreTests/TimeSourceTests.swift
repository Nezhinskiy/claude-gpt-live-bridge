import Foundation
import Testing

@testable import BridgeCore

struct TimeSourceTests {
  @Test func testTimeWakesOnlyTheSleepersItPasses() async throws {
    let time = TestTime()
    let start = time.now
    let short = Task { try await time.sleep(for: .seconds(5)) }
    let cancelled = Task { try await time.sleep(for: .seconds(5)) }
    let long = Task { try await time.sleep(for: .seconds(60)) }
    while time.sleepers < 3 { await Task.yield() }
    cancelled.cancel()
    time.advance(by: .seconds(5))
    try await short.value
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(time.sleepers == 1 && time.now == start.addingTimeInterval(5))
    long.cancel()
    time.advance(by: .seconds(55))
  }
}
