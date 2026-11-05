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
    "join-version": roundTrip(JoinBody.self),
    "leave": roundTrip(LeaveBody.self),
    "target": roundTrip(TargetBody.self), "call": roundTrip(CallBody.self),
    "activity": roundTrip(ActivityBody.self), "activity-question": roundTrip(ActivityBody.self),
    "activity-approval": roundTrip(ActivityBody.self),
    "context": roundTrip(ContextBody.self),
    "answer-ok": roundTrip(AnswerBody.self), "answer-failed": roundTrip(AnswerBody.self),
    "next-request": roundTrip(PollReply.self), "next-context": roundTrip(PollReply.self),
    "next-idle": roundTrip(PollReply.self), "next-reply": roundTrip(PollReply.self),
    "error": roundTrip(ErrorReply.self), "error-removed": roundTrip(ErrorReply.self),
  ]

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
    #expect(Set(files) == Set(Self.roundTrips.keys.map { "\($0).json" }))
    for (name, roundTrip) in Self.roundTrips {
      let json = try Data(contentsOf: Self.fixtures.appending(path: "\(name).json"))
      #expect(try Self.canonical(roundTrip(json)) == Self.canonical(json), "\(name).json")
    }
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

}
