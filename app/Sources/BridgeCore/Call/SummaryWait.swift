import Foundation

/// Whether a line waits for its session's summary, before its seed is built and before it
/// connects. It waits while the session has an open, current ask (`Continuity`'s), its mod said
/// `writesSummaries`, and in this call no wait of that session's ended without a summary, so a
/// persistent failure holds one line, not every line.
struct SummaryWait: Sendable {
  /// The spec's "The time limit" says how the measurement set it.
  static let limit: TimeInterval = 10

  /// The sessions whose wait ended this call with no summary: an empty answer, or the limit.
  private var endedEmpty: Set<SessionID> = []

  /// A wait of `id` ended with no summary; no later line of this call waits for it.
  mutating func endedWithout(_ id: SessionID) { endedEmpty.insert(id) }

  /// The call started: every session may be waited for again.
  mutating func newCall() { endedEmpty = [] }

  /// When a line of `id` stops waiting at the latest, counted from the ask; nil: it does not wait.
  func deadline(
    for id: SessionID, ask: Conversation.SummaryAsk?, writesSummaries: Bool
  ) -> Date? {
    guard writesSummaries, let ask, !ask.isStale, !endedEmpty.contains(id) else { return nil }
    return ask.at + Self.limit
  }
}
