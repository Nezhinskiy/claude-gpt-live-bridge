import Testing

@testable import BridgeCore

struct SummaryLogTests {
  private func timing(model: String?) -> SummaryTiming {
    SummaryTiming(askedFor: 7.25, stale: false, hadSummary: true, model: model, stats: nil)
  }

  @Test func theLineHoldsNumbersAndTheModelNameOnly() {
    let custom = SummaryLog.line(timing(model: "arn:aws:bedrock:eu-west-1:123456789012:x"))
    #expect(custom.contains("model=custom"))
    #expect(!custom.contains("1234"))
    #expect(custom.contains("askedFor=7250ms"))
    #expect(SummaryLog.line(timing(model: "claude-haiku-5-5")).contains("model=\"Haiku 5.5\""))
  }

  @Test func theLineCarriesThePostsNumbers() {
    var withStats = timing(model: "claude-haiku-5-5")
    withStats.stats = SummaryStats(
      durationMs: 4_000, transcriptChars: 90_000, inputTokens: 25_000, outputTokens: 400)
    let line = SummaryLog.line(withStats)
    #expect(line.contains("duration=4000ms"))
    #expect(line.contains("transcriptChars=90000"))
    #expect(line.contains("inputTokens=25000"))
    #expect(line.contains("outputTokens=400"))
  }

  @Test func theLineSaysHowLongTheLineWaited() {
    var waited = timing(model: nil)
    #expect(!SummaryLog.line(waited).contains("waited="))
    waited.waited = 3.5
    #expect(SummaryLog.line(waited).contains("waited=3500ms"))
  }

  @Test func aLineWithoutAModelSaysFork() {
    #expect(SummaryLog.line(timing(model: nil)).contains("model=fork"))
  }
}
