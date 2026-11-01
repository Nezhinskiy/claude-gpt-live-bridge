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
/// transparent band at its top. The sessions list shows `visibleSessions` rows; the last lines
/// and what was sent share what the screen leaves; each scrolls inside its own cap.
public struct PopoverLayout: Sendable, Equatable {
  /// Room kept between the popover and the screen's edges.
  public static let screenMargin = 24.0
  /// The call card, five session rows, the context buttons, the footer, the section titles and
  /// the spacing.
  public static let fixedChrome = 340.0 + 236
  /// The last lines' and what was sent's caps never go below 60 points each.
  public static let minimumSections = 120.0
  /// The sessions list's height in rows; more sessions scroll inside it.
  public static let visibleSessions = 5

  /// The whole popover's height; past it, the popover scrolls.
  public let maxHeight: Double
  public let lastLines: Double
  public let sent: Double

  public init(visibleHeight: Double) {
    maxHeight = max(visibleHeight - Self.screenMargin, 1)
    // Each section has its 60 points; what the screen leaves beyond them is shared out.
    let extra = max(maxHeight - Self.fixedChrome - Self.minimumSections, 0)
    func cap(_ share: Double, _ most: Double) -> Double { min(60 + extra * share, most) }
    lastLines = cap(0.6, 220)
    sent = cap(0.4, 180)
  }

  /// The sessions list's cap for rows `rowHeight` tall with `spacing` between them: exactly
  /// `visibleSessions` rows. Until a row has been measured (`rowHeight` 0) nothing is cut.
  public static func sessionsCap(rowHeight: Double, spacing: Double) -> Double {
    guard rowHeight > 0 else { return .infinity }
    let rows = Double(visibleSessions)
    return rows * rowHeight + (rows - 1) * spacing
  }
}

/// The popover's corner radii. Like macOS's own menu bar modules (Control Center's), the window
/// has large corners, and the cards inside are concentric with them: the window's radius less
/// the popover's padding. Liquid Glass (macOS 26 and later) rounds more.
public struct PopoverCorners: Sendable, Equatable {
  /// The popover's padding between the window's edge and its cards.
  public static let inset = 12.0

  public let window: Double
  public let card: Double

  public init(glass: Bool) {
    window = glass ? 24 : 16
    card = max(window - Self.inset, 8)
  }
}
