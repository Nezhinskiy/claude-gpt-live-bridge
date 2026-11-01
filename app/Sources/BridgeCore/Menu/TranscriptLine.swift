import Foundation

/// One of the menu's last lines, `"<speaker>: <text>"` as the status carries it, with the
/// text on one line and capped, so a long answer cannot take over the menu.
public struct TranscriptLine: Sendable, Equatable {
  public static let maxCharacters = 280

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
    let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    text = flat.count <= Self.maxCharacters ? flat : flat.prefix(Self.maxCharacters - 1) + "…"
  }
}
