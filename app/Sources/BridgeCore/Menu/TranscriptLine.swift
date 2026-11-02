import Foundation

/// One line of the target's conversation in the menu, `"<speaker>: <text>"` as the bridge lists
/// it: who said it, and the whole of what they said, its line breaks kept for the view to wrap.
public struct TranscriptLine: Sendable, Equatable {
  public let speaker: String
  public let text: String

  public init(_ raw: String) {
    let parts = raw.split(separator: ": ", maxSplits: 1, omittingEmptySubsequences: false)
    let body: Substring
    if parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") {
      speaker = String(parts[0])
      body = parts[1]
    } else {
      speaker = ""
      body = Substring(raw)
    }
    text = body.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
