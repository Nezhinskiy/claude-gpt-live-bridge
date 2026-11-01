import AppKit
import BridgeCore
import Observation

/// The menu bar glyph, "Span": nine bars standing on a bridge deck whose heights trace one span
/// of a suspension bridge (two tall towers, the main cable sagging between them, short side
/// spans). The bars double as a level meter and move per call phase; a badge between the towers
/// shows sessions at work, an approval, or unheard results, and a broken deck shows a problem.
/// Drawn as a 24 × 18 pt template image, so the menu bar tints it for light and dark.
enum SpanGlyph {
  static let size = NSSize(width: 24, height: 18)
  static let off = [CGFloat](repeating: 1.6, count: 9)
  static let closed: [CGFloat] = [2.2, 6, 3, 1.8, 1.6, 1.8, 3, 6, 2.2]
  static let connecting: [CGFloat] = [6, 10, 12, 8, 4, 2.4, 1.8, 1.8, 1.8]
  /// The resting bridge: towers at 13.2 pt, the cable down to 2.6 pt at mid-span.
  static let bridge: [CGFloat] = [4.8, 13.2, 6.51, 3.58, 2.6, 3.58, 6.51, 13.2, 4.8]

  /// Bar heights for `phase` at `t` seconds with input `level` (0 to 1); `t == nil` gives the
  /// still frame used when motion is reduced.
  static func heights(_ phase: CallPhase, t: Double?, level: Double) -> [CGFloat] {
    guard let t else { return still(phase) }
    switch phase {
    case .off: return off
    case .listening:  // the half-height bridge breathes on a 4 s cycle
      let breath = 0.8 + 0.2 * sin(t * .pi / 2)
      return closed.map { max(1.6, $0 * breath) }
    case .connecting:  // a crest travels left to right, one pass a second
      let crest = (t.truncatingRemainder(dividingBy: 1)) * 12 - 1.5
      return (0..<9).map { 1.8 + 10.2 * exp(-pow(Double($0) - crest, 2) / 2) }
    case .live:  // bars move with the voice, then settle back into the bridge
      return bridge.enumerated().map { i, rest in
        let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 1.7)
        return rest + (13.2 - rest) * level * wobble
      }
    }
  }

  static func still(_ phase: CallPhase) -> [CGFloat] {
    switch phase {
    case .off: off
    case .listening: closed
    case .connecting: connecting
    case .live: bridge
    }
  }

  /// One frame; `t` turns the working ring and pulses the approval diamond.
  static func image(heights: [CGFloat], badge: Badge, faded: Bool, t: Double) -> NSImage {
    let image = NSImage(size: size, flipped: true) { _ in
      NSColor.black.withAlphaComponent(faded ? 0.5 : 1).setFill()
      let broken = badge == .problem
      for (i, height) in heights.enumerated() where !(broken && i == 4) {
        // the badge sits above the cable's low point; keep the middle bars below it
        let h = badge == .none || !(3...5).contains(i) ? height : min(height, 5)
        NSBezierPath(
          roundedRect: NSRect(x: 1.2 + 2.5 * Double(i), y: 14 - h, width: 1.6, height: h),
          xRadius: 0.8, yRadius: 0.8
        ).fill()
      }
      let decks =
        broken
        ? [
          NSRect(x: 1, y: 13.6, width: 9.2, height: 2.6),
          NSRect(x: 13.8, y: 13.6, width: 9.2, height: 2.6),
        ] : [NSRect(x: 1, y: 13.6, width: 22, height: 2.6)]
      for deck in decks { NSBezierPath(roundedRect: deck, xRadius: 1.3, yRadius: 1.3).fill() }
      drawBadge(badge, t: t)
      return true
    }
    image.isTemplate = true
    return image
  }

  private static func drawBadge(_ badge: Badge, t: Double) {
    switch badge {
    case .none: break
    case .working:  // a three-quarter ring that turns once a second
      let ring = NSBezierPath()
      let turn = t.truncatingRemainder(dividingBy: 1) * 360
      ring.appendArc(
        withCenter: NSPoint(x: 12, y: 4.4), radius: 2.8, startAngle: turn - 90,
        endAngle: turn + 180)
      ring.lineWidth = 1.6
      ring.lineCapStyle = .round
      ring.stroke()
    case .approval:  // a diamond with an exclamation mark cut out, pulsing
      NSColor.black.withAlphaComponent(0.65 + 0.35 * cos(t * 2 * .pi)).setFill()
      let diamond = NSBezierPath()
      for point in [(12, 0.6), (15.8, 4.4), (12, 8.2), (8.2, 4.4)] {
        diamond.isEmpty
          ? diamond.move(to: NSPoint(x: point.0, y: point.1))
          : diamond.line(to: NSPoint(x: point.0, y: point.1))
      }
      diamond.close()
      diamond.append(NSBezierPath(rect: NSRect(x: 11.2, y: 1.8, width: 1.6, height: 3.1)))
      diamond.append(NSBezierPath(ovalIn: NSRect(x: 11.15, y: 5.75, width: 1.7, height: 1.7)))
      diamond.windingRule = .evenOdd
      diamond.fill()
    case .unheard:
      NSBezierPath(ovalIn: NSRect(x: 9.2, y: 1.6, width: 5.6, height: 5.6)).fill()
    case .problem:  // an exclamation mark standing in the broken deck
      NSBezierPath(
        roundedRect: NSRect(x: 11.1, y: 2.4, width: 1.8, height: 7.6), xRadius: 0.9, yRadius: 0.9
      ).fill()
      NSBezierPath(ovalIn: NSRect(x: 10.8, y: 13.7, width: 2.4, height: 2.4)).fill()
    }
  }
}

/// Keeps the menu bar image current: still frames for still states, 12 frames a second while
/// something moves, and still frames whenever the owner asked macOS to reduce motion. The timer
/// runs in the common run loop modes, so the glyph keeps moving while the menu is open.
@MainActor @Observable
final class StatusGlyph {
  private(set) var image = SpanGlyph.image(
    heights: SpanGlyph.off, badge: .none, faded: true, t: 0)
  @ObservationIgnored private var phase = CallPhase.off
  @ObservationIgnored private var badge = Badge.none
  @ObservationIgnored private var level = 0.0
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private let started = Date()

  func show(_ phase: CallPhase, badge: Badge, level: Double) {
    self.phase = phase
    self.badge = badge
    self.level = 0.6 * self.level + 0.4 * level  // a little smoothing between level messages
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let moves =
      !reduce && badge != .problem && (phase != .off || [.working, .approval].contains(badge))
    if moves, timer == nil {
      let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.draw(still: false) }
      }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    } else if !moves {
      timer?.invalidate()
      timer = nil
    }
    draw(still: !moves)
  }

  private func draw(still: Bool) {
    let t = Date().timeIntervalSince(started)
    let heights = SpanGlyph.heights(phase, t: still ? nil : t, level: level)
    image = SpanGlyph.image(heights: heights, badge: badge, faded: phase == .off, t: still ? 0 : t)
  }
}
