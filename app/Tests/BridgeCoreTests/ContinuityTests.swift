import Foundation
import Testing

@testable import BridgeCore

struct ContinuityTests {
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")

  @Test func itemsKeepNewestWithinLimits() {
    var conversation = Conversation()
    for n in 0..<30 { conversation.record(.owner, "\(n)".padding(2_000)) }
    #expect(conversation.lines.count == 24)
    let items = conversation.initialItems(tasks: [])  // 500 estimated tokens each: 16 fit
    #expect(items.map { $0.text.prefix(2) } == (14..<30).map { "\($0)" })
    let tasks = (0..<120).map { "task \($0)" }
    #expect(conversation.initialItems(tasks: tasks).count == 128)
  }

  @Test func contextAndTasksComeFirst() {
    var conversation = Conversation()
    conversation.record(.owner, "hi")
    conversation.record(.voice, "hello")
    conversation.context = "context"
    #expect(
      conversation.initialItems(tasks: ["task"]) == [
        InitialItem(role: .user, text: "context"), InitialItem(role: .user, text: "task"),
        InitialItem(role: .user, text: "hi"), InitialItem(role: .assistant, text: "hello"),
      ])
  }

  /// A session's line goes in as a `user` line, like every line the app adds; one still waiting
  /// to be heard is left out, as it is given to the line again once it opens.
  @Test func sessionLinesGoInAsUserLinesUnlessUnheard() {
    var conversation = Conversation()
    conversation.record(.claude, "[RESULT] Alpha: Done.")
    conversation.record(.claude, "[RESULT] Alpha: Tests pass.")
    #expect(
      conversation.initialItems(tasks: [], unheard: ["[RESULT] Alpha: Tests pass."]) == [
        InitialItem(role: .user, text: "[RESULT] Alpha: Done.")
      ])
  }

  @Test func eachSessionHasItsOwnConversation() {
    var continuity = Continuity()
    continuity.record(.owner, "teal", in: a)
    continuity.record(.owner, "red", in: b)
    continuity.setContext("[CONTEXT] Beta: work", for: b)
    #expect(continuity[a].lines == [Conversation.Line(speaker: .owner, text: "teal")])
    #expect(continuity[a].context == nil)
    #expect(continuity[b].context == "[CONTEXT] Beta: work")
    continuity.forget(a)
    #expect(continuity[a] == Conversation())
    #expect(continuity[b].lines.map(\.text) == ["red"])
  }

  /// After `/clear` the session's new id keeps its conversation.
  @Test func moveKeepsTheConversationUnderTheNewId() {
    var continuity = Continuity()
    continuity.record(.owner, "teal", in: a)
    continuity.move(a, to: b)
    #expect(continuity[a] == Conversation())
    #expect(continuity[b].lines.map(\.text) == ["teal"])
  }

  /// Sessions come and go with new ids, so only the conversations used last are kept.
  @Test func keepsOnlyTheConversationsUsedLast() {
    var continuity = Continuity()
    let ids = (0..<Continuity.keptConversations).map { SessionID(rawValue: "session-\($0)") }
    for id in ids { continuity.record(.owner, "hi", in: id) }
    continuity.record(.owner, "again", in: ids[0])
    continuity.record(.owner, "one more", in: SessionID(rawValue: "newest"))
    #expect(continuity.conversations.count == Continuity.keptConversations)
    #expect(continuity[ids[0]].lines.count == 2)
    #expect(continuity[ids[1]] == Conversation())
  }

  /// The file is a map from session id to that session's conversation.
  @Test func roundTripsThroughJSONAsAMapBySession() throws {
    var continuity = Continuity()
    continuity.record(.owner, "hi", in: a)
    continuity.setContext("context", for: b)
    let json = try JSONEncoder().encode(continuity)
    #expect(try JSONDecoder().decode(Continuity.self, from: json) == continuity)
    let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    let map = try #require(object["conversations"] as? [String: Any])
    #expect(Set(map.keys) == [a.rawValue, b.rawValue])
  }

  /// The single conversation an earlier build saved does not load as anyone's.
  @Test func singleConversationFileDoesNotDecode() {
    let old = #"{"utterances":[{"role":"user","text":"hi"}],"context":"[CONTEXT] Alpha: x"}"#
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Continuity.self, from: Data(old.utf8))
    }
  }
}

extension String {
  func padding(_ length: Int) -> String { padding(toLength: length, withPad: ".", startingAt: 0) }
}
