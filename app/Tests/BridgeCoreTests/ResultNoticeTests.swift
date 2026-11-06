import Testing

@testable import BridgeCore

struct ResultNoticeTests {
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")
  var labels: [SessionID: String] { [a: "Alpha", b: "Beta"] }

  func line(_ body: String, _ session: SessionID?) -> VoiceLine {
    VoiceLine(
      kind: .result, label: session.flatMap { labels[$0] } ?? "LiveBridge", body: body,
      session: session)
  }

  /// With the call off the microphone is released, so speaking alone hears nothing.
  @Test func aCallThatIsOffSaysToStartFirst() throws {
    let notice = try #require(
      ResultNotice.waiting([line("Done.", a)], labels: labels, callIsOff: true))
    #expect(notice.body.contains("start the call and speak"))
  }

  @Test func nothingWaitingIsNoNotice() {
    #expect(ResultNotice.waiting([], labels: labels) == nil)
  }

  /// The body names the session, never the result: it can be private, and it is long.
  @Test func oneResultNamesItsSession() throws {
    let notice = try #require(
      ResultNotice.waiting([line("the secret is 42.", a)], labels: labels))
    #expect(notice.title == "LiveBridge")
    #expect(notice.body == "Alpha has a new result — speak to hear it.")
    #expect(!notice.body.contains("42"))
  }

  @Test func severalFromOneSession() throws {
    let notice = try #require(
      ResultNotice.waiting(
        [line("x", a), line("y", a)], labels: labels))
    #expect(notice.body == "Alpha has new results — speak to hear them.")
  }

  @Test func severalSessionsCollapseIntoOne() throws {
    let lines = [line("x", a), line("y", b), line("z", a)]
    let notice = try #require(ResultNotice.waiting(lines, labels: labels))
    #expect(notice.body == "2 sessions have new results — speak to hear them.")
  }

  /// A line of LiveBridge's own, or from a session that has left, names no session.
  @Test func aResultWithoutAKnownSession() throws {
    let lines = [line("no Claude Code session is joined.", nil)]
    let notice = try #require(ResultNotice.waiting(lines, labels: labels))
    #expect(notice.body == "A new result is waiting — speak to hear it.")
  }

}
