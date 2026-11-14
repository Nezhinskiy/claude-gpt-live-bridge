import Testing

@testable import BridgeCore

struct ModelCheckTests {
  func failed(_ reason: SummaryFailure.Reason, _ kind: String? = nil) -> ModelCheckResult {
    ModelCheckResult(
      ModelCheckBody(
        sessionId: SessionID(rawValue: "00000000-0000-0000-0000-000000000001"),
        id: "00000000-0000-0000-0000-00000000000c", ok: false, reason: reason, error: kind))
  }

  /// Each kind that may clear is one the engine documents, so the check can be told it.
  @Test func whatMayClearIsAKnownKind() {
    #expect(ModelCheckResult.mayClear.isSubset(of: SummaryReport.knownErrors))
  }

  /// An error that may clear on its own says nothing of the model: it is busy, not refused.
  @Test func aRateLimitIsBusy() {
    for kind in ["rate_limit", "overloaded", "server_error"] {
      #expect(failed(.apiError, kind) == .busy)
    }
    #expect(failed(.apiError, "model_not_found") == .refused(.apiError, kind: "model_not_found"))
  }

  /// No text a local process wrote reaches Settings: only a kind the engine documents is shown.
  @Test func anUnknownErrorKindIsNotShown() throws {
    let unknown = try #require(failed(.apiError, "<b>hi").message)
    #expect(!unknown.contains("<b>hi"))
    let known = try #require(failed(.apiError, "model_not_found").message)
    #expect(known.contains("model_not_found"))
  }

  /// Check and save stores the model only when it works; a refusal leaves the choice in force.
  @Test func aRefusalKeepsTheOldValue() async {
    let settings = SettingsStore(file: nil)
    settings.update { $0.summaryModel = "claude-opus-5-5" }
    let refused = await settings.save(summaryModel: "claude-x-1") { _ in
      .refused(.apiError, kind: "model_not_found")
    }
    #expect(refused == .refused(.apiError, kind: "model_not_found"))
    #expect(settings.current.summaryModel == "claude-opus-5-5")
    #expect(await settings.save(summaryModel: "claude-x-1") { _ in .works } == .works)
    #expect(settings.current.summaryModel == "claude-x-1")
  }
}
