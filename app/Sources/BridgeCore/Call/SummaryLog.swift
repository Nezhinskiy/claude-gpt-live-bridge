import Foundation

/// The numbers the mod reports about the summary it wrote; filled by a later wave.
public struct SummaryStats: Sendable, Equatable {
  public init() {}
}

/// How one summary ask went, as the app saw it.
public struct SummaryTiming: Sendable, Equatable {
  /// Seconds from the ask to the post that answers it.
  public var askedFor: TimeInterval
  /// The ask was made before the session's latest gap or forget, so the post is ignored.
  public var stale: Bool
  /// The post carried a non-blank summary.
  public var hadSummary: Bool
  /// The id of the model that wrote it; nil when the summary came from a fork.
  public var model: String?
  public var stats: SummaryStats?

  public init(
    askedFor: TimeInterval, stale: Bool, hadSummary: Bool, model: String?, stats: SummaryStats?
  ) {
    self.askedFor = askedFor
    self.stale = stale
    self.hadSummary = hadSummary
    self.model = model
    self.stats = stats
  }
}

public enum SummaryLog {
  /// `key=value` pairs, durations in ms. It holds numbers and a listed model's name only: a model
  /// id the owner typed can be an ARN with an account number, so it is logged as `custom`.
  public static func line(_ timing: SummaryTiming) -> String {
    let model: String
    if let id = timing.model {
      model =
        SummaryModel.listed.contains { $0.id == id } ? "\"\(SummaryModel.name(id))\"" : "custom"
    } else {
      model = "fork"
    }
    return [
      "askedFor=\(Int((timing.askedFor * 1000).rounded()))ms", "stale=\(timing.stale)",
      "hadSummary=\(timing.hadSummary)", "model=\(model)",
    ].joined(separator: " ")
  }
}
