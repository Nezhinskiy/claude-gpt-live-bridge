import Foundation

/// The models the owner can pick for the summary.
public enum SummaryModel {
  public static let `default` = "claude-haiku-5-5"
  public static let listed: [(id: String, name: String)] = [
    ("claude-haiku-5-5", "Haiku 5.5"),
    ("claude-sonnet-5-5", "Sonnet 5.5"),
    ("claude-opus-5-5", "Opus 5.5"),
  ]

  /// The listed name of `id`, else "Custom model".
  public static func name(_ id: String) -> String {
    listed.first { $0.id == id }?.name ?? "Custom model"
  }

  /// `text` trimmed, if it can be a model id; nil otherwise. It keeps nonsense out of the wire and
  /// the log, and is not a control: the engine resolves and allowlist-checks the id.
  public static func accepted(_ text: String) -> String? {
    let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return id.wholeMatch(of: /[A-Za-z0-9._:\/@\[\]-]{1,128}/) != nil ? id : nil
  }
}

/// What came of the last summary asked for with a model, from the app's own record of the ask.
public struct SummaryReport: Sendable, Equatable {
  public var asked: String
  public var fallback: String?
  public var failures: [SummaryFailure]
  /// A model wrote a summary.
  public var wrote: Bool

  /// The kinds of API error the engine documents; any other text a local process sent is not shown.
  static let knownErrors: Set = [
    "rate_limit", "overloaded", "server_error", "model_not_found", "invalid_request",
    "authentication_failed", "billing_error",
  ]

  /// The model that wrote it: the fallback once the model asked for failed, else that one, which
  /// an empty answer also names. The log and Settings' line both name it.
  public var writer: String { wrote && !failures.isEmpty ? fallback ?? asked : asked }

  /// Settings' line about it; nil when the model asked for wrote it, or when no model was tried.
  public var line: String? {
    guard !failures.isEmpty else { return nil }
    let models = [asked, fallback ?? asked]
    let failed = failures.enumerated().map { index, failure in
      "\(SummaryModel.name(models[min(index, 1)])) \(Self.phrase(failure))"
    }
    if wrote {
      return "The last summary used \(SummaryModel.name(writer)): \(failed[0])."
    }
    return "The voice got no new summary: \(failed.joined(separator: ", then "))."
  }

  /// What the model did, after its name: "was refused", "returned an error (overloaded)".
  static func phrase(_ failure: SummaryFailure) -> String {
    switch failure.reason {
    case .modelRefused: "was refused"
    case .apiError:
      if let kind = failure.error, knownErrors.contains(kind) {
        "returned an error (\(kind))"
      } else {
        "returned an error"
      }
    case .emptyReply: "wrote nothing"
    case .timedOut: "ran out of time"
    case .unknown: "failed"
    }
  }
}
