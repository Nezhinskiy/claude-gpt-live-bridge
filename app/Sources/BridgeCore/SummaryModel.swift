/// The models the owner can pick for the summary.
public enum SummaryModel {
  static let `default` = "claude-haiku-5-5"
  static let listed: [(id: String, name: String)] = [
    ("claude-haiku-5-5", "Haiku 5.5"),
    ("claude-sonnet-5-5", "Sonnet 5.5"),
    ("claude-opus-5-5", "Opus 5.5"),
  ]

  /// The listed name of `id`, else "Custom model".
  static func name(_ id: String) -> String {
    listed.first { $0.id == id }?.name ?? "Custom model"
  }
}
