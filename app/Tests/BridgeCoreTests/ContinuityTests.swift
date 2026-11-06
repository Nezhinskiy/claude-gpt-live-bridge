import Foundation
import Testing

@testable import BridgeCore

struct ContinuityTests {
  /// codex counts UTF-8 bytes over 4 and refuses a start past the limit (ADR 0001 (o)).
  @Test func aRussianSeedStaysUnderCodexsLimit() {
    var conversation = Conversation()
    let line = String(repeating: "Это строка ответа. ", count: 100)
    for _ in 0..<Conversation.keptLines { conversation.record(.claude, line) }
    let tokens = conversation.initialItems(tasks: []).reduce(0) {
      $0 + ($1.text.utf8.count + 3) / 4
    }
    #expect(tokens <= Conversation.maxTokens)
  }

  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")

  @Test func itemsKeepNewestWithinLimits() {
    var conversation = Conversation()
    for n in 0..<30 { conversation.record(.owner, "\(n)".padding(2_000)) }
    #expect(conversation.lines.count == 30)
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

  /// A handoff line is for the menu only: an open request goes in as its task line, so the
  /// voice is not given it twice.
  @Test func handoffLinesAreLeftOutOfItems() {
    var conversation = Conversation()
    conversation.record(.owner, "run the tests")
    conversation.record(.handoff, "Run the test suite.")
    conversation.record(.voice, "I'll pass it on.")
    #expect(
      conversation.initialItems(tasks: []) == [
        InitialItem(role: .user, text: "run the tests"),
        InitialItem(role: .assistant, text: "I'll pass it on."),
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

extension ContinuityTests {
  var voice: RequestID { RequestID(rawValue: "request-1") }

  func admit(
    _ continuity: inout Continuity, _ turn: String, request: RequestID? = nil, _ kind: SyncKind,
    _ id: SessionID, pausing: Bool
  ) -> Bool {
    continuity.admits(
      turn: TurnRef(id: turn, request: request), kind: kind, in: id, pausing: pausing)
  }

  @Test func aFileFromBeforeSyncStillDecodes() throws {
    let old = """
      {"conversations":{"\(a.rawValue)":{"lines":[{"speaker":"owner","text":"hi"}],\
      "context":"[CONTEXT] Alpha: x","lastUsed":1}}}
      """
    let continuity = try JSONDecoder().decode(Continuity.self, from: Data(old.utf8))
    #expect(continuity[a].context == "[CONTEXT] Alpha: x")
    #expect(continuity[a].lines.map(\.text) == ["hi"])
    #expect(continuity[a].outOfSync == nil)
    #expect(continuity[a].isCurrent)
  }

  @Test func aRefusedTurnStaysRefusedAfterThePauseEnds() {
    var continuity = Continuity()
    #expect(!admit(&continuity, "t1", .typed, a, pausing: true))
    #expect(!admit(&continuity, "t1", .answer, a, pausing: false))
  }

  @Test func aTurnFromBeforeThePauseKeepsClaudesAnswer() {
    var continuity = Continuity()
    #expect(admit(&continuity, "t1", .typed, a, pausing: false))
    #expect(admit(&continuity, "t1", .answer, a, pausing: true))
  }

  /// Press Stop with the pause on and type into a turn that started synced: nothing of the turn
  /// is recorded from there on, and the answer stays out.
  @Test func theOwnerTypingAfterStopRefusesTheTurn() {
    var continuity = Continuity()
    #expect(admit(&continuity, "t1", .typed, a, pausing: false))
    #expect(!admit(&continuity, "t1", .typed, a, pausing: true))
    #expect(!admit(&continuity, "t1", .answer, a, pausing: false))
    #expect(continuity[a].outOfSync == .paused)
  }

  /// A voice turn holds nothing of the owner's to keep out, until the owner types into it.
  @Test func aVoiceTurnIsAdmittedWhilePausing() {
    var continuity = Continuity()
    #expect(admit(&continuity, "t1", request: voice, .start, a, pausing: true))
    #expect(continuity[a].outOfSync == nil)
  }

  @Test func aVoiceTurnTypedIntoWhilePausingIsRefused() {
    var continuity = Continuity()
    #expect(admit(&continuity, "t1", request: voice, .start, a, pausing: true))
    #expect(!admit(&continuity, "t1", request: voice, .typed, a, pausing: true))
    #expect(continuity[a].outOfSync == .paused)
  }

  /// The `start` of its turn never arrived: its prompt may be the paused text.
  @Test(arguments: [SyncKind.answer, .report])
  func aClaudeLineWithNoDecisionStaysOutOfAPausedSession(kind: SyncKind) {
    var continuity = Continuity()
    continuity.markMissed(a, asPaused: true)
    #expect(!admit(&continuity, "t1", kind, a, pausing: false))
  }

  @Test func aClaudeLineWithNoDecisionGoesInOutsideThePause() {
    var continuity = Continuity()
    continuity.markMissed(a, asPaused: false)
    #expect(admit(&continuity, "t1", .answer, a, pausing: false))
  }

  /// The owner's own words with the call on are no paused line, whatever the session's mark.
  @Test func aTypedLineWithNoDecisionGoesInToAPausedSession() {
    var continuity = Continuity()
    continuity.markMissed(a, asPaused: true)
    #expect(admit(&continuity, "t1", .typed, a, pausing: false))
  }

  @Test func aVoiceTurnsLineWithNoDecisionGoesInToAPausedSession() {
    var continuity = Continuity()
    continuity.markMissed(a, asPaused: true)
    #expect(admit(&continuity, "t1", request: voice, .report, a, pausing: true))
  }

  @Test func aNewTurnDecidesAgain() {
    var continuity = Continuity()
    #expect(!admit(&continuity, "t1", .typed, a, pausing: true))
    #expect(admit(&continuity, "t2", .start, a, pausing: false))
    #expect(continuity[a].outOfSync == .paused)
    #expect(!admit(&continuity, "t3", .answer, a, pausing: true))
    continuity.setContext("[CONTEXT] Alpha: x", for: a)
    #expect(continuity[a].outOfSync == nil)
  }

  @Test func everyRefusedLineMarksPaused() {
    var continuity = Continuity()
    #expect(!admit(&continuity, "t1", .typed, a, pausing: true))
    continuity.setContext("[CONTEXT] Alpha: x", for: a)
    #expect(continuity[a].outOfSync == nil)
    #expect(!admit(&continuity, "t1", .answer, a, pausing: false))
    #expect(continuity[a].outOfSync == .paused)
  }

  @Test func missedDoesNotReplacePaused() {
    var continuity = Continuity()
    continuity.markMissed(a, asPaused: false)
    #expect(continuity[a].outOfSync == .missed)
    continuity.markMissed(a, asPaused: true)
    #expect(continuity[a].outOfSync == .paused)
    continuity.markMissed(a, asPaused: false)
    #expect(continuity[a].outOfSync == .paused)
  }

  @Test func missedUnderThePauseIsPaused() {
    var continuity = Continuity()
    continuity.markMissed(a, asPaused: true)
    #expect(continuity[a].outOfSync == .paused)
  }

  @Test func aSummaryClearsBothCauses() {
    var continuity = Continuity()
    continuity.markMissed(a, asPaused: false)
    continuity.setContext("[CONTEXT] Alpha: x", for: a)
    #expect(continuity[a].outOfSync == nil)
    continuity.markMissed(a, asPaused: true)
    continuity.setContext("[CONTEXT] Alpha: y", for: a)
    #expect(continuity[a].outOfSync == nil)
  }

  /// After `/clear` the state and the turn's decision go with the conversation.
  @Test func moveCarriesTheStateAndTheTurn() {
    var continuity = Continuity()
    #expect(!admit(&continuity, "t1", .typed, a, pausing: true))
    continuity.move(a, to: b)
    #expect(continuity[b].outOfSync == .paused)
    #expect(!admit(&continuity, "t1", .answer, b, pausing: false))
    #expect(continuity[a].outOfSync == nil)
  }

  /// New conversation drops lines and context; a pause and the turn's decision stay.
  /// The ask came after the gap, so its summary covers it.
  @Test func aSummaryAskedForAfterAGapCoversIt() {
    var continuity = Continuity()
    let now = Date()
    continuity.markMissed(a, asPaused: false)
    continuity.noteSummaryAsk(of: a, at: now)
    let taken = continuity.takeSummaryAsk(of: a, at: now)
    #expect(taken)
  }

  @Test func aSummaryNobodyAskedForIsTaken() {
    var continuity = Continuity()
    continuity.markMissed(a, asPaused: false)
    let taken = continuity.takeSummaryAsk(of: a, at: Date())
    #expect(taken)
  }

  /// A gap the join reports after the ask makes it stale, as a refused line does.
  @Test func aMissedTurnAfterTheAskRefusesItsSummary() {
    var continuity = Continuity()
    let now = Date()
    continuity.noteSummaryAsk(of: a, at: now)
    continuity.markMissed(a, asPaused: false)
    let taken = continuity.takeSummaryAsk(of: a, at: now)
    #expect(!taken)
  }

  /// The mod joins a second ask to the summary on its way, which is the first ask's.
  @Test func aSecondAskDoesNotFreshenTheFirst() {
    var continuity = Continuity()
    let now = Date()
    continuity.noteSummaryAsk(of: a, at: now)
    continuity.markMissed(a, asPaused: false)
    continuity.noteSummaryAsk(of: a, at: now + 1)
    let taken = continuity.takeSummaryAsk(of: a, at: now + 2)
    #expect(!taken)
  }

  /// A summary refused closes its ask: the owner's next press stands on its own.
  @Test func aRefusedSummaryClosesItsAsk() {
    var continuity = Continuity()
    let now = Date()
    continuity.noteSummaryAsk(of: a, at: now)
    continuity.markMissed(a, asPaused: false)
    _ = continuity.takeSummaryAsk(of: a, at: now)
    continuity.noteSummaryAsk(of: a, at: now + 1)
    let taken = continuity.takeSummaryAsk(of: a, at: now + 2)
    #expect(taken)
  }

  /// A summary that never came (nothing to summarise, or a failure) does not hold back a later one.
  @Test func anAskPastItsLifeRefusesNothing() {
    var continuity = Continuity()
    let now = Date()
    continuity.noteSummaryAsk(of: a, at: now)
    continuity.markMissed(a, asPaused: false)
    let later = now + Conversation.askLife
    continuity.noteSummaryAsk(of: a, at: later)
    let taken = continuity.takeSummaryAsk(of: a, at: later)
    #expect(taken)
  }

  /// `/clear` moves the conversation, and the ask with it.
  @Test func anAskMovesWithItsConversation() {
    var continuity = Continuity()
    let now = Date()
    continuity.noteSummaryAsk(of: a, at: now)
    continuity.markMissed(a, asPaused: false)
    continuity.move(a, to: b)
    let taken = continuity.takeSummaryAsk(of: b, at: now)
    #expect(!taken)
  }

  @Test func forgetKeepsAPauseAndItsDecision() {
    var continuity = Continuity()
    continuity.record(.owner, "hi", in: a)
    #expect(!admit(&continuity, "t1", .typed, a, pausing: true))
    continuity.setContext("[CONTEXT] Alpha: x", for: a)
    #expect(!admit(&continuity, "t1", .answer, a, pausing: false))
    continuity.forget(a)
    #expect(continuity[a].lines.isEmpty)
    #expect(continuity[a].context == nil)
    #expect(continuity[a].outOfSync == .paused)
    #expect(!admit(&continuity, "t1", .answer, a, pausing: false))

    continuity.record(.owner, "hi", in: b)
    continuity.markMissed(b, asPaused: false)
    continuity.forget(b)
    #expect(continuity[b].outOfSync == nil)
    #expect(!continuity[b].isCurrent)
  }

  @Test func forgetKeepsAnAdmittedDecisionToo() {
    var continuity = Continuity()
    #expect(admit(&continuity, "t1", .typed, a, pausing: false))
    continuity.forget(a)
    #expect(admit(&continuity, "t1", .answer, a, pausing: true))
  }

  @Test func noContextIsNotCurrent() {
    var continuity = Continuity()
    continuity.record(.owner, "hi", in: a)
    #expect(!continuity[a].isCurrent)
  }

  @Test func currentAfterASummaryAndAShortExchange() {
    var continuity = Continuity()
    continuity.setContext("[CONTEXT] Alpha: x", for: a)
    #expect(continuity[a].isCurrent)
    continuity.record(.owner, "hi", in: a)
    continuity.record(.voice, "hello", in: a)
    #expect(continuity[a].isCurrent)
    continuity.markMissed(a, asPaused: false)
    #expect(!continuity[a].isCurrent)
  }

  @Test func linesTheSeedCannotCarryAreNotCurrent() {
    var continuity = Continuity()
    continuity.setContext("[CONTEXT] Alpha: x", for: a)
    for n in 0..<30 { continuity.record(.owner, "\(n)".padding(2_000), in: a) }
    #expect(continuity[a].lines.count == 30)
    #expect(!continuity[a].isCurrent)
  }

  /// A summary covers the lines before it: the count starts again.
  @Test func aSummaryAfterManyLinesIsCurrent() {
    var continuity = Continuity()
    for n in 0..<30 { continuity.record(.owner, "\(n)".padding(2_000), in: a) }
    continuity.setContext("[CONTEXT] Alpha: x", for: a)
    #expect(continuity[a].isCurrent)
  }

  @Test func linesRolledOffAreNotCurrent() {
    var continuity = Continuity()
    continuity.setContext("[CONTEXT] Alpha: x", for: a)
    for n in 0...Conversation.keptLines { continuity.record(.owner, "w\(n)", in: a) }
    #expect(continuity[a].lines.count == Conversation.keptLines)
    #expect(!continuity[a].isCurrent)
  }

  @Test func aHandoffLineCountsForNothing() {
    var continuity = Continuity()
    continuity.setContext("[CONTEXT] Alpha: x", for: a)
    for n in 0...Conversation.keptLines { continuity.record(.handoff, "task \(n)", in: a) }
    #expect(continuity[a].isCurrent)
  }
}

extension String {
  func padding(_ length: Int) -> String { padding(toLength: length, withPad: ".", startingAt: 0) }
}
