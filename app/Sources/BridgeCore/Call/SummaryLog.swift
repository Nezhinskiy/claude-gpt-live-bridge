import Foundation

/// How one summary ask went, as the app saw it.
public struct SummaryTiming: Sendable, Equatable {
  /// Seconds from the ask to the post that answers it; nil, as is `model`, for a post for another
  /// ask, as the app keeps only the open ask's record.
  public var askedFor: TimeInterval?
  /// The ask was made before the session's latest gap or forget, so the post is ignored.
  public var stale: Bool
  /// The post carried a non-blank summary.
  public var hadSummary: Bool
  /// The id of the model that wrote it (`SummaryReport.writer`); nil when a fork wrote it.
  public var model: String?
  public var stats: SummaryStats?
  /// Seconds a line waited for it, from `SummaryAsks.wait` to `SummaryAsks.answer`; nil when no
  /// line waited.
  public var waited: TimeInterval?
  /// No model was tried, as the transcript could not be read: the line names none.
  public var triedNoModel: Bool

  public init(
    askedFor: TimeInterval?, stale: Bool, hadSummary: Bool, model: String?, stats: SummaryStats?,
    waited: TimeInterval? = nil, triedNoModel: Bool = false
  ) {
    self.askedFor = askedFor
    self.stale = stale
    self.hadSummary = hadSummary
    self.model = model
    self.stats = stats
    self.waited = waited
    self.triedNoModel = triedNoModel
  }
}

public enum SummaryLog {
  /// `key=value` pairs, durations in ms, how long a line waited if one did, then the post's
  /// `stats` if it sent them. A post for another ask has no time and no model, and one on which no
  /// model was tried no model. It holds numbers and a listed model's name only: a model id the
  /// owner typed can be an ARN with an account number, so it is logged as `custom`.
  public static func line(_ timing: SummaryTiming) -> String {
    let model: String
    if let id = timing.model {
      model = SummaryModel.isListed(id) ? "\"\(SummaryModel.name(id))\"" : "custom"
    } else {
      model = "fork"
    }
    let stats = timing.stats.map {
      [
        "duration=\($0.durationMs)ms", "transcriptChars=\($0.transcriptChars)",
        "inputTokens=\($0.inputTokens)", "outputTokens=\($0.outputTokens)",
      ]
    }
    let waited = timing.waited.map { ["waited=\(Self.ms($0))ms"] }
    var head = ["stale=\(timing.stale)", "hadSummary=\(timing.hadSummary)"]
    if let askedFor = timing.askedFor {
      let named = timing.triedNoModel ? [] : ["model=\(model)"]
      head = ["askedFor=\(Self.ms(askedFor))ms"] + head + named
    }
    return (head + (waited ?? []) + (stats ?? [])).joined(separator: " ")
  }

  private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
}
