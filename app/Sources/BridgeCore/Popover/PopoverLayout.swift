import Foundation

/// One of the popover's last lines, `"<speaker>: <text>"` as the status carries it, with the
/// text on one line and capped, so a long answer cannot take over the popover.
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

/// The popover's heights, in points, for a screen whose visible area (below the menu bar, above
/// the Dock) is `visibleHeight` tall. The popover never grows past it, which would leave a
/// transparent band at its top, and the sections that grow with their content (the sessions,
/// the last lines and what was sent) scroll inside their own caps.
public struct PopoverLayout: Sendable, Equatable {
  /// Room kept between the popover and the screen's edges.
  public static let screenMargin = 24.0
  /// The call card, the context buttons, the footer, the section titles and the spacing.
  public static let fixedChrome = 340.0
  /// The sections' caps never go below 60 points each.
  public static let minimumSections = 180.0

  /// The whole popover's height; past it, the popover scrolls.
  public let maxHeight: Double
  public let sessions: Double
  public let lastLines: Double
  public let sent: Double

  public init(visibleHeight: Double) {
    maxHeight = max(visibleHeight - Self.screenMargin, 1)
    // Each section has its 60 points; what the screen leaves beyond them is shared out.
    let extra = max(maxHeight - Self.fixedChrome - Self.minimumSections, 0)
    func cap(_ share: Double, _ most: Double) -> Double { min(60 + extra * share, most) }
    sessions = cap(0.4, 280)
    lastLines = cap(0.35, 220)
    sent = cap(0.25, 180)
  }
}
