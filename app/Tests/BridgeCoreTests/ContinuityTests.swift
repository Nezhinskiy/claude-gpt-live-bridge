import Foundation
import Testing

@testable import BridgeCore

struct ContinuityTests {
  @Test func itemsKeepNewestWithinLimits() {
    var continuity = Continuity()
    for n in 0..<30 { continuity.record(Utterance(role: .user, text: "\(n)".padding(2_000))) }
    #expect(continuity.utterances.count == 24)
    let items = continuity.initialItems(tasks: [])  // 500 estimated tokens each: 16 fit
    #expect(items.map { $0.text.prefix(2) } == (14..<30).map { "\($0)" })
    let tasks = (0..<120).map { "task \($0)" }
    #expect(continuity.initialItems(tasks: tasks).count == 128)
  }

  @Test func contextAndTasksComeFirst() {
    var continuity = Continuity()
    continuity.record(Utterance(role: .user, text: "hi"))
    continuity.record(Utterance(role: .assistant, text: "hello"))
    continuity.context = "context"
    #expect(
      continuity.initialItems(tasks: ["task"]) == [
        InitialItem(role: .user, text: "context"), InitialItem(role: .user, text: "task"),
        InitialItem(role: .user, text: "hi"), InitialItem(role: .assistant, text: "hello"),
      ])
  }

  @Test func roundTripsThroughJSON() throws {
    var continuity = Continuity()
    continuity.record(Utterance(role: .user, text: "hi"))
    continuity.context = "context"
    let json = try JSONEncoder().encode(continuity)
    #expect(try JSONDecoder().decode(Continuity.self, from: json) == continuity)
  }
}

extension String {
  func padding(_ length: Int) -> String { padding(toLength: length, withPad: ".", startingAt: 0) }
}
