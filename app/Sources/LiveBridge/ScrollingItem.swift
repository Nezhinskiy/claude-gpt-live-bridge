import AppKit
import SwiftUI

/// A menu item whose view is a hosted SwiftUI view, `width` wide and wrapped to its own height,
/// that scrolls inside the menu once it is taller than `maxHeight` and opens scrolled to its
/// end. The scrolling is an `NSScrollView`'s, around the hosting view: the hosting view hands
/// the wheel and trackpad events it gets on to it. The item is enabled, as the session rows
/// are, so the menu treats its view as one that takes events; with no action, pressing it does
/// nothing.
@MainActor
final class ScrollingItem<Content: View> {
  let item = NSMenuItem()
  private let scroll = EndScrollView()
  private let host: NSHostingView<Wrapped<Content>>
  private let width: CGFloat
  private let maxHeight: CGFloat

  init(_ content: Content, width: CGFloat, maxHeight: CGFloat) {
    self.width = width
    self.maxHeight = maxHeight
    host = NSHostingView(rootView: Wrapped(content: content, width: width))
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = host
    item.view = scroll
    fit(keepingEnd: true)
  }

  /// The new content. A reader who scrolled up keeps their place; at the end, the view stays
  /// there as lines arrive.
  func show(_ content: Content) {
    let wasAtEnd = scroll.isAtEnd
    host.rootView = Wrapped(content: content, width: width)
    fit(keepingEnd: wasAtEnd)
  }

  /// Sizes the content to its wrapped height, and the item to that height up to `maxHeight`;
  /// the open menu resizes with it.
  private func fit(keepingEnd: Bool) {
    host.layoutSubtreeIfNeeded()
    let height = max(host.fittingSize.height, 1)
    host.setFrameSize(NSSize(width: width, height: height))
    let shown = min(height, maxHeight)
    if abs(scroll.frame.height - shown) > 0.5 || scroll.frame.width != width {
      scroll.setFrameSize(NSSize(width: width, height: shown))
    }
    if keepingEnd { scroll.scrollToEnd() }
  }
}

/// The content at the item's width and its own height.
struct Wrapped<Content: View>: View {
  let content: Content
  let width: CGFloat

  var body: some View {
    content
      .frame(width: width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
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
