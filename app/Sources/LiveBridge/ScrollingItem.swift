import AppKit
import SwiftUI

/// A `HostedItem` inside an `NSScrollView`: it scrolls inside the menu once it is taller than
/// `maxHeight`, and opens scrolled to its end. The hosting view hands the wheel and trackpad
/// events it gets on to the scroll view. The item is enabled, as the session rows are, so the
/// menu treats its view as one that takes events; with no action, pressing it does nothing.
@MainActor
final class ScrollingItem<Content: View> {
  private let hosted: HostedItem<Content>
  private let scroll = EndScrollView()
  private let maxHeight: CGFloat
  /// The reader was at the end when the content last changed, so the view stays there.
  private var keepsEnd = true

  var item: NSMenuItem { hosted.item }

  init(_ content: Content, maxHeight: CGFloat) {
    hosted = HostedItem(content)
    self.maxHeight = maxHeight
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = hosted.host
    hosted.item.view = scroll
    hosted.resized = { [weak self] in self?.fit() }
    fit()
  }

  /// The new content. A reader who scrolled up keeps their place; at the end, the view stays
  /// there as lines arrive.
  func show(_ content: Content) {
    keepsEnd = scroll.isAtEnd
    hosted.show(content)
  }

  /// The item as tall as the content, up to `maxHeight`; the open menu resizes with it.
  private func fit() {
    let shown = min(hosted.host.frame.height, maxHeight)
    if abs(scroll.frame.height - shown) > 0.5 || scroll.frame.width != StatusMenu.width {
      scroll.setFrameSize(NSSize(width: StatusMenu.width, height: shown))
    }
    if keepsEnd { scroll.scrollToEnd() }
  }
}

/// Scrolls to its end whenever its menu opens, so the newest line is in view.
final class EndScrollView: NSScrollView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { scrollToEnd() }
  }

  var isAtEnd: Bool {
    guard let document = documentView else { return true }
    return contentView.bounds.maxY >= document.frame.height - 1
  }

  /// The hosting view is flipped, so its end is its largest y.
  func scrollToEnd() {
    guard let document = documentView else { return }
    let end = max(0, document.frame.height - contentView.bounds.height)
    contentView.scroll(to: NSPoint(x: 0, y: end))
    reflectScrolledClipView(contentView)
  }
}
