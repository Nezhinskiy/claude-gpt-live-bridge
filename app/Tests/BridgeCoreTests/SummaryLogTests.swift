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

  @Test func aLineWithoutAModelSaysFork() {
    #expect(SummaryLog.line(timing(model: nil)).contains("model=fork"))
  }
}
