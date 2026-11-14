import Foundation
import Testing

@testable import BridgeCore

/// `wire/fixtures` is the contract shared with the mod: each file is one message.
struct WireTests {
  static let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent().appending(path: "../../../wire/fixtures").standardized

  /// Fixture name → a check that it decodes to its type and re-encodes to the same JSON.
  static let roundTrips: [String: @Sendable (Data) throws -> Data] = [
    "join": roundTrip(JoinBody.self), "join-replaces": roundTrip(JoinBody.self),
    "join-version": roundTrip(JoinBody.self), "join-syncs": roundTrip(JoinBody.self),
    "join-writes-summaries": roundTrip(JoinBody.self),
    "sync-start": roundTrip(SyncBody.self), "sync-start-voice": roundTrip(SyncBody.self),
    "sync-typed": roundTrip(SyncBody.self), "sync-answer": roundTrip(SyncBody.self),
    "sync-report": roundTrip(SyncBody.self),
    "leave": roundTrip(LeaveBody.self),
    "target": roundTrip(TargetBody.self), "call": roundTrip(CallBody.self),
    "call-mute": roundTrip(CallBody.self),
    "activity": roundTrip(ActivityBody.self), "activity-question": roundTrip(ActivityBody.self),
    "activity-approval": roundTrip(ActivityBody.self),
    "activity-typed-question": roundTrip(ActivityBody.self),
    "activity-voice-question": roundTrip(ActivityBody.self),
    "context": roundTrip(ContextBody.self), "context-stats": roundTrip(ContextBody.self),
    "context-fallback": roundTrip(ContextBody.self), "context-failed": roundTrip(ContextBody.self),
    "context-unreadable": roundTrip(ContextBody.self),
    "limits": roundTrip(LimitsBody.self),
    "answer-ok": roundTrip(AnswerBody.self), "answer-failed": roundTrip(AnswerBody.self),
    "next-request": roundTrip(PollReply.self), "next-context": roundTrip(PollReply.self),
    "next-context-model": roundTrip(PollReply.self), "next-check-model": roundTrip(PollReply.self),
    "model-check-ok": roundTrip(ModelCheckBody.self),
    "model-check-failed": roundTrip(ModelCheckBody.self),
    "next-idle": roundTrip(PollReply.self), "next-reply": roundTrip(PollReply.self),
    "error": roundTrip(ErrorReply.self), "error-removed": roundTrip(ErrorReply.self),
  ]

  /// A reply from an app older than `forRequest`: the mod still reads one, and this app never sends
  /// one, so it is no message of this app's.
  static let olderApp = "next-reply-older"

  static func roundTrip<T: Codable & Sendable>(_ type: T.Type) -> @Sendable (Data) throws -> Data {
    { try JSONEncoder().encode(JSONDecoder().decode(type, from: $0)) }
  }

  static func canonical(_ json: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: json)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  @Test func everyFixtureRoundTrips() throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
    #expect(Set(files) == Set((Array(Self.roundTrips.keys) + [Self.olderApp]).map { "\($0).json" }))
    for (name, roundTrip) in Self.roundTrips {
      let json = try Data(contentsOf: Self.fixtures.appending(path: "\(name).json"))
      #expect(try Self.canonical(roundTrip(json)) == Self.canonical(json), "\(name).json")
    }
  }

  @Test func aReplyWithoutItsRequestIsNoMessageOfThisApps() throws {
    let json = try Data(contentsOf: Self.fixtures.appending(path: "\(Self.olderApp).json"))
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(PollReply.self, from: json) }
  }

  @Test func workIsTaggedByKind() throws {
    let json = try Data(contentsOf: Self.fixtures.appending(path: "next-request.json"))
    let reply = try JSONDecoder().decode(PollReply.self, from: json)
    guard case .request(let request) = reply.work else {
      Issue.record("expected a request")
      return
    }
    #expect(request.transcript == [Utterance(role: .user, text: request.brief)])
    #expect(
      reply.status.sessions.map(\.label) == ["Example session · 0000", "Example session · 1111"])
  }

  /// An older mod reads `{"kind":"context"}` alone, so an ask that names no model must stay that.
  @Test func anAskWithNoModelEncodesAsBefore() throws {
    let json = try Data(contentsOf: Self.fixtures.appending(path: "next-context.json"))
    let reply = try JSONDecoder().decode(PollReply.self, from: json)
    #expect(reply.work == .context())
    let sent = try JSONEncoder().encode(PollReply(status: reply.status, work: .context()))
    #expect(try Self.canonical(sent) == Self.canonical(json))
  }

  /// The mod gives a summary up after the budget the app waits on: this file ties their two constants.
  @Test func theSummaryBudgetIsTheMods() throws {
    let file = Self.fixtures.appending(path: "../summary-budget.json")
    let budget = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: file))
    #expect(budget["summaryBudgetMs"] == SummaryAsks.Policy.modBudget * 1000)
  }
}
