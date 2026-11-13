import Testing

@testable import BridgeCore

struct SummaryModelTests {
  @Test func customTextIsTrimmedAndChecked() {
    #expect(SummaryModel.accepted(" claude-x-1 ") == "claude-x-1")
    #expect(SummaryModel.accepted("") == nil)
    #expect(SummaryModel.accepted("a b") == nil)
    #expect(SummaryModel.accepted(String(repeating: "x", count: 129)) == nil)
    #expect(SummaryModel.accepted("x;rm") == nil)
  }

  private func report(
    _ asked: String, fallback: String? = "claude-haiku-5-5", _ failures: [SummaryFailure],
    wrote: Bool
  ) -> SummaryReport {
    SummaryReport(asked: asked, fallback: fallback, failures: failures, wrote: wrote)
  }

  @Test func theReportSaysWhichModelWrote() {
    let refused = SummaryFailure(reason: .modelRefused, error: nil)
    let timedOut = SummaryFailure(reason: .timedOut, error: nil)
    #expect(report("claude-opus-5-5", [], wrote: true).line == nil)
    #expect(
      report("claude-opus-5-5", [refused], wrote: true).line
        == "The last summary used Haiku 5.5: Opus 5.5 was refused.")
    #expect(
      report("claude-opus-5-5", [refused, timedOut], wrote: false).line
        == "The voice got no new summary: Opus 5.5 was refused, then Haiku 5.5 ran out of time.")
    #expect(
      report(
        "claude-haiku-5-5", fallback: nil, [SummaryFailure(reason: .emptyReply, error: nil)],
        wrote: false
      ).line == "The voice got no new summary: Haiku 5.5 wrote nothing.")
    #expect(
      report(
        "claude-sonnet-5-5", [SummaryFailure(reason: .apiError, error: "overloaded")], wrote: true
      ).line == "The last summary used Haiku 5.5: Sonnet 5.5 returned an error (overloaded).")
  }

  /// The log and Settings' line name the same writer: the fallback once the asked model failed.
  @Test func theWriterIsTheFallbackOnceTheAskedModelFailed() {
    let refused = SummaryFailure(reason: .modelRefused, error: nil)
    let timedOut = SummaryFailure(reason: .timedOut, error: nil)
    #expect(report("claude-opus-5-5", [], wrote: true).writer == "claude-opus-5-5")
    #expect(report("claude-opus-5-5", [refused], wrote: true).writer == "claude-haiku-5-5")
    #expect(
      report("claude-opus-5-5", [refused, timedOut], wrote: true).writer == "claude-haiku-5-5")
    #expect(
      report("claude-sonnet-5-5", fallback: nil, [refused], wrote: true).writer
        == "claude-sonnet-5-5")
    #expect(
      report("claude-opus-5-5", [refused, timedOut], wrote: false).writer == "claude-opus-5-5")
  }

  /// The kind comes from a local process, so only one the engine documents is shown.
  @Test func anUnknownErrorKindIsNotShown() {
    let line = report(
      "claude-opus-5-5", [SummaryFailure(reason: .apiError, error: "<b>hi")], wrote: true
    ).line
    #expect(line == "The last summary used Haiku 5.5: Opus 5.5 returned an error.")
  }
}
