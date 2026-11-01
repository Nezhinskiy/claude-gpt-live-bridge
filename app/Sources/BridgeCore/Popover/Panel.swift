import CoreGraphics
import Foundation

/// Where the popover's panel opens: under its status item's button, right-aligned to it, a small
/// gap under the menu bar as macOS's own menu bar modules hang, and kept inside the visible
/// frame (below the menu bar, beside the Dock) of the screen holding the button. Coordinates are
/// AppKit's screen coordinates: y grows upwards. Pure: the caller passes the frames.
public enum PanelPlacement {
  /// Between the menu bar and the panel's top.
  public static let gap: CGFloat = 6
  /// Between the panel and the visible frame's other edges.
  public static let margin: CGFloat = 6

  /// One display: its whole frame and the part windows may use.
  public struct Screen: Sendable, Equatable {
    public let frame: CGRect
    public let visible: CGRect

    public init(frame: CGRect, visible: CGRect) {
      self.frame = frame
      self.visible = visible
    }
  }

  /// The screen holding `anchor` (the button's frame); without one, the first screen, which is
  /// the one with the menu bar (`NSScreen.screens.first`).
  public static func screen(for anchor: CGRect?, in screens: [Screen]) -> Screen? {
    guard let anchor else { return screens.first }
    let middle = CGPoint(x: anchor.midX, y: anchor.midY)
    if let holding = screens.first(where: { $0.frame.contains(middle) }) { return holding }
    func overlap(_ screen: Screen) -> Double {
      let shared = screen.frame.intersection(anchor)
      return shared.isNull ? 0 : Double(shared.width * shared.height)
    }
    return screens.max { overlap($0) < overlap($1) } ?? screens.first
  }

  /// The panel's frame for content `size` under the button at `anchor`, in whole points. A
  /// panel taller than the screen leaves is cut to it (the popover scrolls inside).
  public static func frame(size: CGSize, under anchor: CGRect?, screens: [Screen]) -> CGRect {
    guard let visible = screen(for: anchor, in: screens)?.visible else {
      let origin = anchor.map { CGPoint(x: $0.maxX - size.width, y: $0.minY - gap - size.height) }
      return CGRect(origin: origin ?? .zero, size: size).integral
    }
    let top = (min(anchor?.minY ?? visible.maxY, visible.maxY) - gap).rounded(.down)
    let height = min(size.height, max(top - (visible.minY + margin), 1)).rounded()
    let width = min(size.width, max(visible.width - 2 * margin, 1)).rounded()
    let right = anchor?.maxX ?? (visible.maxX - margin)
    let x = min(max(right - width, visible.minX + margin), visible.maxX - margin - width)
    return CGRect(x: x.rounded(), y: top - height, width: width, height: height)
  }
}

/// Whether the popover's panel is open, and what opening or closing it asks of AppKit. On macOS
/// 27 the system runs the status item's expanded interface session (opening on the button,
/// highlighting it, ending on menu bar tracking); before, and for a panel opened by a
/// notification, the app does it by hand. Either way the app closes the panel on a click
/// elsewhere, Escape, another app or another Space; its own confirmation alerts leave it open.
public struct PanelMachine: Sendable, Equatable {
  /// Where a mouse click landed.
  public enum Click: Sendable, Equatable {
    case panel
    /// The status item's button, which opens and closes the panel by itself.
    case statusItem
    /// A confirmation the popover asked (an app-modal alert).
    case alert
    /// Another window of the app, or another app.
    case elsewhere
  }

  public enum Event: Sendable, Equatable {
    /// The button's action, when the app toggles the panel by hand.
    case statusItemPressed
    /// A click on one of the app's notifications.
    case open
    /// macOS 27's expanded interface session began or ended.
    case sessionBegan, sessionEnded
    case click(Click)
    case escape, otherAppActivated, spaceChanged
    /// The popover itself closes the panel, as when it opens Settings.
    case dismiss
  }

  public enum Effect: Sendable, Equatable {
    case show, hide
    /// The button's highlight, drawn by hand only when no system session draws it.
    case highlight(Bool)
    /// Ends the system's session, which the app closed.
    case cancelSession
  }

  public private(set) var isOpen = false
  public private(set) var inSession = false
  /// The app draws the button's highlight: the panel is open with no system session.
  public private(set) var highlighted = false

  public init() {}

  public mutating func handle(_ event: Event) -> [Effect] {
    switch event {
    case .statusItemPressed: return isOpen ? close() : open()
    case .open: return isOpen ? [] : open()
    case .sessionBegan:
      if isOpen { return inSession ? [] : close() + [.cancelSession] }  // a second press
      isOpen = true
      inSession = true
      return [.show]
    case .sessionEnded:
      inSession = false
      return isOpen ? close() : []
    case .click(.panel), .click(.statusItem), .click(.alert): return []
    case .click(.elsewhere), .escape, .otherAppActivated, .spaceChanged, .dismiss:
      guard isOpen else { return [] }
      let cancels = inSession
      inSession = false
      return close() + (cancels ? [.cancelSession] : [])
    }
  }

  private mutating func open() -> [Effect] {
    isOpen = true
    highlighted = true
    return [.show, .highlight(true)]
  }

  private mutating func close() -> [Effect] {
    isOpen = false
    defer { highlighted = false }
    return highlighted ? [.hide, .highlight(false)] : [.hide]
  }
}
