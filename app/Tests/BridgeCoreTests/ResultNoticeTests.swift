import Testing

@testable import BridgeCore

struct ResultNoticeTests {
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")
  var labels: [SessionID: String] { [a: "Alpha", b: "Beta"] }

  func line(_ text: String, _ session: SessionID?) -> VoiceLine {
    VoiceLine(text: text, session: session)
  }

  @Test func nothingWaitingIsNoNotice() {
    #expect(ResultNotice.waiting([], labels: labels) == nil)
  }

  /// The body names the session, never the result: it can be private, and it is long.
  @Test func oneResultNamesItsSession() throws {
    let notice = try #require(
      ResultNotice.waiting([line("[RESULT] Alpha: the secret is 42.", a)], labels: labels))
    #expect(notice.title == "LiveBridge")
    #expect(notice.body == "Alpha has a new result — speak to hear it.")
    #expect(!notice.body.contains("42"))
  }

  @Test func severalFromOneSession() throws {
    let notice = try #require(
      ResultNotice.waiting(
        [line("[RESULT] Alpha: x", a), line("[UPDATE] Alpha: y", a)], labels: labels))
    #expect(notice.body == "Alpha has new results — speak to hear them.")
  }

  @Test func severalSessionsCollapseIntoOne() throws {
    let lines = [line("[RESULT] Alpha: x", a), line("[RESULT] Beta: y", b), line("z", a)]
    let notice = try #require(ResultNotice.waiting(lines, labels: labels))
    #expect(notice.body == "2 sessions have new results — speak to hear them.")
  }

  /// A line of LiveBridge's own, or from a session that has left, names no session.
  @Test func aResultWithoutAKnownSession() throws {
    let lines = [line("[FAILED] LiveBridge: no Claude Code session is joined.", nil)]
    let notice = try #require(ResultNotice.waiting(lines, labels: labels))
    #expect(notice.body == "A new result is waiting — speak to hear it.")
  }

  /// Each notice replaces the one before instead of stacking.
  @Test func everyNoticeHasTheSameIdentity() throws {
    let one = try #require(ResultNotice.waiting([line("x", a)], labels: labels))
    let two = try #require(ResultNotice.waiting([line("x", a), line("y", b)], labels: labels))
    #expect(one.identifier == two.identifier)
  }
}
