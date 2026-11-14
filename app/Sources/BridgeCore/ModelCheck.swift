/// What came of Settings' check of a custom summary model (`Bridge.checkModel`), in the app's own
/// words: no text the checking session sent is shown but a kind of API error the engine documents.
public enum ModelCheckResult: Sendable, Equatable {
  /// The model answered with text.
  case works
  /// No joined session's mod can check, so nothing was sent.
  case noSession
  /// The session left, or no result came within 20 s.
  case noAnswer
  /// An API error that may clear on its own.
  case busy
  /// The model wrote nothing: why, and the engine's kind of API error with `apiError`.
  case refused(SummaryFailure.Reason, kind: String?)

  /// The kinds of API error that may clear on their own.
  static let mayClear: Set = ["rate_limit", "overloaded", "server_error"]

  init(_ body: ModelCheckBody) {
    if body.ok {
      self = .works
    } else if body.reason == .apiError, let kind = body.error, Self.mayClear.contains(kind) {
      self = .busy
    } else {
      self = .refused(body.reason ?? .unknown, kind: body.error)
    }
  }

  /// The sentence beside the field; nil when the model works.
  public var message: String? {
    switch self {
    case .works: nil
    case .noSession: "No session can check this model. Run /live in a session and save again."
    case .noAnswer: "The check got no answer."
    case .busy: "Claude is busy; try again."
    case .refused(let reason, let kind):
      "Not saved: the model \(SummaryReport.phrase(SummaryFailure(reason: reason, error: kind)))."
    }
  }
}

extension SettingsStore {
  /// Settings' Check and save: `model` is stored only when `check` says it works, so a refusal
  /// leaves the choice in force.
  public func save(
    summaryModel model: String, checkedBy check: @Sendable (String) async -> ModelCheckResult
  ) async -> ModelCheckResult {
    let result = await check(model)
    if result == .works { update { $0.summaryModel = model } }
    return result
  }
}
